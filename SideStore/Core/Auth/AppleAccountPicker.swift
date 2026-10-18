//
//  AppleAccountPicker.swift
//  SideStore
//
//  Shown while installing when more than one Apple ID is signed in.
//

import UIKit

@MainActor
enum AppleAccountPicker {
    /// Returns the chosen Apple ID, or nil if the user cancelled.
    /// With a single signed-in account this returns that account without presenting UI.
    static func choose(from presenter: UIViewController) async -> String? {
        let accounts = AppleAccountStore.shared.accounts()
        if accounts.count <= 1 {
            return accounts.first?.appleID ?? AppleAccountStore.shared.activeAppleID
        }
        let active = AppleAccountStore.shared.activeAppleID
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(
                title: NSLocalizedString("Sign With Apple ID", comment: ""),
                message: NSLocalizedString("Choose which Apple ID should sign this app.", comment: ""),
                preferredStyle: .actionSheet
            )
            let sorted = accounts.sorted { lhs, rhs in
                let lhsCurrent = lhs.appleID.caseInsensitiveCompare(active ?? "") == .orderedSame
                let rhsCurrent = rhs.appleID.caseInsensitiveCompare(active ?? "") == .orderedSame
                if lhsCurrent != rhsCurrent { return lhsCurrent }
                return lhs.appleID.localizedCaseInsensitiveCompare(rhs.appleID) == .orderedAscending
            }
            for account in sorted {
                let isCurrent = account.appleID.caseInsensitiveCompare(active ?? "") == .orderedSame
                let title = isCurrent
                    ? String(format: NSLocalizedString("%@ (Current)", comment: ""), account.appleID)
                    : account.appleID
                alert.addAction(UIAlertAction(title: title, style: .default) { _ in
                    continuation.resume(returning: account.appleID)
                })
            }
            alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel) { _ in
                continuation.resume(returning: nil)
            })
            let host = presenter.presentedViewController ?? presenter
            if let popover = alert.popoverPresentationController {
                popover.sourceView = host.view
                popover.sourceRect = CGRect(x: host.view.bounds.midX, y: host.view.bounds.midY, width: 1, height: 1)
                popover.permittedArrowDirections = []
            }
            host.present(alert, animated: true)
        }
    }
}
