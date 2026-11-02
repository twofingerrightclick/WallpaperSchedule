import Foundation

/// A deliberately narrow adapter for the Sequoia native aerial format.
/// Unknown layouts fail before writing. Apple assets are never modified.
public enum WallpaperStore {
    public static func selectedAsset(in data: Data) throws -> String? {
        let store = try dictionary(data)
        guard let entry = store["AllSpacesAndDisplays"] as? [String: Any],
              let linked = entry["Linked"] as? [String: Any],
              let content = linked["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]],
              let choice = choices.first,
              choice["Provider"] as? String == "com.apple.wallpaper.choice.aerials",
              let configuration = choice["Configuration"] as? Data,
              let value = try dictionary(configuration)["assetID"] as? String else { return nil }
        return value
    }

    public static func selecting(_ assetID: String, in data: Data, now: Date = Date()) throws -> Data {
        guard UUID(uuidString: assetID) != nil else { throw WallpaperError.message("Invalid Apple wallpaper identifier.") }
        var store = try dictionary(data)
        // Per-display and per-Space overrides require a different adapter. Do not erase them.
        guard let spaces = store["Spaces"] as? [String: Any], spaces.isEmpty,
              let displays = store["Displays"] as? [String: Any], displays.isEmpty else {
            throw WallpaperError.message("Enable “Show on all Spaces” in System Settings → Wallpaper first. This app uses one wallpaper across your displays and Spaces.")
        }
        for key in ["AllSpacesAndDisplays", "SystemDefault"] {
            guard var entry = store[key] as? [String: Any], entry["Type"] as? String == "linked",
                  var linked = entry["Linked"] as? [String: Any],
                  var content = linked["Content"] as? [String: Any],
                  let choices = content["Choices"] as? [[String: Any]], choices.count == 1,
                  var choice = choices.first,
                  choice["Provider"] as? String == "com.apple.wallpaper.choice.aerials",
                  let existing = choice["Configuration"] as? Data,
                  try dictionary(existing)["assetID"] is String else {
                throw WallpaperError.message("Choose an Apple aerial in System Settings → Wallpaper and turn on “Show as Screen Saver” first, then try again. This wallpaper layout is not supported yet.")
            }
            var configuration = try dictionary(existing)
            configuration["assetID"] = assetID
            choice["Configuration"] = try PropertyListSerialization.data(fromPropertyList: configuration, format: .binary, options: 0)
            content["Choices"] = [choice]
            content.removeValue(forKey: "Shuffle")
            linked["Content"] = content
            linked["LastSet"] = now
            linked["LastUse"] = now
            entry["Linked"] = linked
            store[key] = entry
        }
        return try PropertyListSerialization.data(fromPropertyList: store, format: .binary, options: 0)
    }

    private static func dictionary(_ data: Data) throws -> [String: Any] {
        guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw WallpaperError.message("Apple’s wallpaper configuration has an unsupported format. No changes were made.")
        }
        return value
    }
}

public actor WallpaperEngine {
    public static var storeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }
    public static var supportURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/WallpaperSchedule")
    }

    public init() {}

    public func apply(_ aerial: Aerial) async throws {
        let version = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        guard (14...15).contains(version) else {
            throw WallpaperError.message("Native aerial switching currently supports macOS Sonoma and Sequoia. This macOS version needs a separate compatibility check.")
        }
        guard let size = try aerial.videoURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else {
            throw WallpaperError.message("This aerial is no longer downloaded. Download it in System Settings, then refresh.")
        }
        let settings = try SystemCommand.run("/usr/bin/pgrep", ["-x", "-u", String(getuid()), "System Settings"])
        guard settings.status == 0 || settings.status == 1 else {
            throw WallpaperError.message("Couldn’t check whether System Settings is open. No wallpaper change was made.")
        }
        guard settings.status == 1 else {
            throw WallpaperError.message("Quit System Settings before applying a wallpaper so it cannot overwrite the selection. Then try again.")
        }
        let url = Self.storeURL
        let original = try Data(contentsOf: url)
        let updated = try WallpaperStore.selecting(aerial.id, in: original)
        let directory = Self.supportURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let firstBackup = directory.appendingPathComponent("OriginalWallpaper.plist")
        if !FileManager.default.fileExists(atPath: firstBackup.path) {
            try original.write(to: firstBackup, options: .atomic)
        }
        try original.write(to: directory.appendingPathComponent("PreviousWallpaper.plist"), options: .atomic)
        // Coordination helps cooperating writers; Apple does not publish a transaction API.
        // Preserve backups and refuse when Settings is open to reduce concurrent-write risk.
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var writeError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            do {
                guard try Data(contentsOf: coordinatedURL) == original else {
                    throw WallpaperError.message("Wallpaper settings changed while applying. Try again after closing System Settings.")
                }
                try updated.write(to: coordinatedURL, options: .atomic)
            } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }
        do {
            try Self.reloadAgent()
        } catch {
            // Only roll back our own bytes, never a newer user or system write.
            if (try? Data(contentsOf: url)) == updated { try? original.write(to: url, options: .atomic) }
            throw error
        }
        // A signal being accepted does not mean macOS retained the new configuration.
        try await Task.sleep(for: .seconds(2))
        guard try WallpaperStore.selectedAsset(in: Data(contentsOf: url)) == aerial.id else {
            throw WallpaperError.message("macOS did not retain the aerial selection. Quit System Settings and try again. Your previous configuration is backed up in Library/Application Support/WallpaperSchedule.")
        }
    }

    private static func reloadAgent() throws {
        let result = try SystemCommand.run("/usr/bin/killall", ["-u", NSUserName(), "WallpaperAgent"])
        guard result.status == 0 else {
            throw WallpaperError.message("Could not refresh macOS’s wallpaper process. No wallpaper change was kept. Log out and back in, then try again.")
        }
    }
}
