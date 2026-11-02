import Foundation
import WallpaperCore

actor SchedulerClient {
    static var helperURL: URL? {
        let bundle = Bundle.main.bundleURL
        guard bundle.deletingLastPathComponent().lastPathComponent == "Applications" else { return nil }
        let url = bundle.appendingPathComponent("Contents/Helpers/WallpaperScheduler")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    func run(_ arguments: [String]) throws -> String {
        guard let url = Self.helperURL else {
            throw WallpaperError.message("Install the updated Wallpaper Schedule app in Applications first.")
        }
        let result = try SystemCommand.run(url.path, arguments, timeout: 65)
        guard result.status == 0 else {
            throw WallpaperError.message(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
