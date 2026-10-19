//
//  RefreshAllAppsWidgetIntent.swift
//  AltStore
//
//  Created by Riley Testut on 8/18/23.
//  Copyright © 2023 Riley Testut. All rights reserved.
//

import AppIntents

@available(iOS 17, tvOS 17, *)
struct RefreshAllAppsWidgetIntent: AppIntent, ProgressReportingIntent
{
    static var title: LocalizedStringResource { "Refresh Apps via Widget" }
    static var isDiscoverable: Bool { false } // Don't show in Shortcuts or Spotlight.
    
    #if !WIDGET_EXTENSION
    private let intent = RefreshAllAppsIntent(presentsNotifications: true, appliesAutoRefreshSchedule: true)
    #endif
    
    func perform() async throws -> some IntentResult
    {
    #if !WIDGET_EXTENSION
        if await self.continuesInAppOffWiFi()
        {
            return .result()
        }
        
        do
        {
            _ = try await self.intent.perform()
        }
        catch
        {
            debugLog("Failed to refresh apps via widget. \(error)")
        }
    #endif
        
        return .result()
    }
}

#if !WIDGET_EXTENSION
@available(iOS 17, tvOS 17, *)
private extension RefreshAllAppsWidgetIntent
{
    /// With "Open App to Refresh on Cellular" on and the device off Wi-Fi, brings SideStore to the foreground and
    /// starts Refresh All in My Apps, where switching cellular data through Shortcuts works.
    /// Returns false (refresh in the background, as before) when the setting is off, on Wi-Fi, or if iOS declines.
    func continuesInAppOffWiFi() async -> Bool
    {
        guard AutoRefreshPreferences.widgetOpensAppOnCellular else { return false }
        
        let isOnWiFi = await WiFiReachability.isOnWiFi()
        guard !isOnWiFi else { return false }
        
        debugLog("[RefreshAllAppsWidgetIntent] Not on Wi-Fi, continuing Refresh All in the app.")
        await MainActor.run {
            RefreshAllDeepLink.request()
        }
        
        do
        {
            try await self.intent.requestToContinueInForeground(nil) {
                RefreshAllDeepLink.request()
            }
            return true
        }
        catch
        {
            debugLog("[RefreshAllAppsWidgetIntent] Couldn't continue in the app, refreshing in the background. \(error)")
            await MainActor.run {
                RefreshAllDeepLink.cancel()
            }
            return false
        }
    }
}
#endif

// To ensure this intent is handled by the app itself (and not widget extension)
// we need to conform to either `ForegroundContinuableIntent` or `AudioPlaybackIntent`.
// https://mastodon.social/@mgorbach/110812347476671807
//
// Unfortunately `ForegroundContinuableIntent` is marked as unavailable in app extensions,
// so we "conform" RefreshAllAppsWidgetIntent to it in an `unavailable` extension ¯\_(ツ)_/¯
@available(iOS, unavailable)
@available(tvOS, unavailable)
extension RefreshAllAppsWidgetIntent: ForegroundContinuableIntent {}
