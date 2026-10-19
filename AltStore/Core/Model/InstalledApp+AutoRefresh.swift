//
//  InstalledApp+AutoRefresh.swift
//  SideStore
//
//  Applies the user's automatic refresh timing on top of the apps SideStore's original rules picked.
//

import Foundation
import CoreData

extension InstalledApp
{
    /// Keeps the apps that are due under the user's automatic refresh settings.
    /// Returns `installedApps` unchanged while the settings keep the original behavior.
    /// Call on the queue of the apps' managed object context.
    class func filterDueForAutomaticRefresh(_ installedApps: [InstalledApp], now: Date = Date()) -> [InstalledApp]
    {
        guard AutoRefreshPreferences.isCustomized else { return installedApps }

        return installedApps.filter { installedApp in
            AutoRefreshPreferences.isDueForAutomaticRefresh(bundleIdentifier: installedApp.bundleIdentifier,
                                                            expirationDate: installedApp.expirationDate,
                                                            refreshedDate: installedApp.refreshedDate,
                                                            now: now)
        }
    }
}
