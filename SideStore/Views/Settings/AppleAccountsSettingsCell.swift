//
//  AppleAccountsSettingsCell.swift
//  SideStore
//
//  The "Apple IDs" row at the bottom of the account card in Settings.
//
//  The other account rows come from the storyboard, which gives them a clear cell background.
//  A cell made in code gets UIKit's default background configuration instead (white in light mode),
//  so this cell clears it and lays out its text the same way the storyboard rows do.
//

@preconcurrency import UIKit

final class AppleAccountsSettingsCell: InsetGroupTableViewCell
{
    static let reuseIdentifier = "AppleAccountsSettingsCell"
    /// Same as the storyboard's account rows.
    static let preferredHeight: CGFloat = 51.0

    private let titleLabel = UILabel()
    private let countLabel = UILabel()
    private let chevronView = UIImageView()

    init(reuseIdentifier: String? = AppleAccountsSettingsCell.reuseIdentifier)
    {
        super.init(style: .default, reuseIdentifier: reuseIdentifier)
        self.setUpViews()
    }

    required init?(coder: NSCoder)
    {
        super.init(coder: coder)
        self.setUpViews()
    }

    override func prepareForReuse()
    {
        super.prepareForReuse()
        self.applyClearBackground()
    }

    func configure(numberOfAppleIDs: Int)
    {
        self.applyClearBackground()
        self.style = .bottom

        let count = NumberFormatter.localizedString(from: NSNumber(value: numberOfAppleIDs), number: .none)
        self.countLabel.text = count
        self.accessibilityValue = count
    }

    private func setUpViews()
    {
        self.style = .bottom
        self.isSelectable = true
        self.selectionStyle = .none
        self.accessoryType = .none
        self.applyClearBackground()
        // Same card color as the storyboard's account rows (white, 15% opacity).
        self.insetBackgroundColor = UIColor.white.withAlphaComponent(0.15)

        let title = NSLocalizedString("Apple IDs", comment: "")
        self.titleLabel.translatesAutoresizingMaskIntoConstraints = false
        self.titleLabel.text = title
        self.titleLabel.font = UIFont.systemFont(ofSize: 17)
        self.titleLabel.textColor = UIColor.white.withAlphaComponent(0.8)
        self.titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        self.titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        self.countLabel.translatesAutoresizingMaskIntoConstraints = false
        self.countLabel.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        self.countLabel.textColor = .white
        self.countLabel.textAlignment = .right
        self.countLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let chevronConfiguration = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        self.chevronView.translatesAutoresizingMaskIntoConstraints = false
        self.chevronView.image = UIImage(systemName: "chevron.right", withConfiguration: chevronConfiguration)
        self.chevronView.tintColor = UIColor.white.withAlphaComponent(0.6)
        self.chevronView.contentMode = .scaleAspectFit
        self.chevronView.setContentHuggingPriority(.required, for: .horizontal)
        self.chevronView.setContentCompressionResistancePriority(.required, for: .horizontal)

        self.contentView.addSubview(self.titleLabel)
        self.contentView.addSubview(self.countLabel)
        self.contentView.addSubview(self.chevronView)

        NSLayoutConstraint.activate([
            self.titleLabel.leadingAnchor.constraint(equalTo: self.contentView.leadingAnchor, constant: 30),
            self.titleLabel.centerYAnchor.constraint(equalTo: self.contentView.centerYAnchor),

            self.countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: self.titleLabel.trailingAnchor, constant: 12),
            self.countLabel.centerYAnchor.constraint(equalTo: self.contentView.centerYAnchor),

            self.chevronView.leadingAnchor.constraint(equalTo: self.countLabel.trailingAnchor, constant: 8),
            self.chevronView.trailingAnchor.constraint(equalTo: self.contentView.trailingAnchor, constant: -30),
            self.chevronView.centerYAnchor.constraint(equalTo: self.contentView.centerYAnchor)
        ])

        self.isAccessibilityElement = true
        self.accessibilityLabel = title
        self.accessibilityHint = NSLocalizedString("Shows the Apple IDs signed in to SideStore.", comment: "")
        self.accessibilityTraits = .button
    }

    private func applyClearBackground()
    {
        self.backgroundColor = .clear
        self.contentView.backgroundColor = .clear
        self.backgroundConfiguration = .clear()
    }
}
