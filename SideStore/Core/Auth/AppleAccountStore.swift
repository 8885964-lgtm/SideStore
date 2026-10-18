//
//  AppleAccountStore.swift
//  SideStore
//
//  Keeps every signed-in Apple ID in the same keychain the single-account
//  flow already uses. The legacy keys remain the signed-in account.
//

import Foundation
import CoreData
import SideSign

struct StoredAppleAccount: Equatable, Hashable, Sendable {
    var appleID: String
    var accountIdentifier: String?
    var firstName: String?
    var lastName: String?
    var teamIdentifier: String?
    var teamName: String?
    var teamTypeRaw: Int?

    var teamType: ALTTeamType? {
        guard let teamTypeRaw else { return nil }
        return ALTTeamType(rawValue: teamTypeRaw)
    }
}

final class AppleAccountStore: @unchecked Sendable {
    static let shared = AppleAccountStore()
    static let didChangeNotification = Notification.Name("io.sidestore.AppleAccountStore.didChange")

    private static let fields = ["password", "adsid", "xcodeToken", "cert", "certPassword", "teamID", "teamName", "teamType", "accountID", "firstName", "lastName"]

    private let lock = NSLock()
    private let indexKey = "appleAccountsIndex"

    private init() {
        self.lock.lock()
        self.importLegacyAccountIfNeeded()
        self.lock.unlock()
    }

    /// The Apple ID in the signed-in keychain slots, including one signed in for a single batch.
    var activeAppleID: String? {
        Self.normalized(Keychain.shared.appleIDEmailAddress)
    }

