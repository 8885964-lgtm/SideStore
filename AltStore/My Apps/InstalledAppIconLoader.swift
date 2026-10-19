//
//  InstalledAppIconLoader.swift
//  SideStore
//
//  Loads the icons shown in My Apps, and always produces one so the cell's spinner can stop.
//
//  The original loader (InstalledApp.loadIcon) is tried first. It reads only the last file in
//  CFBundleIcons > CFBundlePrimaryIcon > CFBundleIconFiles (or CFBundleIconFile), so it returns nil
//  for apps whose icon lives only in Assets.car, uses ~ipad or other suffixed file names, or whose
//  cached bundle is missing. My Apps' data source never calls back when the loader returns nil,
//  which left those cells spinning forever. The fallbacks here cover those cases.
//

@preconcurrency import UIKit
import Nuke

@MainActor
enum InstalledAppIconLoader
{
    /// The icon for an installed app: the original loader's, then one found in the app bundle,
    /// then the source's icon, and finally a placeholder. Never nil.
    static func icon(for installedApp: InstalledApp) async -> UIImage
    {
        do
        {
            if let icon = try await installedApp.loadIcon()
            {
                return icon
            }
        }
        catch
        {
            debugLog("[InstalledAppIconLoader] Original icon loader failed for \(installedApp.bundleIdentifier), trying fallbacks. \(error)")
        }

        var bundleURLs = [installedApp.fileURL, installedApp.directoryURL.appendingPathComponent("App.app")]
        if installedApp.bundleIdentifier == StoreApp.altstoreAppID
        {
            bundleURLs.append(Bundle.main.bundleURL)
        }
        let candidateURLs = bundleURLs

        let bundleIcon = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            var checkedPaths = Set<String>()
            for bundleURL in candidateURLs
            {
                guard checkedPaths.insert(bundleURL.standardizedFileURL.path).inserted else { continue }
                if let icon = AppBundleIconExtractor.icon(inBundleAt: bundleURL)
                {
                    return icon
                }
            }
            return nil
        }.value

        if let bundleIcon
        {
            return bundleIcon
        }

        if let iconURL = installedApp.storeApp?.iconURL,
           let sourceIcon = try? await ImagePipeline.shared.image(for: iconURL)
        {
            return sourceIcon
        }

        debugLog("[InstalledAppIconLoader] No icon found for \(installedApp.bundleIdentifier), using placeholder.")
        return self.placeholderIcon
    }

    /// For the Updates section: the source's icon (the original behavior), then the installed app's icon.
    static func updateIcon(for installedApp: InstalledApp) async -> UIImage
    {
        if let iconURL = installedApp.storeApp?.iconURL
        {
            do
            {
                return try await ImagePipeline.shared.image(for: iconURL)
            }
            catch
            {
                debugLog("[InstalledAppIconLoader] Failed to load source icon for \(installedApp.bundleIdentifier), using the installed app's icon. \(error)")
            }
        }

        return await self.icon(for: installedApp)
    }

    static var placeholderIcon: UIImage {
        if let cachedPlaceholderIcon
        {
            return cachedPlaceholderIcon
        }

        let size = CGSize(width: 180, height: 180)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1

        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(white: 0.9, alpha: 1.0).setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let configuration = UIImage.SymbolConfiguration(pointSize: 84, weight: .regular)
            if let symbol = UIImage(systemName: "app.dashed", withConfiguration: configuration)?.withTintColor(UIColor(white: 0.6, alpha: 1.0), renderingMode: .alwaysOriginal)
            {
                let origin = CGPoint(x: (size.width - symbol.size.width) / 2, y: (size.height - symbol.size.height) / 2)
                symbol.draw(at: origin)
            }
        }

        cachedPlaceholderIcon = image
        return image
    }

    private static var cachedPlaceholderIcon: UIImage?
}

/// Finds an app's icon inside its bundle without relying on a single Info.plist entry.
enum AppBundleIconExtractor
{
    private static let defaultIconNames = ["AppIcon60x60", "AppIcon76x76", "AppIcon83.5x83.5", "AppIcon", "Icon-60", "Icon-76", "Icon", "icon"]

    private static let fileSuffixes = ["@3x.png", "@2x.png", ".png",
                                       "@3x~iphone.png", "@2x~iphone.png", "~iphone.png",
                                       "@2x~ipad.png", "~ipad.png",
                                       ""]

