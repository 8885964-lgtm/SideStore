//
//  AccountSessionGate.swift
//  SideStore
//
//  Serializes account switches. Pipeline work for one Apple ID runs only while
//  that account occupies the legacy keychain slots the rest of the app reads.
//

import Foundation
import CoreData
import SideSign

final class AccountSessionGate: @unchecked Sendable {
    static let shared = AccountSessionGate()

    @TaskLocal static var depth = 0

    private let lock = NSLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private init() {}

    func requiresSwitch(to appleID: String?) -> Bool {
        guard let appleID = appleID?.trimmingCharacters(in: .whitespacesAndNewlines), !appleID.isEmpty else { return false }
        guard let current = AppleAccountStore.shared.activeAppleID, !current.isEmpty else { return true }
        return current.caseInsensitiveCompare(appleID) != .orderedSame
    }

    /// Holds the gate without changing the active account.
    func performExclusive<T>(_ body: () async throws -> T) async throws -> T {
        if Self.depth > 0 {
            return try await body()
        }
        await self.acquire()
        defer { self.release() }
        return try await Self.$depth.withValue(1) {
            try await body()
        }
    }

    /// Runs `body` with `appleID` loaded. Restores the previously active account afterwards.
    /// Nested calls keep the account the outer call already selected.
    func perform<T>(appleID: String?, _ body: () async throws -> T) async throws -> T {
        if Self.depth > 0 {
            return try await body()
        }
        return try await self.performExclusive {
            guard self.requiresSwitch(to: appleID), let appleID else {
                return try await body()
            }
            let previous = AppleAccountStore.shared.activeAppleID
            try await self.activate(appleID, notify: false)
            do {
                let result = try await body()
                if let previous {
                    try? await self.activate(previous, notify: false)
                }
                return result
            } catch {
                if let previous {
                    try? await self.activate(previous, notify: false)
                }
                throw error
            }
        }
    }

    func useAccount(_ appleID: String) async throws {
        try await self.performExclusive {
            try await self.activate(appleID, notify: true)
        }
    }

    func activate(_ appleID: String, notify: Bool) async throws {
        guard let account = AppleAccountStore.shared.account(matching: appleID) else {
            throw OperationError.notAuthenticated
        }
        AppleAccountStore.shared.captureCurrentCredentials(postNotification: false)
        AppleAccountStore.shared.applyToLegacyKeychain(account)
        AuthManager.shared.invalidateCachedSession()
        try await self.syncDatabase(to: account)
        if let teamType = account.teamType {
            AuthManager.shared.applyActiveAppsLimit(for: teamType)
        }
        if notify {
            NotificationCenter.default.post(name: AppleAccountStore.didChangeNotification, object: nil)
        }
        debugLog("[AccountSessionGate] Active Apple ID is now \(account.appleID)")
    }

    private func syncDatabase(to account: StoredAppleAccount) async throws {
        let coordinator = DatabaseManager.shared.persistentContainer.persistentStoreCoordinator
        guard !coordinator.persistentStores.isEmpty else { return }
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        try await context.perform {
            let accountRequest: NSFetchRequest<Account> = Account.fetchRequest()
            let accounts = try context.fetch(accountRequest)
            var match: Account?
            for dbAccount in accounts {
                let isMatch = dbAccount.appleID.caseInsensitiveCompare(account.appleID) == .orderedSame
                dbAccount.isActiveAccount = isMatch
                if isMatch { match = dbAccount }
            }
            if match == nil {
                let identifier = account.accountIdentifier ?? account.teamIdentifier ?? account.appleID
                if let existing = Account.first(satisfying: NSPredicate(format: "%K == %@", #keyPath(Account.identifier), identifier), in: context) {
                    existing.appleID = account.appleID
                    existing.isActiveAccount = true
                    if let firstName = account.firstName { existing.firstName = firstName }
                    if let lastName = account.lastName { existing.lastName = lastName }
                    match = existing
                } else {
                    let created = Account(
                        ALTAccount(
                            appleID: account.appleID,
                            identifier: identifier,
                            firstName: account.firstName ?? "",
                            lastName: account.lastName ?? ""
                        ),
                        context: context
                    )
                    created.isActiveAccount = true
                    match = created
                }
            }

            let teamRequest: NSFetchRequest<Team> = Team.fetchRequest()
            let teams = try context.fetch(teamRequest)
            var teamMatch: Team?
            for team in teams {
                let isMatch = account.teamIdentifier != nil && team.identifier == account.teamIdentifier
                team.isActiveTeam = isMatch
                if isMatch { teamMatch = team }
            }
            if teamMatch == nil, let teamID = account.teamIdentifier, let dbAccount = match {
                let type = ALTTeamType(rawValue: account.teamTypeRaw ?? ALTTeamType.unknown.rawValue) ?? .unknown
                let created = Team(
                    ALTTeam(identifier: teamID, name: account.teamName ?? teamID, type: type),
                    account: dbAccount,
                    context: context
                )
                created.isActiveTeam = true
            }
            if context.hasChanges {
                try context.save()
            }
        }
        await DatabaseManager.shared.viewContext.perform {
            DatabaseManager.shared.viewContext.processPendingChanges()
            DatabaseManager.shared.viewContext.refreshAllObjects()
        }
    }

    private func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.lock.lock()
            if !self.busy {
                self.busy = true
                self.lock.unlock()
                continuation.resume()
            } else {
                self.waiters.append(continuation)
                self.lock.unlock()
            }
        }
    }

    private func release() {
        self.lock.lock()
        if self.waiters.isEmpty {
            self.busy = false
            self.lock.unlock()
        } else {
            let next = self.waiters.removeFirst()
            self.lock.unlock()
            next.resume()
        }
    }
}