    func storedAppleIDs() -> [String] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.readIndex()
    }

    func contains(_ appleID: String) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.canonicalAppleID(matching: appleID) != nil
    }

    func accounts() -> [StoredAppleAccount] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.readIndex().compactMap { self.readAccount(appleID: $0) }
    }

    func account(matching appleID: String) -> StoredAppleAccount? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let canonical = self.canonicalAppleID(matching: appleID) else { return nil }
        return self.readAccount(appleID: canonical)
    }

    /// The keychain values that sign `account` in.
    func slots(for account: StoredAppleAccount) -> KeychainAccountSlots {
        self.lock.lock()
        defer { self.lock.unlock() }
        let appleID = self.canonicalAppleID(matching: account.appleID) ?? account.appleID
        return KeychainAccountSlots(
            appleIDEmailAddress: appleID,
            appleIDPassword: Keychain.shared.storedString(for: self.key(appleID, "password")),
            appleIDAdsid: Keychain.shared.storedString(for: self.key(appleID, "adsid")),
            appleIDXcodeToken: Keychain.shared.storedString(for: self.key(appleID, "xcodeToken")),
            signingCertificate: Keychain.shared.storedData(for: self.key(appleID, "cert")),
            signingCertificatePassword: Keychain.shared.storedString(for: self.key(appleID, "certPassword"))
        )
    }

    /// Copies the signed-in keychain slots (and the database's active team, when it belongs to them) into the store.
    func captureCurrentCredentials(postNotification: Bool = true) {
        let slots = Keychain.shared.accountSlots
        guard let email = Self.normalized(slots.appleIDEmailAddress) else { return }
        let snapshot = self.databaseSnapshot(for: email)

        self.lock.lock()
        let appleID = self.canonicalAppleID(matching: email) ?? email
        let existing = self.readAccount(appleID: appleID)
        self.writeSecrets(slots, appleID: appleID)
        self.writeMetadata(StoredAppleAccount(
            appleID: appleID,
            accountIdentifier: snapshot?.accountIdentifier ?? existing?.accountIdentifier,
            firstName: snapshot?.firstName ?? existing?.firstName,
            lastName: snapshot?.lastName ?? existing?.lastName,
            teamIdentifier: snapshot?.teamIdentifier ?? existing?.teamIdentifier,
            teamName: snapshot?.teamName ?? existing?.teamName,
            teamTypeRaw: snapshot?.teamTypeRaw ?? existing?.teamTypeRaw
        ))
        self.insertIndex(appleID)
        self.lock.unlock()

        if postNotification {
            self.postChange()
        }
    }

    /// Persists the active signing certificate onto whichever stored Apple ID is signed in.
    func captureActiveCertificate() {
        let slots = Keychain.shared.accountSlots
        guard let email = Self.normalized(slots.appleIDEmailAddress) else { return }

        self.lock.lock()
        defer { self.lock.unlock() }
        guard let appleID = self.canonicalAppleID(matching: email) else { return }
        self.write(slots.signingCertificate, forKey: self.key(appleID, "cert"))
        self.write(slots.signingCertificatePassword, forKey: self.key(appleID, "certPassword"))
    }

    func remove(appleID: String) {
        self.lock.lock()
        guard let canonical = self.canonicalAppleID(matching: appleID) else {
            self.lock.unlock()
            return
        }
        self.removeEntries(for: canonical)
        self.writeIndex(self.readIndex().filter { !self.same($0, canonical) })
        self.lock.unlock()
        self.postChange()
    }

    func removeAll() {
        self.lock.lock()
        let appleIDs = self.readIndex()
        for appleID in appleIDs {
            self.removeEntries(for: appleID)
        }
        Keychain.shared.setStoredString(nil, for: self.indexKey)
        self.lock.unlock()

        if !appleIDs.isEmpty {
            self.postChange()
        }
    }

    private func importLegacyAccountIfNeeded() {
        guard self.readIndex().isEmpty else { return }
        let slots = Keychain.shared.accountSlots
        guard let email = Self.normalized(slots.appleIDEmailAddress) else { return }
        self.writeSecrets(slots, appleID: email)
        self.writeIndex([email])
    }

    private func writeSecrets(_ slots: KeychainAccountSlots, appleID: String) {
        self.write(slots.appleIDPassword, forKey: self.key(appleID, "password"))
        self.write(slots.appleIDAdsid, forKey: self.key(appleID, "adsid"))
        self.write(slots.appleIDXcodeToken, forKey: self.key(appleID, "xcodeToken"))
        self.write(slots.signingCertificate, forKey: self.key(appleID, "cert"))
        self.write(slots.signingCertificatePassword, forKey: self.key(appleID, "certPassword"))
    }

    private func writeMetadata(_ account: StoredAppleAccount) {
        self.write(account.accountIdentifier, forKey: self.key(account.appleID, "accountID"))
        self.write(account.firstName, forKey: self.key(account.appleID, "firstName"))
        self.write(account.lastName, forKey: self.key(account.appleID, "lastName"))
        self.write(account.teamIdentifier, forKey: self.key(account.appleID, "teamID"))
        self.write(account.teamName, forKey: self.key(account.appleID, "teamName"))
        if let teamTypeRaw = account.teamTypeRaw {
            self.write(String(teamTypeRaw), forKey: self.key(account.appleID, "teamType"))
        }
    }

    private func removeEntries(for appleID: String) {
        for field in Self.fields {
            if field == "cert" {
                Keychain.shared.setStoredData(nil, for: self.key(appleID, field))
            } else {
                Keychain.shared.setStoredString(nil, for: self.key(appleID, field))
            }
        }
    }

    // Unchanged values are skipped so captures don't rewrite synchronizable keychain items.
    private func write(_ value: String?, forKey key: String) {
        guard Keychain.shared.storedString(for: key) != value else { return }
        Keychain.shared.setStoredString(value, for: key)
    }

    private func write(_ value: Data?, forKey key: String) {
        guard Keychain.shared.storedData(for: key) != value else { return }
        Keychain.shared.setStoredData(value, for: key)
    }

    private func readAccount(appleID: String) -> StoredAppleAccount? {
        guard self.readIndex().contains(where: { self.same($0, appleID) }) else { return nil }
        return StoredAppleAccount(
            appleID: appleID,
            accountIdentifier: Keychain.shared.storedString(for: self.key(appleID, "accountID")),
            firstName: Keychain.shared.storedString(for: self.key(appleID, "firstName")),
            lastName: Keychain.shared.storedString(for: self.key(appleID, "lastName")),
            teamIdentifier: Keychain.shared.storedString(for: self.key(appleID, "teamID")),
            teamName: Keychain.shared.storedString(for: self.key(appleID, "teamName")),
            teamTypeRaw: Keychain.shared.storedString(for: self.key(appleID, "teamType")).flatMap { Int($0) }
        )
    }

    private func readIndex() -> [String] {
        guard let raw = Keychain.shared.storedString(for: self.indexKey),
              let data = raw.data(using: .utf8),
              let appleIDs = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return appleIDs
    }

    private func writeIndex(_ appleIDs: [String]) {
        guard let data = try? JSONEncoder().encode(appleIDs), let raw = String(data: data, encoding: .utf8) else { return }
        self.write(raw, forKey: self.indexKey)
    }

    private func insertIndex(_ appleID: String) {
        var appleIDs = self.readIndex()
        guard !appleIDs.contains(where: { self.same($0, appleID) }) else { return }
        appleIDs.append(appleID)
        self.writeIndex(appleIDs)
    }

    private func canonicalAppleID(matching appleID: String) -> String? {
        self.readIndex().first { self.same($0, appleID) }
    }

    private func same(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(rhs.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    private func key(_ appleID: String, _ field: String) -> String {
        let lowered = appleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let slot = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "_"
        }
        return "appleAccount.\(String(slot)).\(field)"
    }

    private func postChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    private static func normalized(_ appleID: String?) -> String? {
        guard let trimmed = appleID?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private struct DatabaseSnapshot {
        var accountIdentifier: String?
        var firstName: String?
        var lastName: String?
        var teamIdentifier: String?
        var teamName: String?
        var teamTypeRaw: Int?
    }

    private func databaseSnapshot(for email: String) -> DatabaseSnapshot? {
        let coordinator = DatabaseManager.shared.persistentContainer.persistentStoreCoordinator
        guard !coordinator.persistentStores.isEmpty else { return nil }
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        var snapshot: DatabaseSnapshot?
        context.performAndWait {
            guard let dbAccount = DatabaseManager.shared.activeAccount(in: context),
                  self.same(dbAccount.appleID, email) else { return }
            var record = DatabaseSnapshot(
                accountIdentifier: dbAccount.identifier,
                firstName: dbAccount.firstName,
                lastName: dbAccount.lastName,
                teamIdentifier: nil,
                teamName: nil,
                teamTypeRaw: nil
            )
            if let team = DatabaseManager.shared.activeTeam(in: context),
               let owner = team.account,
               self.same(owner.appleID, email) {
                record.teamIdentifier = team.identifier
                record.teamName = team.name
                record.teamTypeRaw = Int(team.type.rawValue)
            }
            snapshot = record
        }
        return snapshot
    }
}