    /// The best icon in the bundle at `bundleURL`: the largest PNG named by the Info.plist icon entries
    /// (or the usual default names), then the app icon in Assets.car.
    static func icon(inBundleAt bundleURL: URL) -> UIImage?
    {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: bundleURL.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }

        let infoDictionary = self.infoDictionary(inBundleAt: bundleURL)
        let (fileNames, assetNames) = self.iconNames(in: infoDictionary)

        if let icon = self.largestIconFile(named: fileNames + self.defaultIconNames, inBundleAt: bundleURL)
        {
            return icon
        }

        let assetCatalogURL = bundleURL.appendingPathComponent("Assets.car")
        if fileManager.fileExists(atPath: assetCatalogURL.path), let bundle = Bundle(url: bundleURL)
        {
            let traits = UITraitCollection(displayScale: 3)
            for name in assetNames + ["AppIcon"]
            {
                if let icon = UIImage(named: name, in: bundle, compatibleWith: traits)
                {
                    return icon
                }
            }
        }

        return nil
    }

    private static func infoDictionary(inBundleAt bundleURL: URL) -> [String: Any]
    {
        let infoURL = bundleURL.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any]
        else { return [:] }
        return dictionary
    }

    /// File names from every known icon key, and asset catalog names from CFBundleIconName.
    private static func iconNames(in infoDictionary: [String: Any]) -> (fileNames: [String], assetNames: [String])
    {
        var fileNames: [String] = []
        var assetNames: [String] = []

        func addFileNames(_ value: Any?)
        {
            if let names = value as? [String]
            {
                // The last entry is usually the largest.
                fileNames.append(contentsOf: names.reversed())
            }
            else if let name = value as? String
            {
                fileNames.append(name)
            }
        }

        func addAssetName(_ value: Any?)
        {
            if let name = value as? String, !name.isEmpty
            {
                assetNames.append(name)
            }
        }

        for key in ["CFBundleIcons", "CFBundleIcons~ipad", "CFBundleIcons~iphone"]
        {
            guard let icons = infoDictionary[key] as? [String: Any] else { continue }

            if let primaryIcon = icons["CFBundlePrimaryIcon"] as? [String: Any]
            {
                addFileNames(primaryIcon["CFBundleIconFiles"])
                addAssetName(primaryIcon["CFBundleIconName"])
                addFileNames(primaryIcon["CFBundleIconName"])
            }
            else
            {
                addFileNames(icons["CFBundlePrimaryIcon"])
            }
        }

        addFileNames(infoDictionary["CFBundleIconFiles"])
        addFileNames(infoDictionary["CFBundleIconFiles~ipad"])
        addFileNames(infoDictionary["CFBundleIconFile"])
        addAssetName(infoDictionary["CFBundleIconName"])
        addFileNames(infoDictionary["CFBundleIconName"])

        return (fileNames, assetNames)
    }

    private static func largestIconFile(named names: [String], inBundleAt bundleURL: URL) -> UIImage?
    {
        let bundleContents = (try? FileManager.default.contentsOfDirectory(atPath: bundleURL.path)) ?? []
        let lowercasedContents = bundleContents.map { ($0, $0.lowercased()) }

        var candidatePaths: [String] = []
        var seenPaths = Set<String>()
        func addCandidate(_ fileName: String)
        {
            guard seenPaths.insert(fileName).inserted else { return }
            candidatePaths.append(fileName)
        }

        for rawName in names where !rawName.isEmpty
        {
            let name = rawName.lowercased().hasSuffix(".png") ? String(rawName.dropLast(4)) : rawName

            for suffix in self.fileSuffixes
            {
                let fileName = name + suffix
                if bundleContents.contains(fileName)
                {
                    addCandidate(fileName)
                }
            }

            // Variants with other scale or device suffixes, e.g. "AppIcon60x60@2x.png" for "AppIcon60x60", in any letter case.
            let lowercasedName = name.lowercased()
            for (fileName, lowercasedFileName) in lowercasedContents where lowercasedFileName.hasPrefix(lowercasedName) && lowercasedFileName.hasSuffix(".png")
            {
                addCandidate(fileName)
            }
        }

        var bestImage: UIImage?
        var bestWidth: CGFloat = 0
        for fileName in candidatePaths
        {
            let path = bundleURL.appendingPathComponent(fileName).path
            guard let image = UIImage(contentsOfFile: path) else { continue }

            let width = image.size.width * image.scale
            if width > bestWidth
            {
                bestImage = image
                bestWidth = width
            }
        }
        return bestImage
    }
}
