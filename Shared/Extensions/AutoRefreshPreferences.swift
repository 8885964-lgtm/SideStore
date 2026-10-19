//
//  AutoRefreshPreferences.swift
//  SideStore
//
//  Settings that tune automatic refreshing. They live in the app group so the widget, the app,
//  and its intents all read the same values.
//
//  Every setting defaults to "unset", which keeps SideStore's original behavior exactly:
//  - Background refresh picks every active app last refreshed more than 6 hours ago.
//  - A failed refresh is tried again at the next background refresh iOS grants.
//  - The widget's Refresh button refreshes in the background on any network.
//

import Foundation

public enum AutoRefreshPreferences
{
    /// The choices offered for "Refresh When N Days Remain".
    public static let daysRemainingOptions: [Int] = [1, 2, 3, 4, 5, 6]

    /// The choices offered for "Retry Interval After Failure", in hours.
    public static let retryIntervalOptions: [Int] = [1, 3, 6, 12, 24]

    private static let daysRemainingKey = "io.sidestore.AutoRefresh.refreshWhenDaysRemain"
    private static let retryIntervalKey = "io.sidestore.AutoRefresh.retryIntervalHours"
    private static let lastFailureDatesKey = "io.sidestore.AutoRefresh.lastFailureDates"
    private static let widgetOpensAppOnCellularKey = "io.sidestore.AutoRefresh.widgetOpensAppOnCellular"

    /// The app group's defaults, so the widget and intents see the same values as the app.
    public static var defaults: UserDefaults {
        if let appGroup = Bundle.main.altstoreAppGroup, let defaults = UserDefaults(suiteName: appGroup)
        {
            return defaults
        }
        return .standard
    }

    /// Apps are refreshed automatically once they expire within this many days. `nil` keeps the original behavior.
    public static var refreshWhenDaysRemain: Int? {
        get {
            let value = self.defaults.integer(forKey: self.daysRemainingKey)
            return value > 0 ? value : nil
        }
        set {
            if let newValue, newValue > 0
            {
                self.defaults.set(newValue, forKey: self.daysRemainingKey)
            }
            else
            {
                self.defaults.removeObject(forKey: self.daysRemainingKey)
            }
        }
    }

    /// After an automatic refresh of an app fails, it isn't tried again for this many hours. `nil` keeps the original behavior.
    public static var retryIntervalHours: Int? {
        get {
            let value = self.defaults.integer(forKey: self.retryIntervalKey)
            return value > 0 ? value : nil
        }
        set {
            if let newValue, newValue > 0
            {
                self.defaults.set(newValue, forKey: self.retryIntervalKey)
            }
            else
            {
                self.defaults.removeObject(forKey: self.retryIntervalKey)
                self.defaults.removeObject(forKey: self.lastFailureDatesKey)
            }
        }
    }

    /// When on, tapping the widget's Refresh button off Wi-Fi opens SideStore and refreshes there. Off by default.
    public static var widgetOpensAppOnCellular: Bool {
        get { self.defaults.bool(forKey: self.widgetOpensAppOnCellularKey) }
        set { self.defaults.set(newValue, forKey: self.widgetOpensAppOnCellularKey) }
    }

    /// Whether the user changed any automatic refresh timing from the original behavior.
    public static var isCustomized: Bool {
        self.refreshWhenDaysRemain != nil || self.retryIntervalHours != nil
    }

    // MARK: - Failures

    /// Remembers when automatic refreshes failed, so they can wait out the retry interval.
    /// Nothing is recorded while the retry interval keeps the original behavior.
    public static func recordRefreshResults(failedBundleIdentifiers: [String], succeededBundleIdentifiers: [String], date: Date = Date())
    {
        guard self.retryIntervalHours != nil else { return }

        var dates = self.defaults.dictionary(forKey: self.lastFailureDatesKey) as? [String: Double] ?? [:]
        for bundleIdentifier in succeededBundleIdentifiers
        {
            dates.removeValue(forKey: bundleIdentifier)
        }
        for bundleIdentifier in failedBundleIdentifiers
        {
            dates[bundleIdentifier] = date.timeIntervalSince1970
        }
        self.defaults.set(dates, forKey: self.lastFailureDatesKey)
    }

    public static func lastFailureDate(forBundleIdentifier bundleIdentifier: String) -> Date?
    {
        let dates = self.defaults.dictionary(forKey: self.lastFailureDatesKey) as? [String: Double] ?? [:]
        return dates[bundleIdentifier].map { Date(timeIntervalSince1970: $0) }
    }

    // MARK: - Scheduling

    /// Whether an app should be refreshed automatically now. Always true while every setting keeps the original behavior,
    /// so callers can filter apps they already chose with SideStore's original rules.
    public static func isDueForAutomaticRefresh(bundleIdentifier: String, expirationDate: Date, refreshedDate: Date, now: Date = Date()) -> Bool
    {
        if let days = self.refreshWhenDaysRemain
        {
            let threshold = now.addingTimeInterval(TimeInterval(days) * 24 * 60 * 60)
            guard expirationDate <= threshold else { return false }
        }

        if let hours = self.retryIntervalHours,
           let lastFailureDate = self.lastFailureDate(forBundleIdentifier: bundleIdentifier),
           lastFailureDate > refreshedDate
        {
            let retryDate = lastFailureDate.addingTimeInterval(TimeInterval(hours) * 60 * 60)
            guard now >= retryDate else { return false }
        }

        return true
    }
}
