//
//  AppleAccountStore.swift
//  SideStore
//
//  Keeps every signed-in Apple ID in the same keychain the single-account
//  flow already uses. The legacy keys remain the active account.
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
    var hasPassword: Bool
    var hasToken: Bool
    var hasCertificate: Bool

    var teamType: ALTTeamType? {
        guard let teamTypeRaw else { return nil }
        return ALTTeamType(rawValue: teamTypeRaw)
    }
}

final class AppleAccountStore: @unchecked Sendable {
    static let shared = AppleAccountStore()
    static let didChangeNotification = Notification.Name("io.sidestore.AppleAccountStore.didChange")

    private let lock = NSLock()
    private let indexKey = "appleAccountsIndex"

    private init() {
        self.lock.lock()
        self.importLegacyAccountIfNeeded()
        self.lock.unlock()
    }

    var activeAppleID: String? {
        let email = Keychain.shared.appleIDEmailAddress?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let email, !email.isEmpty else { return nil }
        return email
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

    func password(for appleID: String) -> String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let canonical = self.canonicalAppleID(matching: appleID) else { return nil }
        return Keychain.shared.storedString(for: self.key(canonical, "password"))
    }

    func adsid(for appleID: String) -> String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let canonical = self.canonicalAppleID(matching: appleID) else { return nil }
        return Keychain.shared.storedString(for: self.key(canonical, "adsid"))
    }

    func xcodeToken(for appleID: String) -> String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let canonical = self.canonicalAppleID(matching: appleID) else { return nil }
        return Keychain.shared.storedString(for: self.key(canonical, "xcodeToken"))
    }

    func certificateData(for appleID: String) -> Data? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let canonical = self.canonicalAppleID(matching: appleID) else { return nil }
        return Keychain.shared.storedData(for: self.key(canonical, "cert"))
    }

    func certificatePassword(for appleID: String) -> String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let canonical = self.canonicalAppleID(matching: appleID) else { return nil }
        return Keychain.shared.storedString(for: self.key(canonical, "certPassword"))
    }

    /// Copies the active legacy keychain account (and its Core Data team, when the store is loaded) into the multi-account index.
    func captureCurrentCredentials(postNotification: Bool = true) {
        guard let email = self.activeAppleID else { return }
        let snapshot = self.databaseSnapshot(for: email)
        self.lock.lock()
        let existing = self.readAccount(appleID: email)
        let record = StoredAppleAccount(
            appleID: email,
            accountIdentifier: snapshot?.accountIdentifier ?? existing?.accountIdentifier,
            firstName: snapshot?.firstName ?? existing?.firstName,
            lastName: snapshot?.lastName ?? existing?.lastName,
            teamIdentifier: snapshot?.teamIdentifier ?? existing?.teamIdentifier,
            teamName: snapshot?.teamName ?? existing?.teamName,
            teamTypeRaw: snapshot?.teamTypeRaw ?? existing?.teamTypeRaw,
            hasPassword: Keychain.shared.appleIDPassword != nil,
            hasToken: Keychain.shared.appleIDXcodeToken != nil,
            hasCertificate: Keychain.shared.signingCertificate != nil
        )
        self.writeSecrets(
            appleID: email,
            password: Keychain.shared.appleIDPassword,
            adsid: Keychain.shared.appleIDAdsid,
            xcodeToken: Keychain.shared.appleIDXcodeToken,
            certificate: Keychain.shared.signingCertificate,
            certificatePassword: Keychain.shared.signingCertificatePassword
        )
        self.writeMetadata(record)
        self.insertIndex(email)
        self.lock.unlock()
        if postNotification {
            self.postChange()
        }
    }

    /// Persists the active signing certificate onto whichever Apple ID is currently in the legacy keychain slot.
    func captureActiveCertificate() {
        guard let email = self.activeAppleID else { return }
        self.lock.lock()
        guard self.readIndex().contains(where: { self.same($0, email) }) else {
            self.lock.unlock()
            return
        }
        let canonical = self.canonicalAppleID(matching: email) ?? email
        Keychain.shared.setStoredData(Keychain.shared.signingCertificate, for: self.key(canonical, "cert"))
        Keychain.shared.setStoredString(Keychain.shared.signingCertificatePassword, for: self.key(canonical, "certPassword"))
        self.lock.unlock()
    }

    /// Writes a stored account into the legacy single-account keychain slots and reloads the in-memory certificate.
    func applyToLegacyKeychain(_ account: StoredAppleAccount) {
        self.lock.lock()
        let canonical = self.canonicalAppleID(matching: account.appleID) ?? account.appleID
        let password = Keychain.shared.storedString(for: self.key(canonical, "password"))
        let adsid = Keychain.shared.storedString(for: self.key(canonical, "adsid"))
        let token = Keychain.shared.storedString(for: self.key(canonical, "xcodeToken"))
        let certificate = Keychain.shared.storedData(for: self.key(canonical, "cert"))
        let certificatePassword = Keychain.shared.storedString(for: self.key(canonical, "certPassword"))
        self.lock.unlock()

        Keychain.shared.appleIDEmailAddress = canonical
        Keychain.shared.appleIDPassword = password
        Keychain.shared.appleIDAdsid = adsid
        Keychain.shared.appleIDXcodeToken = token
        if let certificate {
            Keychain.shared.signingCertificate = certificate
            Keychain.shared.signingCertificatePassword = certificatePassword
            try? CertificateManager.shared.loadActiveCertificate()
        } else {
            CertificateManager.shared.clearActiveCertificate()
        }
    }

    func remove(appleID: String) {
        self.lock.lock()
        guard let canonical = self.canonicalAppleID(matching: appleID) else {
            self.lock.unlock()
            return
        }
        for field in Self.fields {
            if field == "cert" {
                Keychain.shared.setStoredData(nil, for: self.key(canonical, field))
            } else {
                Keychain.shared.setStoredString(nil, for: self.key(canonical, field))
            }
        }
        let updated = self.readIndex().filter { !self.same($0, canonical) }
        self.writeIndex(updated)
        self.lock.unlock()
        self.postChange()
    }

    private static let fields = ["password", "adsid", "xcodeToken", "cert", "certPassword", "teamID", "teamName", "teamType", "accountID", "firstName", "lastName"]

    private func importLegacyAccountIfNeeded() {
        guard self.readIndex().isEmpty, let email = Keychain.shared.appleIDEmailAddress, !email.isEmpty else { return }
        self.writeSecrets(
            appleID: email,
            password: Keychain.shared.appleIDPassword,
            adsid: Keychain.shared.appleIDAdsid,
            xcodeToken: Keychain.shared.appleIDXcodeToken,
            certificate: Keychain.shared.signingCertificate,
            certificatePassword: Keychain.shared.signingCertificatePassword
        )
        self.writeMetadata(StoredAppleAccount(
            appleID: email,
            accountIdentifier: nil,
            firstName: nil,
            lastName: nil,
            teamIdentifier: nil,
            teamName: nil,
            teamTypeRaw: nil,
            hasPassword: Keychain.shared.appleIDPassword != nil,
            hasToken: Keychain.shared.appleIDXcodeToken != nil,
            hasCertificate: Keychain.shared.signingCertificate != nil
        ))
        self.writeIndex([email])
    }

    private func writeSecrets(appleID: String, password: String?, adsid: String?, xcodeToken: String?, certificate: Data?, certificatePassword: String?) {
        Keychain.shared.setStoredString(password, for: self.key(appleID, "password"))
        Keychain.shared.setStoredString(adsid, for: self.key(appleID, "adsid"))
        Keychain.shared.setStoredString(xcodeToken, for: self.key(appleID, "xcodeToken"))
        Keychain.shared.setStoredData(certificate, for: self.key(appleID, "cert"))
        Keychain.shared.setStoredString(certificatePassword, for: self.key(appleID, "certPassword"))
    }

    private func writeMetadata(_ account: StoredAppleAccount) {
        Keychain.shared.setStoredString(account.accountIdentifier, for: self.key(account.appleID, "accountID"))
        Keychain.shared.setStoredString(account.firstName, for: self.key(account.appleID, "firstName"))
        Keychain.shared.setStoredString(account.lastName, for: self.key(account.appleID, "lastName"))
        Keychain.shared.setStoredString(account.teamIdentifier, for: self.key(account.appleID, "teamID"))
        Keychain.shared.setStoredString(account.teamName, for: self.key(account.appleID, "teamName"))
        if let teamTypeRaw = account.teamTypeRaw {
            Keychain.shared.setStoredString(String(teamTypeRaw), for: self.key(account.appleID, "teamType"))
        }
    }

    private func readAccount(appleID: String) -> StoredAppleAccount? {
        guard self.readIndex().contains(where: { self.same($0, appleID) }) else { return nil }
        let teamType = Keychain.shared.storedString(for: self.key(appleID, "teamType")).flatMap { Int($0) }
        return StoredAppleAccount(
            appleID: appleID,
            accountIdentifier: Keychain.shared.storedString(for: self.key(appleID, "accountID")),
            firstName: Keychain.shared.storedString(for: self.key(appleID, "firstName")),
            lastName: Keychain.shared.storedString(for: self.key(appleID, "lastName")),
            teamIdentifier: Keychain.shared.storedString(for: self.key(appleID, "teamID")),
            teamName: Keychain.shared.storedString(for: self.key(appleID, "teamName")),
            teamTypeRaw: teamType,
            hasPassword: Keychain.shared.storedString(for: self.key(appleID, "password")) != nil,
            hasToken: Keychain.shared.storedString(for: self.key(appleID, "xcodeToken")) != nil,
            hasCertificate: Keychain.shared.storedData(for: self.key(appleID, "cert")) != nil
        )
    }

    private func readIndex() -> [String] {
        guard let raw = Keychain.shared.storedString(for: self.indexKey),
              let data = raw.data(using: .utf8),
              let emails = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return emails
    }

    private func writeIndex(_ emails: [String]) {
        guard let data = try? JSONEncoder().encode(emails), let raw = String(data: data, encoding: .utf8) else { return }
        Keychain.shared.setStoredString(raw, for: self.indexKey)
    }

    private func insertIndex(_ email: String) {
        var emails = self.readIndex().filter { !self.same($0, email) }
        emails.append(email)
        self.writeIndex(emails)
    }

    private func canonicalAppleID(matching appleID: String) -> String? {
        self.readIndex().first { self.same($0, appleID) }
    }

    private func same(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(rhs.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    private func key(_ email: String, _ field: String) -> String {
        let lowered = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let slot = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "_"
        }
        return "appleAccount.\(String(slot)).\(field)"
    }

    private func postChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
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
