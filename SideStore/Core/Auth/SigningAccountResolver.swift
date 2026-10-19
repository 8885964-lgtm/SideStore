//
//  SigningAccountResolver.swift
//  SideStore
//
//  Which Apple ID an installed app should refresh or resign with.
//

import Foundation
import CoreData

enum SigningAccountResolver {
    struct Bucket {
        var appleID: String
        var apps: [InstalledApp]
    }

    static func bundleID(for app: InstalledApp) -> String {
        self.read(app) { $0.bundleIdentifier }
    }

    /// The stored Apple ID that signed the app, otherwise the signed-in Apple ID (empty when signed out).
    static func appleID(for app: InstalledApp) -> String {
        self.appleID(
            for: app,
            storedAppleIDs: AppleAccountStore.shared.storedAppleIDs(),
            currentAppleID: AuthManager.shared.currentAppleID ?? ""
        )
    }

    /// The Apple ID recorded as having signed the app, for display. Nil unless more than one Apple ID is stored,
    /// so screens look the same as before for a single Apple ID.
    static func displayedAppleID(for app: InstalledApp) -> String? {
        guard AppleAccountStore.shared.storedAppleIDs().count > 1 else { return nil }
        let recorded: String? = self.read(app) { $0.signingAppleID ?? $0.team?.account?.appleID }
        guard let appleID = recorded?.trimmingCharacters(in: .whitespacesAndNewlines), !appleID.isEmpty else { return nil }
        return appleID
    }

    /// A single Apple ID when every installed app in the batch agrees, nil when they don't or there are none.
    /// Installs are skipped: they use the signed-in Apple ID or the one picked for the install.
    static func appleID(for operations: [AppOperation]) -> String? {
        let storedAppleIDs = AppleAccountStore.shared.storedAppleIDs()
        let currentAppleID = AuthManager.shared.currentAppleID ?? ""
        var resolved: String?
        for operation in operations {
            if case .install = operation { continue }
            guard let app = operation.app as? InstalledApp else { continue }
            let appleID = self.appleID(for: app, storedAppleIDs: storedAppleIDs, currentAppleID: currentAppleID)
            guard !appleID.isEmpty else { continue }
            if let resolved, resolved.caseInsensitiveCompare(appleID) != .orderedSame {
                return nil
            }
            resolved = appleID
        }
        return resolved
    }

    /// Groups apps by signing Apple ID. The signed-in Apple ID goes first and SideStore's own Apple ID last.
    static func buckets(for apps: [InstalledApp]) -> [Bucket] {
        let storedAppleIDs = AppleAccountStore.shared.storedAppleIDs()
        let currentAppleID = AuthManager.shared.currentAppleID ?? ""
        var order: [String] = []
        var grouped: [String: [InstalledApp]] = [:]
        var display: [String: String] = [:]
        for app in apps {
            let appleID = self.appleID(for: app, storedAppleIDs: storedAppleIDs, currentAppleID: currentAppleID)
            let key = appleID.lowercased()
            if grouped[key] == nil {
                order.append(key)
                display[key] = appleID
                grouped[key] = []
            }
            grouped[key, default: []].append(app)
        }
        let active = currentAppleID.lowercased()
        let altID = StoreApp.altstoreAppID
        var buckets = order.map { key in
            Bucket(appleID: display[key] ?? key, apps: grouped[key] ?? [])
        }
        buckets.sort { lhs, rhs in
            let lhsAlt = lhs.apps.contains { self.bundleID(for: $0) == altID }
            let rhsAlt = rhs.apps.contains { self.bundleID(for: $0) == altID }
            if lhsAlt != rhsAlt { return !lhsAlt }
            let lhsActive = lhs.appleID.lowercased() == active
            let rhsActive = rhs.appleID.lowercased() == active
            if lhsActive != rhsActive { return lhsActive }
            return false
        }
        return buckets
    }

    private static func appleID(for app: InstalledApp, storedAppleIDs: [String], currentAppleID: String) -> String {
        let candidates: [String?] = self.read(app) { app in
            [app.signingAppleID, app.team?.account?.appleID]
        }
        for recorded in candidates {
            guard let candidate = recorded?.trimmingCharacters(in: .whitespacesAndNewlines), !candidate.isEmpty else { continue }
            if let stored = storedAppleIDs.first(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
                return stored
            }
        }
        return currentAppleID
    }

    private static func read<T>(_ app: InstalledApp, _ body: (InstalledApp) -> T) -> T {
        if let context = app.managedObjectContext {
            var value: T?
            context.performAndWait {
                value = body(app)
            }
            return value!
        }
        return body(app)
    }
}
