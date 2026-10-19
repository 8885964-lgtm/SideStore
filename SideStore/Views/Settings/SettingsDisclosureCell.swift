//
//  SettingsDisclosureCell.swift
//  SideStore
//
//  A Settings row made in code that looks like the storyboard's rows: a title, an optional value, and a chevron.
//  Like AppleAccountsSettingsCell, it clears UIKit's default (white) background configuration.
//

@preconcurrency import UIKit

final class SettingsDisclosureCell: InsetGroupTableViewCell
{
    static let reuseIdentifier = "SettingsDisclosureCell"
    static let preferredHeight: CGFloat = 51.0

    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private let chevronView = UIImageView()

    init(reuseIdentifier: String? = SettingsDisclosureCell.reuseIdentifier)
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

    func configure(title: String, value: String?, accessibilityHint: String?)
    {
        self.applyClearBackground()

        self.titleLabel.text = title
        self.valueLabel.text = value
        self.valueLabel.isHidden = (value ?? "").isEmpty

        self.accessibilityLabel = title
        self.accessibilityValue = value
        self.accessibilityHint = accessibilityHint
    }

    private func setUpViews()
    {
        self.isSelectable = true
        self.selectionStyle = .none
        self.accessoryType = .none
        self.applyClearBackground()
        // Same card color as the storyboard's rows (white, 15% opacity).
        self.insetBackgroundColor = UIColor.white.withAlphaComponent(0.15)

        self.titleLabel.translatesAutoresizingMaskIntoConstraints = false
        // Bold white, like the App Refresh section's storyboard rows.
        self.titleLabel.font = UIFont.boldSystemFont(ofSize: 17)
        self.titleLabel.textColor = .white
        self.titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        self.titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        self.valueLabel.translatesAutoresizingMaskIntoConstraints = false
        self.valueLabel.font = UIFont.systemFont(ofSize: 17)
        self.valueLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        self.valueLabel.textAlignment = .right
        self.valueLabel.adjustsFontSizeToFitWidth = true
        self.valueLabel.minimumScaleFactor = 0.75
        self.valueLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        self.valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let chevronConfiguration = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        self.chevronView.translatesAutoresizingMaskIntoConstraints = false
        self.chevronView.image = UIImage(systemName: "chevron.right", withConfiguration: chevronConfiguration)
        self.chevronView.tintColor = UIColor.white.withAlphaComponent(0.6)
        self.chevronView.contentMode = .scaleAspectFit
        self.chevronView.setContentHuggingPriority(.required, for: .horizontal)
        self.chevronView.setContentCompressionResistancePriority(.required, for: .horizontal)

        self.contentView.addSubview(self.titleLabel)
        self.contentView.addSubview(self.valueLabel)
        self.contentView.addSubview(self.chevronView)

        NSLayoutConstraint.activate([
            self.titleLabel.leadingAnchor.constraint(equalTo: self.contentView.leadingAnchor, constant: 30),
            self.titleLabel.centerYAnchor.constraint(equalTo: self.contentView.centerYAnchor),

            self.valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: self.titleLabel.trailingAnchor, constant: 12),
            self.valueLabel.centerYAnchor.constraint(equalTo: self.contentView.centerYAnchor),

            self.chevronView.leadingAnchor.constraint(equalTo: self.valueLabel.trailingAnchor, constant: 8),
            self.chevronView.trailingAnchor.constraint(equalTo: self.contentView.trailingAnchor, constant: -30),
            self.chevronView.centerYAnchor.constraint(equalTo: self.contentView.centerYAnchor)
        ])

        self.isAccessibilityElement = true
        self.accessibilityTraits = .button
    }

    private func applyClearBackground()
    {
        self.backgroundColor = .clear
        self.contentView.backgroundColor = .clear
        self.backgroundConfiguration = .clear()
    }
}
