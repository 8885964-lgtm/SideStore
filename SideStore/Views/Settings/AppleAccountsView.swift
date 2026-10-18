//
//  AppleAccountsView.swift
//  SideStore
//
//  Add, switch, and remove Apple IDs. Credentials stay in the keychain.
//

import SwiftUI
import UIKit
import Combine
import SideSign

private extension Color {
    static let appleAccountsCard = Color.white.opacity(0.15)
}

private struct AppleAccountFailure {
    let title: String
    let message: String
}

struct AppleAccountsView: View {
    @State private var accounts: [StoredAppleAccount] = []
    @State private var activeAppleID: String?
    @State private var busyAppleID: String?
    @State private var isAdding = false
    @State private var failure: AppleAccountFailure?
    @State private var pendingRemoval: StoredAppleAccount?
    @State private var isConfirmingRemoval = false

    private var isWorking: Bool {
        self.isAdding || self.busyAppleID != nil
    }

    var body: some View {
        self.content
            .onAppear(perform: self.reload)
            .onReceive(self.accountChanges) { _ in
                self.reload()
            }
    }

    private var content: some View {
        self.scrollView
            .alert(
                Text(self.failureTitle),
                isPresented: self.isShowingFailure,
                actions: { Button("OK", role: .cancel) {} },
                message: { Text(self.failureMessage) }
            )
            .confirmationDialog(
                Text(self.removalTitle),
                isPresented: self.$isConfirmingRemoval,
                titleVisibility: .visible,
                actions: { self.removalActions },
                message: { Text(self.removalMessage) }
            )
    }

