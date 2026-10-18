//
//  AccountSessionGate.swift
//  SideStore
//
//  Serializes changes to which Apple ID occupies the signed-in keychain slots.
//  Pipeline work for one Apple ID never overlaps a switch to another one.
//

import Foundation
import CoreData
import SideSign

final class AccountSessionGate: @unchecked Sendable {
    static let shared = AccountSessionGate()

    enum Access: Sendable {
        /// Pipeline work for the Apple ID that is already signed in. Runs alongside other shared work.
        case shared
        /// Signing in or out. Runs alongside shared work, as it did before there were multiple Apple IDs.
        case credentials
        /// Puts a different Apple ID in the signed-in slots. Waits for, and blocks, all other work.
        case exclusive
    }

    /// The access held by the current task tree. Nested calls run under it instead of waiting again.
    @TaskLocal static var holding: Access? = nil

    private struct Waiter {
        let access: Access
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var sharedCount = 0
    private var credentialsHeld = false
    private var exclusiveHeld = false
    private var waiters: [Waiter] = []

    private init() {}

    // MARK: - Access

    func withAccess<T>(_ access: Access, _ body: () async throws -> T) async rethrows -> T {
        if Self.holding != nil {
            return try await body()
        }
        await self.acquire(access)
        defer { self.release(access) }
        return try await Self.$holding.withValue(access) {
            try await body()
        }
    }

    /// Runs pipeline work for apps signed by `appleID`. When that Apple ID is stored and isn't the signed-in one,
    /// it is signed in for the duration of `body`, and the signed-in Apple ID comes back afterwards.
    func perform<T>(appleID: String?, _ body: () async throws -> T) async throws -> T {
        if Self.holding != nil {
            return try await body()
        }

        if !self.requiresSwitch(to: appleID) {
            await self.acquire(.shared)
            if !self.requiresSwitch(to: appleID) {
                defer { self.release(.shared) }
                return try await Self.$holding.withValue(.shared) {
                    try await body()
                }
            }
            self.release(.shared)
        }

        return try await self.withAccess(.exclusive) {
            try await self.runSwitched(to: appleID, body)
        }
    }

    func requiresSwitch(to appleID: String?) -> Bool {
        guard let appleID = appleID?.trimmingCharacters(in: .whitespacesAndNewlines), !appleID.isEmpty,
              AppleAccountStore.shared.contains(appleID) else {
            return false
        }
        guard let current = AppleAccountStore.shared.activeAppleID else { return true }
        return current.caseInsensitiveCompare(appleID) != .orderedSame
    }

