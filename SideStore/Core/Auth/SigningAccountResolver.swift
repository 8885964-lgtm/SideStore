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

    /// Stored signing Apple ID, otherwise the team account recorded at install, otherwise the active Apple ID.
    static func appleID(for app: InstalledApp) -> String {
        self.read(app) { app in
            if let stored = app.signingAppleID?.trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty {
                return stored
            }
            if let recorded = app.team?.account?.appleID.trimmingCharacters(in: .whitespacesAndNewlines), !recorded.isEmpty {
                return recorded
            }
            return AuthManager.shared.currentAppleID ?? ""
        }
    }

    /// A single Apple ID when every installed-app operation agrees. Nil when the batch mixes accounts.
    static func appleID(for operations: [AppOperation]) -> String? {
        var resolved: String?
        for operation in operations {
            guard let app = operation.app as? InstalledApp else { continue }
            let appleID = self.appleID(for: app)
            guard !appleID.isEmpty else { continue }
            if let resolved, resolved.caseInsensitiveCompare(appleID) != .orderedSame {
                return nil
            }
            resolved = appleID
        }
        return resolved
    }

    /// Groups apps by signing Apple ID. The active account is refreshed first and SideStore's own account last.
    static func buckets(for apps: [InstalledApp]) -> [Bucket] {
        var order: [String] = []
        var grouped: [String: [InstalledApp]] = [:]
        var display: [String: String] = [:]
        for app in apps {
            let appleID = self.appleID(for: app)
            let key = appleID.lowercased()
            if grouped[key] == nil {
                order.append(key)
                display[key] = appleID
                grouped[key] = []
            }
            grouped[key, default: []].append(app)
        }
        let active = (AuthManager.shared.currentAppleID ?? "").lowercased()
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
