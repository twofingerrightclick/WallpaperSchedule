import Foundation

public struct Aerial: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let videoURL: URL
    public let previewURL: URL?

    public init(id: String, name: String, videoURL: URL, previewURL: URL?) {
        self.id = id
        self.name = name
        self.videoURL = videoURL
        self.previewURL = previewURL
    }
}

public struct AerialCatalog: Sendable {
    public let root: URL
    public init(root: URL = URL(fileURLWithPath: "/Library/Application Support/com.apple.idleassetsd")) {
        self.root = root
    }

    public func load() throws -> [Aerial] {
        let customer = root.appendingPathComponent("Customer")
        let catalogURL = customer.appendingPathComponent("entries.json")
        guard FileManager.default.fileExists(atPath: catalogURL.path) else {
            throw WallpaperError.message("Apple’s aerial catalog is not available. Download an aerial in System Settings → Wallpaper, then click Refresh.")
        }
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: catalogURL))
        let strings = localizedNames(in: customer)
        let videos = customer.appendingPathComponent("4KSDR240FPS")
        return catalog.assets.compactMap { asset in
            guard UUID(uuidString: asset.id) != nil else { return nil }
            let video = videos.appendingPathComponent(asset.id + ".mov")
            guard let values = try? video.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { return nil }
            let preview = root.appendingPathComponent("snapshots/asset-preview-\(asset.id).jpg")
            let name = asset.localizedNameKey.flatMap { strings[$0] } ?? asset.accessibilityLabel ?? "Apple aerial"
            return Aerial(id: asset.id, name: name, videoURL: video,
                          previewURL: FileManager.default.fileExists(atPath: preview.path) ? preview : nil)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func localizedNames(in customer: URL) -> [String: String] {
        let bundleURL = customer.appendingPathComponent("TVIdleScreenStrings.bundle")
        let bundle = Bundle(url: bundleURL)
        let preferred = Bundle.preferredLocalizations(from: bundle?.localizations ?? ["en"]).first ?? "en"
        for locale in [preferred, "en"] {
            let url = bundleURL.appendingPathComponent("\(locale).lproj/Localizable.nocache.strings")
            if let data = try? Data(contentsOf: url),
               let names = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] {
                return names
            }
        }
        return [:]
    }

    private struct Catalog: Decodable { let assets: [Asset] }
    private struct Asset: Decodable {
        let id: String
        let localizedNameKey: String?
        let accessibilityLabel: String?
    }
}

public enum WallpaperError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let text): text }
    }
}