    private var scrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                self.accountsSection
                self.addSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .background(Color(uiColor: .settingsBackground).ignoresSafeArea())
    }

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            AppleAccountsSectionHeader(title: NSLocalizedString("Signed-In Apple IDs", comment: ""))
            self.accountsCard
            AppleAccountsSectionFooter(text: NSLocalizedString("Each app is refreshed with the Apple ID that signed it. The Apple ID with a checkmark is used for account settings and is suggested first when you install an app.", comment: ""))
        }
    }

    @ViewBuilder
    private var accountsCard: some View {
        if self.accounts.isEmpty {
            AppleAccountsEmptyState()
        } else {
            VStack(spacing: 0) {
                ForEach(self.accounts, id: \.appleID) { account in
                    self.row(for: account)
                }
            }
            .background(Color.appleAccountsCard)
            .cornerRadius(14)
        }
    }

    private func row(for account: StoredAppleAccount) -> AppleAccountRow {
        AppleAccountRow(
            account: account,
            isActive: self.isActive(account),
            isBusy: self.busyAppleID?.caseInsensitiveCompare(account.appleID) == .orderedSame,
            isEnabled: !self.isWorking,
            showsDivider: account.appleID != self.accounts.first?.appleID,
            select: { self.switchTo(account) },
            remove: { self.confirmRemoval(of: account) }
        )
    }

    private var addSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: self.addAccount) {
                AppleAccountsAddLabel(isAdding: self.isAdding)
            }
            .buttonStyle(.plain)
            .disabled(self.isWorking)
            .opacity(self.isWorking && !self.isAdding ? 0.5 : 1)
            .background(Color.appleAccountsCard)
            .cornerRadius(14)
            .accessibilityHint(Text("Signs in with another Apple ID and makes it the signed-in one."))
            AppleAccountsSectionFooter(text: NSLocalizedString("When more than one Apple ID is signed in, SideStore asks which one should sign each app you install.", comment: ""))
        }
    }

    @ViewBuilder
    private var removalActions: some View {
        Button(self.removalButtonTitle, role: .destructive) {
            self.removePendingAccount()
        }
        Button("Cancel", role: .cancel) {
            self.pendingRemoval = nil
        }
    }

    // MARK: - Text

    private var isShowingFailure: Binding<Bool> {
        Binding<Bool>(
            get: { self.failure != nil },
            set: { isPresented in
                if !isPresented {
                    self.failure = nil
                }
            }
        )
    }

    private var failureTitle: String {
        self.failure?.title ?? ""
    }

    private var failureMessage: String {
        self.failure?.message ?? ""
    }

    private var removalTitle: String {
        guard let account = self.pendingRemoval else { return "" }
        return String(format: NSLocalizedString("Remove %@?", comment: ""), account.appleID)
    }

    private var removalMessage: String {
        guard let account = self.pendingRemoval else { return "" }
        guard self.isActive(account) else {
            return NSLocalizedString("SideStore forgets this Apple ID’s password and certificate on this device. Apps it signed will be refreshed with the signed-in Apple ID instead.", comment: "")
        }
        if let next = self.accounts.first(where: { !self.isActive($0) }) {
            return String(format: NSLocalizedString("You’ll be signed out of this Apple ID, and %@ will become the signed-in Apple ID.", comment: ""), next.appleID)
        }
        return NSLocalizedString("You’ll be signed out. You won’t be able to install or refresh apps until you sign in again.", comment: "")
    }

    private var removalButtonTitle: String {
        guard let account = self.pendingRemoval, self.isActive(account) else {
            return NSLocalizedString("Remove Apple ID", comment: "")
        }
        return NSLocalizedString("Sign Out and Remove", comment: "")
    }

    private var accountChanges: AnyPublisher<Notification, Never> {
        NotificationCenter.default.publisher(for: AppleAccountStore.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    // MARK: - Actions

    private func isActive(_ account: StoredAppleAccount) -> Bool {
        account.appleID.caseInsensitiveCompare(self.activeAppleID ?? "") == .orderedSame
    }

    private func reload() {
        self.accounts = AppleAccountStore.shared.accounts()
        self.activeAppleID = AppleAccountStore.shared.activeAppleID
    }

    private func confirmRemoval(of account: StoredAppleAccount) {
        guard !self.isWorking else { return }
        self.pendingRemoval = account
        self.isConfirmingRemoval = true
    }

    private func addAccount() {
        guard !self.isWorking, let presenter = UIApplication.shared.topViewController() else { return }
        self.isAdding = true
        Task {
            do {
                try await AuthManager.shared.addAccount(presentingViewController: presenter)
                if let appleID = AppleAccountStore.shared.activeAppleID {
                    self.announce(String(format: NSLocalizedString("Signed in as %@.", comment: ""), appleID))
                }
            } catch is CancellationError {
            } catch {
                self.failure = AppleAccountFailure(
                    title: NSLocalizedString("Couldn’t Add Apple ID", comment: ""),
                    message: error.localizedDescription
                )
            }
            self.isAdding = false
            self.reload()
        }
    }

    private func switchTo(_ account: StoredAppleAccount) {
        guard !self.isWorking, !self.isActive(account) else { return }
        self.busyAppleID = account.appleID
        Task {
            do {
                try await AccountSessionGate.shared.useAccount(account.appleID)
                self.announce(String(format: NSLocalizedString("Signed in as %@.", comment: ""), account.appleID))
            } catch {
                let message: String
                if (error as? OperationError) == .notAuthenticated {
                    message = NSLocalizedString("SideStore couldn’t find the developer team for this Apple ID. Remove it and add it again.", comment: "")
                } else {
                    message = error.localizedDescription
                }
                self.failure = AppleAccountFailure(title: NSLocalizedString("Couldn’t Switch Apple ID", comment: ""), message: message)
            }
            self.busyAppleID = nil
            self.reload()
        }
    }

    private func removePendingAccount() {
        guard let account = self.pendingRemoval else { return }
        self.pendingRemoval = nil
        self.busyAppleID = account.appleID
        Task {
            await AuthManager.shared.removeAccount(account.appleID)
            self.busyAppleID = nil
            self.reload()
            self.announce(String(format: NSLocalizedString("Removed %@.", comment: ""), account.appleID))
        }
    }

    private func announce(_ message: String) {
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}

// MARK: - Rows

private struct AppleAccountRow: View {
    let account: StoredAppleAccount
    let isActive: Bool
    let isBusy: Bool
    let isEnabled: Bool
    let showsDivider: Bool
    let select: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if self.showsDivider {
                Rectangle()
                    .fill(Color.appleAccountsCard)
                    .frame(height: 0.5)
                    .padding(.leading, 16)
                    .accessibilityHidden(true)
            }
            self.rowContent
        }
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            self.selectButton
            self.trailingAccessory
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 60)
        .opacity(self.isEnabled || self.isBusy ? 1 : 0.5)
        .contextMenu {
            self.menuItems
        }
    }

    private var selectButton: some View {
        Button(action: self.select) {
            AppleAccountRowLabel(account: self.account, isActive: self.isActive)
        }
        .buttonStyle(.plain)
        .disabled(!self.isEnabled)
        .accessibilityLabel(Text(self.accessibilityText))
        .accessibilityValue(Text(self.accessibilityValueText))
        .accessibilityHint(Text(self.accessibilityHintText))
        .accessibilityAction(named: Text("Remove")) {
            self.remove()
        }
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        if self.isBusy {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
        } else {
            if self.isActive {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(.white)
                    .accessibilityHidden(true)
            }
            #if !os(tvOS)
            Menu {
                self.menuItems
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundColor(Color.white.opacity(0.8))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .disabled(!self.isEnabled)
            .accessibilityLabel(Text(self.menuAccessibilityLabel))
            #endif
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        if !self.isActive {
            Button(action: self.select) {
                Label(NSLocalizedString("Use This Apple ID", comment: ""), systemImage: "person.crop.circle.badge.checkmark")
            }
        }
        Button(role: .destructive, action: self.remove) {
            Label(NSLocalizedString("Remove Apple ID…", comment: ""), systemImage: "trash")
        }
    }

    private var accessibilityText: String {
        guard let detail = AppleAccountRowLabel.detail(for: self.account) else { return self.account.appleID }
        return self.account.appleID + ", " + detail
    }

    private var accessibilityValueText: String {
        self.isActive ? NSLocalizedString("Signed In", comment: "") : ""
    }

    private var accessibilityHintText: String {
        self.isActive ? "" : NSLocalizedString("Makes this the signed-in Apple ID.", comment: "")
    }

    private var menuAccessibilityLabel: String {
        String(format: NSLocalizedString("More Options for %@", comment: ""), self.account.appleID)
    }
}

private struct AppleAccountRowLabel: View {
    let account: StoredAppleAccount
    let isActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.title2)
                .foregroundColor(self.isActive ? Color.white : Color.white.opacity(0.6))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(self.account.appleID)
                    .font(.body.weight(.semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = Self.detail(for: self.account) {
                    Text(detail)
                        .font(.footnote)
                        .foregroundColor(Color.white.opacity(0.7))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    static func detail(for account: StoredAppleAccount) -> String? {
        guard let teamName = account.teamName, !teamName.isEmpty else { return nil }
        guard let teamType = account.teamType else { return teamName }
        return String(format: NSLocalizedString("%1$@ · %2$@", comment: "Developer team name, then the team type."), teamName, teamType.localizedDescription)
    }
}

private struct AppleAccountsAddLabel: View {
    let isAdding: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus.circle.fill")
                .font(.title3)
                .foregroundColor(.white)
                .accessibilityHidden(true)
            Text(self.title)
                .font(.body.weight(.semibold))
                .foregroundColor(.white)
            Spacer(minLength: 8)
            if self.isAdding {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 50)
        .contentShape(Rectangle())
    }

    private var title: String {
        self.isAdding ? NSLocalizedString("Adding Apple ID…", comment: "") : NSLocalizedString("Add Apple ID", comment: "")
    }
}

private struct AppleAccountsEmptyState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.largeTitle)
                .foregroundColor(Color.white.opacity(0.8))
                .accessibilityHidden(true)
            Text("No Apple IDs")
                .font(.headline)
                .foregroundColor(.white)
            Text("Sign in with an Apple ID to install and refresh apps.")
                .font(.subheadline)
                .foregroundColor(Color.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
        .background(Color.appleAccountsCard)
        .cornerRadius(14)
        .accessibilityElement(children: .combine)
    }
}

private struct AppleAccountsSectionHeader: View {
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

private struct AppleAccountsSectionFooter: View {
    let text: String

    var body: some View {
        Text(self.text)
            .font(.caption)
            .foregroundColor(Color.white.opacity(0.6))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
    }
}
