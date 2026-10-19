//
//  FreeAppLimitGuard.swift
//  SideStore
//
//  iOS limits how many apps signed with free developer profiles can be installed on a device at once,
//  and it counts every Apple ID together. Signing with another free Apple ID doesn't add room, so when
//  the device is full the install would register App IDs, resign the app, and then be rejected by iOS
//  ("This device has reached the maximum number of installed apps using a free developer profile").
//  Before an install signs anything, this offers to deactivate an app instead, like activating does.
//

import UIKit
import CoreData
import SideSign

@MainActor
enum FreeAppLimitGuard
{
    /// Succeeds when the install can go ahead, after deactivating an app if the user chose one.
    /// Fails with `CancellationError` when the user cancels, or with the deactivation's error.
    static func makeRoom(forAppNamed appName: String,
                         bundleIdentifier: String?,
                         signingAppleID: String,
                         presentingViewController: UIViewController) async -> Result<Void, Error>
    {
        guard !UserDefaults.standard.isAppLimitDisabled,
              AppleAccountStore.shared.account(matching: signingAppleID)?.teamType == .free,
              let activeAppsLimit = AuthManager.shared.activeAppsLimit(for: .free)
        else { return .success(()) }

        let context = DatabaseManager.shared.viewContext
        let installedVersion = bundleIdentifier.flatMap { bundleIdentifier in
            InstalledApp.first(satisfying: NSPredicate(format: "%K == %@", #keyPath(InstalledApp.bundleIdentifier), bundleIdentifier), in: context)
        }
        if let installedVersion, installedVersion.isActive
        {
            // Updating or reinstalling an active app keeps its slot.
            return .success(())
        }

        let activeApps = InstalledApp.fetchActiveApps(in: context)
            .filter { ($0.team?.type ?? .unknown) == .free }
            .filter { $0 != installedVersion }
        let usedSlots = activeApps.map(\.requiredActiveSlots).reduce(0, +)
        guard usedSlots + 1 > activeAppsLimit else { return .success(()) }

        let candidates = activeApps
            .filter { $0.bundleIdentifier != StoreApp.altstoreAppID }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !candidates.isEmpty else { return .success(()) }

        var host = presentingViewController
        while let presented = host.presentedViewController, !presented.isBeingDismissed
        {
            host = presented
        }
        guard host.viewIfLoaded?.window != nil else { return .success(()) }

        // An IPA's bundle ID isn't known until it's unpacked, so it may be an app that's already installed.
        let choice = await self.chooseAppToDeactivate(from: candidates,
                                                      limit: activeAppsLimit,
                                                      appName: appName,
                                                      allowsInstallAnyway: bundleIdentifier == nil,
                                                      host: host)
        switch choice
        {
        case .cancel:
            return .failure(CancellationError())

        case .installAnyway:
            return .success(())

        case .deactivate(let installedApp):
            return await withCheckedContinuation { (continuation: CheckedContinuation<Result<Void, Error>, Never>) in
                AppManager.shared.deactivate(installedApp, presentingViewController: presentingViewController) { result in
                    continuation.resume(returning: result.map { _ in () })
                }
            }
        }
    }

    private enum Choice
    {
        case deactivate(InstalledApp)
        case installAnyway
        case cancel
    }

    private static func chooseAppToDeactivate(from candidates: [InstalledApp],
                                              limit: Int,
                                              appName: String,
                                              allowsInstallAnyway: Bool,
                                              host: UIViewController) async -> Choice
    {
        await withCheckedContinuation { (continuation: CheckedContinuation<Choice, Never>) in
            var didFinish = false
            let finish: (Choice) -> Void = { choice in
                guard !didFinish else { return }
                didFinish = true
                continuation.resume(returning: choice)
            }

            let limitText = NumberFormatter.localizedString(from: NSNumber(value: limit), number: .none)
            let title = String(format: NSLocalizedString("Cannot Activate More than %@ Apps", comment: ""), limitText)
            let message = String(format: NSLocalizedString("iOS allows only %1$@ apps signed with free Apple IDs to be active on this device at a time, counting every Apple ID together. Signing with another Apple ID doesn’t add room. Choose an app to deactivate so “%2$@” can be installed.", comment: ""), limitText, appName)

            let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
            for installedApp in candidates
            {
                let actionTitle = String(format: NSLocalizedString("Deactivate %@", comment: ""), installedApp.name)
                alertController.addAction(UIAlertAction(title: actionTitle, style: .default) { _ in
                    finish(.deactivate(installedApp))
                })
            }
            if allowsInstallAnyway
            {
                alertController.addAction(UIAlertAction(title: NSLocalizedString("Install Anyway", comment: ""), style: .default) { _ in
                    finish(.installAnyway)
                })
            }
            alertController.addAction(UIAlertAction(title: UIAlertAction.cancel.title, style: UIAlertAction.cancel.style) { _ in
                finish(.cancel)
            })

            host.present(alertController, animated: true)

            // UIKit drops a presentation while another one is in flight; let iOS decide then, as before.
            DispatchQueue.main.async {
                if alertController.presentingViewController == nil
                {
                    finish(.installAnyway)
                }
            }
        }
    }
}