    private func acquire(_ access: Access) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.lock.lock()
            self.waiters.append(Waiter(access: access, continuation: continuation))
            let granted = self.grantWaiters()
            self.lock.unlock()
            for waiting in granted {
                waiting.resume()
            }
        }
    }

    private func release(_ access: Access) {
        self.lock.lock()
        switch access {
        case .shared: self.sharedCount -= 1
        case .credentials: self.credentialsHeld = false
        case .exclusive: self.exclusiveHeld = false
        }
        let granted = self.grantWaiters()
        self.lock.unlock()
        for continuation in granted {
            continuation.resume()
        }
    }

    /// Grants waiters in order. Nothing passes a waiting exclusive request, so switches can't be starved,
    /// except while a sign-in holds credentials: the switch can't start then anyway, and the sign-in may be
    /// waiting on pipeline work (re-signing SideStore) that needs shared access.
    private func grantWaiters() -> [CheckedContinuation<Void, Never>] {
        var granted: [CheckedContinuation<Void, Never>] = []
        var exclusiveWaiting = false
        var index = 0
        while index < self.waiters.count {
            let waiter = self.waiters[index]
            let isBehindExclusive = exclusiveWaiting && waiter.access != .exclusive && !self.credentialsHeld
            if !isBehindExclusive && self.canTake(waiter.access) {
                self.take(waiter.access)
                granted.append(waiter.continuation)
                self.waiters.remove(at: index)
            } else {
                if waiter.access == .exclusive {
                    exclusiveWaiting = true
                }
                index += 1
            }
        }
        return granted
    }

    private func canTake(_ access: Access) -> Bool {
        switch access {
        case .shared: return !self.exclusiveHeld
        case .credentials: return !self.exclusiveHeld && !self.credentialsHeld
        case .exclusive: return !self.exclusiveHeld && !self.credentialsHeld && self.sharedCount == 0
        }
    }

    private func take(_ access: Access) {
        switch access {
        case .shared: self.sharedCount += 1
        case .credentials: self.credentialsHeld = true
        case .exclusive: self.exclusiveHeld = true
        }
    }

    // MARK: - Switching

    /// Call with exclusive access. Nothing is written to the keychain or the database, so quitting
    /// mid-batch leaves the signed-in Apple ID untouched.
    private func runSwitched<T>(to appleID: String?, _ body: () async throws -> T) async throws -> T {
        guard self.requiresSwitch(to: appleID), let appleID,
              let account = AppleAccountStore.shared.account(matching: appleID) else {
            return try await body()
        }

        let team = try await self.team(for: account)
        let previousAppleID = AppleAccountStore.shared.activeAppleID
        let previousLimit = UserDefaults.standard.activeAppsLimit
        let limit = AuthManager.shared.activeAppsLimit(for: team.type)
        let changesLimit = limit != previousLimit
        if changesLimit {
            self.savePendingRestore(PendingRestore(appleID: previousAppleID, restoresActiveAppsLimit: true, activeAppsLimit: previousLimit))
            UserDefaults.standard.activeAppsLimit = limit
        }

        Keychain.shared.beginAccountOverride(AppleAccountStore.shared.slots(for: account))
        self.reloadActiveCertificate()
        AuthManager.shared.overrideCachedTeam(team)
        debugLog("[AccountSessionGate] Signed in \(account.appleID) (team \(team.identifier)) for this batch.")

        defer {
            // Keeps a certificate the batch provisioned for this Apple ID.
            AppleAccountStore.shared.captureCurrentCredentials(postNotification: false)
            Keychain.shared.endAccountOverride()
            self.reloadActiveCertificate()
            AuthManager.shared.invalidateCachedSession()
            if changesLimit {
                UserDefaults.standard.activeAppsLimit = previousLimit
                self.clearPendingRestore()
            }
            debugLog("[AccountSessionGate] Restored the signed-in Apple ID after the batch for \(account.appleID).")
        }

        return try await body()
    }

    func useAccount(_ appleID: String) async throws {
        try await self.withAccess(.exclusive) {
            AppleAccountStore.shared.captureCurrentCredentials(postNotification: false)
            try await self.makeActive(appleID)
        }
        NotificationCenter.default.post(name: AppleAccountStore.didChangeNotification, object: nil)
    }

    /// Signs in the next stored Apple ID after the signed-in one signed out. Call with exclusive access.
    func promote(_ appleID: String) async {
        do {
            try await self.makeActive(appleID)
            NotificationCenter.default.post(name: AppleAccountStore.didChangeNotification, object: nil)
        } catch {
            debugLog("[AccountSessionGate] Could not sign in \(appleID) after signing out: \(error)")
        }
    }

    /// Makes `appleID` the signed-in Apple ID in the database, the keychain, and the free-account limit.
    /// Call with exclusive access.
    private func makeActive(_ appleID: String) async throws {
        guard let account = AppleAccountStore.shared.account(matching: appleID) else {
            throw OperationError.notAuthenticated
        }

        let previousSelection = await self.currentDatabaseSelection()
        self.savePendingRestore(PendingRestore(
            appleID: AppleAccountStore.shared.activeAppleID,
            restoresDatabase: true,
            accountURI: previousSelection.account?.uriRepresentation(),
            teamURI: previousSelection.team?.uriRepresentation()
        ))
        defer { self.clearPendingRestore() }

        // The database goes first: if the app quits before the keychain changes, launch puts the database back.
        try await self.activateDatabaseRecords(for: account)
        Keychain.shared.setAccountSlots(AppleAccountStore.shared.slots(for: account))
        self.reloadActiveCertificate()
        AuthManager.shared.invalidateCachedSession()
        if let teamType = account.teamType {
            AuthManager.shared.applyActiveAppsLimit(for: teamType)
        }
        // The flag describes the previous team; Settings checks the new team's registration again.
        UserDefaults.standard.isDeviceRegistered = false
        debugLog("[AccountSessionGate] \(account.appleID) is now the signed-in Apple ID.")
    }

    /// Runs `signIn` against empty Apple ID slots so it can't reuse the signed-in account's credentials or
    /// certificate. The new Apple ID is kept on success; otherwise everything returns to the previous one.
    func addAccount<T>(_ signIn: () async throws -> T) async throws -> T {
        return try await self.withAccess(.exclusive) {
            AppleAccountStore.shared.captureCurrentCredentials(postNotification: false)

            let previousSelection = await self.currentDatabaseSelection()
            let previousLimit = UserDefaults.standard.activeAppsLimit
            let previousDeviceRegistered = UserDefaults.standard.isDeviceRegistered
            self.savePendingRestore(PendingRestore(
                appleID: AppleAccountStore.shared.activeAppleID,
                restoresActiveAppsLimit: true,
                activeAppsLimit: previousLimit,
                isDeviceRegistered: previousDeviceRegistered,
                restoresDatabase: true,
                accountURI: previousSelection.account?.uriRepresentation(),
                teamURI: previousSelection.team?.uriRepresentation()
            ))

            Keychain.shared.beginAccountOverride(KeychainAccountSlots())
            self.reloadActiveCertificate()
            AuthManager.shared.invalidateCachedSession()
            UserDefaults.standard.isDeviceRegistered = false

            let result: T
            do {
                result = try await signIn()
            } catch {
                Keychain.shared.endAccountOverride()
                self.reloadActiveCertificate()
                AuthManager.shared.invalidateCachedSession()
                await self.restoreDatabaseSelection(previousSelection)
                UserDefaults.standard.activeAppsLimit = previousLimit
                UserDefaults.standard.isDeviceRegistered = previousDeviceRegistered
                self.clearPendingRestore()
                throw error
            }

            if let added = Keychain.shared.endAccountOverride() {
                Keychain.shared.setAccountSlots(added)
            }
            self.clearPendingRestore()
            self.reloadActiveCertificate()
            AuthManager.shared.invalidateCachedSession()
            AppleAccountStore.shared.captureCurrentCredentials()
            return result
        }
    }

    private func team(for account: StoredAppleAccount) async throws -> ALTTeam {
        if let identifier = account.teamIdentifier, !identifier.isEmpty {
            return ALTTeam(identifier: identifier, name: account.teamName ?? identifier, type: account.teamType ?? .unknown)
        }
        if let team = await self.databaseTeam(forAppleID: account.appleID) {
            return team
        }
        let message = String(format: NSLocalizedString("SideStore couldn’t find the developer team for %@. Sign in to it again in Settings > Apple IDs.", comment: ""), account.appleID)
        throw NSError(domain: "SideStore.AppleAccounts", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func reloadActiveCertificate() {
        do {
            try CertificateManager.shared.loadActiveCertificate()
        } catch {
            debugLog("[AccountSessionGate] Failed to load the signing certificate: \(error)")
        }
    }

    // MARK: - Database

    private struct DatabaseSelection {
        var account: NSManagedObjectID?
        var team: NSManagedObjectID?
    }

    private static var isDatabaseLoaded: Bool {
        !DatabaseManager.shared.persistentContainer.persistentStoreCoordinator.persistentStores.isEmpty
    }

    private func databaseTeam(forAppleID appleID: String) async -> ALTTeam? {
        guard Self.isDatabaseLoaded else { return nil }
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        return await context.perform {
            let request: NSFetchRequest<Account> = Account.fetchRequest()
            guard let accounts = try? context.fetch(request),
                  let dbAccount = accounts.first(where: { $0.appleID.caseInsensitiveCompare(appleID) == .orderedSame }) else {
                return nil
            }
            let teams = Array(dbAccount.teams)
            guard let dbTeam = teams.first(where: { $0.isActiveTeam }) ?? (teams.count == 1 ? teams.first : nil) else {
                return nil
            }
            return ALTTeam(identifier: dbTeam.identifier, name: dbTeam.name, type: dbTeam.type)
        }
    }

    private func currentDatabaseSelection() async -> DatabaseSelection {
        guard Self.isDatabaseLoaded else { return DatabaseSelection(account: nil, team: nil) }
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        return await context.perform {
            DatabaseSelection(
                account: DatabaseManager.shared.activeAccount(in: context)?.objectID,
                team: DatabaseManager.shared.activeTeam(in: context)?.objectID
            )
        }
    }

    private func restoreDatabaseSelection(_ selection: DatabaseSelection) async {
        guard Self.isDatabaseLoaded else { return }
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        await context.perform {
            do {
                let accountRequest: NSFetchRequest<Account> = Account.fetchRequest()
                for dbAccount in try context.fetch(accountRequest) {
                    dbAccount.isActiveAccount = dbAccount.objectID == selection.account
                }
                let teamRequest: NSFetchRequest<Team> = Team.fetchRequest()
                for dbTeam in try context.fetch(teamRequest) {
                    dbTeam.isActiveTeam = dbTeam.objectID == selection.team
                }
                if context.hasChanges {
                    try context.save()
                }
            } catch {
                debugLog("[AccountSessionGate] Failed to restore the active account in the database: \(error)")
            }
        }
        await self.refreshViewContext()
    }

    /// Marks the stored account's Account and Team active. Only creates records when the store knows both identifiers.
    private func activateDatabaseRecords(for account: StoredAppleAccount) async throws {
        guard Self.isDatabaseLoaded else { return }
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        try await context.perform {
            let accountRequest: NSFetchRequest<Account> = Account.fetchRequest()
            let dbAccounts = try context.fetch(accountRequest)
            let teamRequest: NSFetchRequest<Team> = Team.fetchRequest()
            let dbTeams = try context.fetch(teamRequest)

            var matchedAccount: Account?
            if let identifier = account.accountIdentifier {
                matchedAccount = dbAccounts.first { $0.identifier == identifier }
            }
            if matchedAccount == nil {
                matchedAccount = dbAccounts.first { $0.appleID.caseInsensitiveCompare(account.appleID) == .orderedSame }
            }
            if matchedAccount == nil, let teamIdentifier = account.teamIdentifier {
                matchedAccount = dbTeams.first { $0.identifier == teamIdentifier }?.account
            }
            if matchedAccount == nil, let identifier = account.accountIdentifier, account.teamIdentifier != nil {
                matchedAccount = Account(
                    ALTAccount(appleID: account.appleID, identifier: identifier, firstName: account.firstName ?? "", lastName: account.lastName ?? ""),
                    context: context
                )
            }
            guard let activeAccount = matchedAccount else { throw OperationError.notAuthenticated }

            var matchedTeam: Team?
            if let teamIdentifier = account.teamIdentifier {
                matchedTeam = dbTeams.first { $0.identifier == teamIdentifier }
                if matchedTeam == nil {
                    let team = ALTTeam(identifier: teamIdentifier, name: account.teamName ?? teamIdentifier, type: account.teamType ?? .unknown)
                    matchedTeam = Team(team, account: activeAccount, context: context)
                }
            } else {
                let ownedTeams = dbTeams.filter { $0.account == activeAccount }
                matchedTeam = ownedTeams.first { $0.isActiveTeam } ?? (ownedTeams.count == 1 ? ownedTeams.first : nil)
            }
            guard let activeTeam = matchedTeam else { throw OperationError.notAuthenticated }

            for dbAccount in dbAccounts {
                dbAccount.isActiveAccount = dbAccount == activeAccount
            }
            activeAccount.isActiveAccount = true
            for dbTeam in dbTeams {
                dbTeam.isActiveTeam = dbTeam == activeTeam
            }
            activeTeam.isActiveTeam = true

            if context.hasChanges {
                try context.save()
            }
        }
        await self.refreshViewContext()
    }

    private func refreshViewContext() async {
        let viewContext = DatabaseManager.shared.viewContext
        await viewContext.perform {
            viewContext.processPendingChanges()
            viewContext.refreshAllObjects()
        }
    }

    // MARK: - Interrupted changes

    private static let pendingRestoreKey = "SideStoreAccountSessionPendingRestore"

    /// What to put back if the app quits during a switch, while it was still signed in as `appleID`.
    private struct PendingRestore: Codable {
        var appleID: String?
        var restoresActiveAppsLimit = false
        var activeAppsLimit: Int?
        var isDeviceRegistered: Bool?
        var restoresDatabase = false
        var accountURI: URL?
        var teamURI: URL?
    }

    private func savePendingRestore(_ pending: PendingRestore) {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        UserDefaults.standard.set(data, forKey: Self.pendingRestoreKey)
    }

    private func clearPendingRestore() {
        UserDefaults.standard.removeObject(forKey: Self.pendingRestoreKey)
    }

    /// Undoes a switch or Apple ID addition that the app quit in the middle of. Call at launch, after the database loads.
    static func restoreInterruptedChangeIfNeeded() async {
        guard let data = UserDefaults.standard.data(forKey: Self.pendingRestoreKey) else { return }
        UserDefaults.standard.removeObject(forKey: Self.pendingRestoreKey)
        guard let pending = try? JSONDecoder().decode(PendingRestore.self, from: data) else { return }

        // If the keychain already holds the new Apple ID, the change finished and there is nothing to undo.
        let current = AppleAccountStore.shared.activeAppleID ?? ""
        let previous = pending.appleID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard current.caseInsensitiveCompare(previous) == .orderedSame else { return }

        if pending.restoresActiveAppsLimit {
            UserDefaults.standard.activeAppsLimit = pending.activeAppsLimit
        }
        if let isDeviceRegistered = pending.isDeviceRegistered {
            UserDefaults.standard.isDeviceRegistered = isDeviceRegistered
        }
        if pending.restoresDatabase, Self.isDatabaseLoaded {
            let coordinator = DatabaseManager.shared.persistentContainer.persistentStoreCoordinator
            let selection = DatabaseSelection(
                account: pending.accountURI.flatMap { coordinator.managedObjectID(forURIRepresentation: $0) },
                team: pending.teamURI.flatMap { coordinator.managedObjectID(forURIRepresentation: $0) }
            )
            await AccountSessionGate.shared.restoreDatabaseSelection(selection)
        }
        debugLog("[AccountSessionGate] Restored the Apple ID state left by an interrupted switch.")
    }
}
