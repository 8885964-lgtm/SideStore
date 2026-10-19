//
//  AppBannerView+SigningAppleID.swift
//  SideStore
//
//  Shows which Apple ID signed an installed app when more than one is signed in.
//

import UIKit

extension AppBannerView {
    /// Call after `configure(for:action:)`. Adds the signing Apple ID as a second subtitle line when there is one to show.
    func showSigningAppleID(for installedApp: InstalledApp) {
        guard let appleID = SigningAccountResolver.displayedAppleID(for: installedApp) else {
            self.subtitleLabel.numberOfLines = 1
            self.accessibilityValue = nil
            return
        }

        let subtitle = self.subtitleLabel.text ?? ""
        self.subtitleLabel.numberOfLines = 2
        self.subtitleLabel.text = subtitle.isEmpty ? appleID : subtitle + "\n" + appleID
        self.accessibilityValue = String(format: NSLocalizedString("Signed with %@", comment: ""), appleID)
    }
}
