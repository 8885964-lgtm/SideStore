//
//  RefreshAllDeepLink.swift
//  SideStore
//
//  sidestore://refresh-all opens My Apps and starts Refresh All, which already handles every Apple ID.
//  The widget uses it off Wi-Fi when "Open App to Refresh on Cellular" is on, because a refresh that
//  has to switch cellular data through Shortcuts can only run while SideStore is in the foreground.
//

@preconcurrency import UIKit

@MainActor
enum RefreshAllDeepLink
{
    static let host = "refresh-all"

    /// Ask the app to handle the link only when the device isn't on Wi-Fi (the tap otherwise just opens the app, as before).
    static let onlyOffWiFiQueryItem = "onlyOffWiFi"

    static let didRequestNotification = Notification.Name("io.sidestore.RefreshAllDeepLink.didRequest")

    static var url: URL {
        URL(string: "sidestore://\(Self.host)")!
    }

    static var widgetURL: URL {
        URL(string: "sidestore://\(Self.host)?\(Self.onlyOffWiFiQueryItem)=1")!
    }

    /// Set until My Apps starts the refresh, so a request made during launch isn't lost.
    private(set) static var isPending = false

    /// Opens My Apps and starts Refresh All as soon as it's on screen.
    static func request()
    {
        debugLog("[RefreshAllDeepLink] Refresh All requested.")
        self.isPending = true
        NotificationCenter.default.post(name: self.didRequestNotification, object: nil)
    }

    static func cancel()
    {
        self.isPending = false
    }

    /// Returns true once per request.
    static func consume() -> Bool
    {
        guard self.isPending else { return false }
        self.isPending = false
        return true
    }

    /// Handles sidestore://refresh-all[?onlyOffWiFi=1].
    static func handle(_ components: URLComponents) -> Bool
    {
        let onlyOffWiFi = components.queryItems?.contains { $0.name.caseInsensitiveCompare(self.onlyOffWiFiQueryItem) == .orderedSame && $0.value == "1" } ?? false
        guard onlyOffWiFi else {
            self.request()
            return true
        }

        guard AutoRefreshPreferences.widgetOpensAppOnCellular else { return true }

        Task { @MainActor in
            let isOnWiFi = await WiFiReachability.isOnWiFi()
            debugLog("[RefreshAllDeepLink] Opened from widget. On Wi-Fi: \(isOnWiFi)")
            guard !isOnWiFi else { return }
            self.request()
        }
        return true
    }
}
