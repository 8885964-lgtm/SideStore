//
//  InterfaceLocalizer.swift
//  AltStore
//
//  Storyboards and nibs are not localized, so the text they set is translated here at load time.
//  The English text is the key in Localizable.strings. Text without a translation (which includes
//  everything on an English device) is left exactly as Interface Builder set it.
//

@preconcurrency import UIKit

@MainActor
enum InterfaceLocalizer
{
    /// The translation of `text` for the current language, or nil when there isn't one.
    nonisolated static func translation(for text: String?) -> String?
    {
        guard let text, !text.isEmpty else { return nil }

        let missingValue = "com.sidestore.InterfaceLocalizer.missing"
        let value = Bundle.main.localizedString(forKey: text, value: missingValue, table: nil)
        guard value != missingValue, value != text else { return nil }
        return value
    }

    /// Translates the view controller's titles, bar items, and view hierarchy.
    static func localize(_ viewController: UIViewController)
    {
        if let title = self.translation(for: viewController.title)
        {
            viewController.title = title
        }
        self.localizeNavigationItem(viewController.navigationItem)
        self.localizeBarItem(viewController.tabBarItem)

        if viewController.isViewLoaded
        {
            self.localize(viewController.view)
        }
    }

    static func localizeNavigationItem(_ navigationItem: UINavigationItem)
    {
        if let title = self.translation(for: navigationItem.title)
        {
            navigationItem.title = title
        }
        #if !os(tvOS)
        if let title = self.translation(for: navigationItem.prompt)
        {
            navigationItem.prompt = title
        }
        if let title = self.translation(for: navigationItem.backButtonTitle)
        {
            navigationItem.backButtonTitle = title
        }
        #endif
        for item in (navigationItem.leftBarButtonItems ?? []) + (navigationItem.rightBarButtonItems ?? [])
        {
            self.localizeBarItem(item)
        }
    }

    static func localizeBarItem(_ item: UIBarItem?)
    {
        guard let item else { return }
        if let title = self.translation(for: item.title)
        {
            item.title = title
        }
    }

    /// Translates the text of labels, buttons, text fields, and segmented controls in `view` and its subviews.
    static func localize(_ view: UIView)
    {
        switch view
        {
        case let label as UILabel:
            if let text = self.translation(for: label.text)
            {
                label.text = text
            }

        case let button as UIButton:
            // The button's own title label is handled through the button, so its subviews are skipped.
            self.localizeButton(button)
            return

        case let textField as UITextField:
            if let placeholder = self.translation(for: textField.placeholder)
            {
                textField.placeholder = placeholder
            }
            return

        case let segmentedControl as UISegmentedControl:
            for index in 0 ..< segmentedControl.numberOfSegments
            {
                if let title = self.translation(for: segmentedControl.titleForSegment(at: index))
                {
                    segmentedControl.setTitle(title, forSegmentAt: index)
                }
            }
            return

        default:
            break
        }

        for subview in view.subviews
        {
            self.localize(subview)
        }
    }

    private static func localizeButton(_ button: UIButton)
    {
        if var configuration = button.configuration
        {
            if let title = self.translation(for: configuration.title)
            {
                configuration.title = title
                button.configuration = configuration
            }
            return
        }

        if let title = self.translation(for: button.title(for: .normal))
        {
            button.setTitle(title, for: .normal)
        }
    }
}
