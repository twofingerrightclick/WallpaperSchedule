import Foundation

/// The bundle supplies its identity so custom local builds keep stable job labels.
/// SwiftPM tests and unpackaged command-line builds use the public default.
public enum AppIdentity {
    public static let defaultIdentifier = "local.wallpaperschedule"

    public static var identifier: String {
        var candidate = Bundle.main.bundleURL
        for _ in 0..<5 {
            if candidate.pathExtension == "app" { return identifier(in: candidate) }
            let parent = candidate.deletingLastPathComponent()
            if parent == candidate { break }
            candidate = parent
        }
        return defaultIdentifier
    }

    public static func identifier(in bundleURL: URL) -> String {
        let info = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: info),
              let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let value = dictionary["CFBundleIdentifier"] as? String,
              value.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]*$"#, options: .regularExpression) != nil else {
            return defaultIdentifier
        }
        return value
    }
}
