//
//  AutoRefreshSettingsView.swift
//  SideStore
//
//  Settings > App Refresh > Automatic Refresh.
//  Each choice's first option keeps SideStore's original behavior, and it's the default.
//

import SwiftUI
import UIKit
#if canImport(WidgetKit)
import WidgetKit
#endif

private extension Color {
    static let autoRefreshCard = Color.white.opacity(0.15)
}

enum AutoRefreshSettingsText
{
    static var title: String { NSLocalizedString("Automatic Refresh", comment: "") }

    static func daysRemaining(_ days: Int?) -> String
    {
        guard let days else { return NSLocalizedString("Default", comment: "") }
        if days == 1
        {
            return NSLocalizedString("When 1 Day Remains", comment: "")
        }
        return String(format: NSLocalizedString("When %@ Days Remain", comment: ""), NSNumber(value: days))
    }

    static func retryInterval(_ hours: Int?) -> String
    {
        guard let hours else { return NSLocalizedString("Default", comment: "") }
        if hours == 1
        {
            return NSLocalizedString("After 1 Hour", comment: "")
        }
        return String(format: NSLocalizedString("After %@ Hours", comment: ""), NSNumber(value: hours))
    }

    /// Shown as the Settings row's value.
    static var summary: String {
        guard let days = AutoRefreshPreferences.refreshWhenDaysRemain else {
            return AutoRefreshPreferences.retryIntervalHours == nil ? NSLocalizedString("Default", comment: "") : NSLocalizedString("Custom", comment: "")
        }
        if days == 1
        {
            return NSLocalizedString("1 Day Left", comment: "")
        }
        return String(format: NSLocalizedString("%@ Days Left", comment: ""), NSNumber(value: days))
    }
}

struct AutoRefreshSettingsView: View {
    @State private var daysRemaining: Int? = AutoRefreshPreferences.refreshWhenDaysRemain
    @State private var retryInterval: Int? = AutoRefreshPreferences.retryIntervalHours
    @State private var opensAppOnCellular: Bool = AutoRefreshPreferences.widgetOpensAppOnCellular

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                self.daysRemainingSection
                self.retryIntervalSection
                self.widgetSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .background(Color(uiColor: .settingsBackground).ignoresSafeArea())
    }

    // MARK: - Sections

    private var daysRemainingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            AutoRefreshSectionHeader(title: NSLocalizedString("Refresh When Days Remain", comment: ""))
            VStack(spacing: 0) {
                AutoRefreshOptionRow(
                    title: NSLocalizedString("Default", comment: ""),
                    subtitle: NSLocalizedString("Refresh every app not refreshed in the last 6 hours", comment: ""),
                    isSelected: self.daysRemaining == nil,
                    showsDivider: false,
                    select: { self.setDaysRemaining(nil) }
                )
                ForEach(AutoRefreshPreferences.daysRemainingOptions, id: \.self) { days in
                    AutoRefreshOptionRow(
                        title: AutoRefreshSettingsText.daysRemaining(days),
                        subtitle: nil,
                        isSelected: self.daysRemaining == days,
                        showsDivider: true,
                        select: { self.setDaysRemaining(days) }
                    )
                }
            }
            .background(Color.autoRefreshCard)
            .cornerRadius(14)
            AutoRefreshSectionFooter(text: NSLocalizedString("Background refresh and the widget refresh an app only once it expires within this many days. Apps signed with a free Apple ID expire 7 days after they’re refreshed. Refresh All in My Apps always refreshes every app.", comment: ""))
        }
    }

    private var retryIntervalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            AutoRefreshSectionHeader(title: NSLocalizedString("Retry Interval After Failure", comment: ""))
            VStack(spacing: 0) {
                AutoRefreshOptionRow(
                    title: NSLocalizedString("Default", comment: ""),
                    subtitle: NSLocalizedString("Retry at the next background refresh", comment: ""),
                    isSelected: self.retryInterval == nil,
                    showsDivider: false,
                    select: { self.setRetryInterval(nil) }
                )
                ForEach(AutoRefreshPreferences.retryIntervalOptions, id: \.self) { hours in
                    AutoRefreshOptionRow(
                        title: AutoRefreshSettingsText.retryInterval(hours),
                        subtitle: nil,
                        isSelected: self.retryInterval == hours,
                        showsDivider: true,
                        select: { self.setRetryInterval(hours) }
                    )
                }
            }
            .background(Color.autoRefreshCard)
            .cornerRadius(14)
            AutoRefreshSectionFooter(text: NSLocalizedString("After an automatic refresh of an app fails, background refresh and the widget wait this long before trying that app again.", comment: ""))
        }
    }

    private var widgetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            AutoRefreshSectionHeader(title: NSLocalizedString("Widget", comment: ""))
            Toggle(isOn: self.opensAppOnCellularBinding) {
                Text(NSLocalizedString("Open App to Refresh on Cellular", comment: ""))
                    .font(.body.weight(.semibold))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.autoRefreshCard)
            .cornerRadius(14)
            AutoRefreshSectionFooter(text: NSLocalizedString("When you tap the widget’s refresh button and your device isn’t on Wi-Fi, SideStore opens to My Apps and runs Refresh All for all your Apple IDs, so cellular refresh can work. On Wi-Fi, the widget refreshes in the background as usual.", comment: ""))
        }
    }

    // MARK: - Changes

    private var opensAppOnCellularBinding: Binding<Bool> {
        Binding(
            get: { self.opensAppOnCellular },
            set: { newValue in
                self.opensAppOnCellular = newValue
                AutoRefreshPreferences.widgetOpensAppOnCellular = newValue
                Self.reloadWidgets()
            }
        )
    }

    private func setDaysRemaining(_ days: Int?)
    {
        self.daysRemaining = days
        AutoRefreshPreferences.refreshWhenDaysRemain = days
        Self.reloadWidgets()
    }

    private func setRetryInterval(_ hours: Int?)
    {
        self.retryInterval = hours
        AutoRefreshPreferences.retryIntervalHours = hours
    }

    private static func reloadWidgets()
    {
        #if canImport(WidgetKit) && !os(tvOS)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}

// MARK: - Components

private struct AutoRefreshOptionRow: View {
    let title: String
    let subtitle: String?
    let isSelected: Bool
    let showsDivider: Bool
    let select: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if self.showsDivider {
                Rectangle()
                    .fill(Color.white.opacity(0.25))
                    .frame(height: 1)
                    .padding(.leading, 16)
            }
            SwiftUI.Button(action: self.select) {
                self.label
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(self.isSelected ? [.isButton, .isSelected] : [.isButton])
        }
    }

    private var label: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(self.title)
                    .font(.body.weight(.semibold))
                    .foregroundColor(.white)
                if let subtitle = self.subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundColor(Color.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .foregroundColor(.white)
                .opacity(self.isSelected ? 1 : 0)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 51)
        .contentShape(Rectangle())
    }
}

private struct AutoRefreshSectionHeader: View {
    let title: String

    var body: some View {
        Text(self.title)
            .font(.footnote.weight(.semibold))
            .textCase(.uppercase)
            .foregroundColor(Color.white.opacity(0.6))
            .padding(.horizontal, 16)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct AutoRefreshSectionFooter: View {
    let text: String

    var body: some View {
        Text(self.text)
            .font(.caption)
            .foregroundColor(Color.white.opacity(0.6))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
    }
}
