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

struct AppleAccountsView: View {
    @State private var accounts: [StoredAppleAccount] = []
    @State private var activeAppleID: String?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var pendingRemoval: StoredAppleAccount?
    @State private var confirmRemoval = false

    var body: some View {
        List {
            Section {
                if accounts.isEmpty {
                    Text("No Apple ID is signed in.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(accounts, id: \.appleID) { account in
                        Button {
                            switchTo(account)
                        } label: {
                            accountRow(account)
                        }
                        .buttonStyle(.plain)
                        .disabled(isWorking || isActive(account))
                        .swipeActions {
                            Button(role: .destructive) {
                                pendingRemoval = account
                                confirmRemoval = true
                            } label: {
                                Text("Remove")
                            }
                        }
                    }
                }
            } footer: {
                Text("SideStore refreshes each app with the Apple ID that signed it. Add another Apple ID to sign new apps with a different account.")
            }
            Section {
                Button("Add Apple ID") {
                    addAccount()
                }
                .disabled(isWorking)
            }
        }
        .navigationTitle("Apple IDs")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: AppleAccountStore.didChangeNotification)) { _ in
            reload()
        }
        .alert("Apple ID", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            "Remove this Apple ID?",
            isPresented: $confirmRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                let account = pendingRemoval
                pendingRemoval = nil
                if let account {
                    remove(account)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingRemoval = nil
            }
        } message: {
            Text(pendingRemoval.map { "Apps signed with \($0.appleID) cannot be refreshed until you sign in again." } ?? "")
        }
    }

    @ViewBuilder
    private func accountRow(_ account: StoredAppleAccount) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(account.appleID)
                    .font(.body)
                if let teamName = account.teamName, !teamName.isEmpty {
                    Text(teamDetail(account))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            if isActive(account) {
                Image(systemName: "checkmark")
                    .foregroundColor(.accentColor)
            }
        }
        .contentShape(Rectangle())
    }

    private func teamDetail(_ account: StoredAppleAccount) -> String {
        let name = account.teamName ?? ""
        if let type = account.teamType {
            return "\(name) · \(type.localizedDescription)"
        }
        return name
    }

    private func isActive(_ account: StoredAppleAccount) -> Bool {
        account.appleID.caseInsensitiveCompare(activeAppleID ?? "") == .orderedSame
    }

    private func reload() {
        accounts = AppleAccountStore.shared.accounts()
        activeAppleID = AppleAccountStore.shared.activeAppleID
    }

    private func addAccount() {
        guard let presenter = UIApplication.shared.topViewController() else { return }
        isWorking = true
        Task {
            do {
                _ = try await AuthManager.shared.signIn(presentingViewController: presenter)
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
            reload()
        }
    }

    private func switchTo(_ account: StoredAppleAccount) {
        guard !isActive(account) else { return }
        isWorking = true
        Task {
            do {
                try await AccountSessionGate.shared.useAccount(account.appleID)
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
            reload()
        }
    }

    private func remove(_ account: StoredAppleAccount) {
        pendingRemoval = nil
        isWorking = true
        Task {
            if account.appleID.caseInsensitiveCompare(AppleAccountStore.shared.activeAppleID ?? "") == .orderedSame {
                await AuthManager.shared.signOut()
            } else {
                AppleAccountStore.shared.remove(appleID: account.appleID)
            }
            isWorking = false
            reload()
        }
    }
}

private extension UIApplication {
    func topViewController(base: UIViewController? = nil) -> UIViewController? {
        let root: UIViewController?
        if let base {
            root = base
        } else {
            root = connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow)?
                .rootViewController
        }
        if let navigation = root as? UINavigationController {
            return topViewController(base: navigation.visibleViewController)
        }
        if let tab = root as? UITabBarController, let selected = tab.selectedViewController {
            return topViewController(base: selected)
        }
        if let presented = root?.presentedViewController {
            return topViewController(base: presented)
        }
        return root
    }
}
