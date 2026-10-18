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
    /// With one stored Apple ID, or nowhere to show the choice, this returns the signed-in one without asking.
    static func choose(from presenter: UIViewController, appName: String) async -> String? {
        let accounts = AppleAccountStore.shared.accounts()
        let active = AppleAccountStore.shared.activeAppleID
        let fallback = active ?? accounts.first?.appleID

        var host = presenter
        while let presented = host.presentedViewController, !presented.isBeingDismissed {
            host = presented
        }
        guard accounts.count > 1, host.viewIfLoaded?.window != nil else {
            return fallback
        }

        return await withCheckedContinuation { continuation in
            var didFinish = false
            let finish: (String?) -> Void = { appleID in
                guard !didFinish else { return }
                didFinish = true
                continuation.resume(returning: appleID)
            }

            let alert = UIAlertController(
                title: NSLocalizedString("Choose an Apple ID", comment: ""),
                message: String(format: NSLocalizedString("The Apple ID you choose signs “%@” and is used to refresh it from now on.", comment: ""), appName),
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
                    finish(account.appleID)
                })
            }
            alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel) { _ in
                finish(nil)
            })

            #if !os(tvOS)
            if let popover = alert.popoverPresentationController {
                popover.sourceView = host.view
                popover.sourceRect = CGRect(x: host.view.bounds.midX, y: host.view.bounds.midY, width: 1, height: 1)
                popover.permittedArrowDirections = []
            }
            #endif

            host.present(alert, animated: true)

            // UIKit drops the presentation when another one is in flight; install with the signed-in Apple ID then.
            DispatchQueue.main.async {
                if alert.presentingViewController == nil {
                    finish(fallback)
                }
            }
        }
    }
}
