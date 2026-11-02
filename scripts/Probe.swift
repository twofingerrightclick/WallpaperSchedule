// Development integration probe. Never runs as part of the app or unit tests.
// Compile with Sources/WallpaperCore/*.swift, then run --inspect or --live.
import Foundation

@main
struct Probe {
    static func main() async throws {
        let aerials = try AerialCatalog().load()
        print("Downloaded aerials: \(aerials.map { $0.name }.joined(separator: ", "))")
        let url = WallpaperEngine.storeURL
        let original = try Data(contentsOf: url)
        let current = try WallpaperStore.selectedAsset(in: original)
        print("Current selection: \(current ?? "none")")
        guard let alternate = aerials.first(where: { $0.id != current }) else {
            throw WallpaperError.message("Need two downloaded aerials for a switching check.")
        }
        _ = try WallpaperStore.selecting(alternate.id, in: original)
        print("Native configuration accepted by adapter.")
        guard CommandLine.arguments.contains("--live") else { return }
        // Live checks must not run while the user's schedule is active.
        let schedule = try SchedulePersistence().load()
        guard !schedule.enabled || schedule.entries.isEmpty else {
            throw WallpaperError.message("Pause the app’s schedule before running a live probe.")
        }
        let recovery = FileManager.default.temporaryDirectory.appendingPathComponent("WallpaperSchedule-probe-\(UUID().uuidString).plist")
        try original.write(to: recovery, options: .atomic)
        print("Exact pre-probe recovery copy: \(recovery.path)")
        var appliedSnapshot: Data?
        do {
            try await WallpaperEngine().apply(alternate)
            appliedSnapshot = try Data(contentsOf: url)
            try await Task.sleep(for: .seconds(3))
            guard try WallpaperStore.selectedAsset(in: Data(contentsOf: url)) == alternate.id else {
                throw WallpaperError.message("Selection did not persist five seconds after reload.")
            }
            print("PASS: \(alternate.name) selected and retained after reload.")
        } catch {
            if let appliedSnapshot { _ = try restore(original, ifUnchanged: appliedSnapshot, at: url) }
            else { print("No safe post-apply snapshot was captured. Use the recovery copy if restoration is needed.") }
            throw error
        }
        guard let appliedSnapshot, try restore(original, ifUnchanged: appliedSnapshot, at: url) else {
            print("Probe ended without restoration because native settings changed externally. Recovery: \(recovery.path)")
            return
        }
        try await Task.sleep(for: .seconds(3))
        guard try WallpaperStore.selectedAsset(in: Data(contentsOf: url)) == current else {
            throw WallpaperError.message("Original selection did not persist after restoration. Recovery: \(recovery.path)")
        }
        print("PASS: original wallpaper restored and retained. Playback requires visual verification.")
    }

    static func restore(_ data: Data, ifUnchanged snapshot: Data, at url: URL) throws -> Bool {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var writeError: Error?
        var restored = false
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do {
                // Refuse to overwrite any intervening change, including unrelated settings.
                guard try Data(contentsOf: target) == snapshot else { return }
                try data.write(to: target, options: .atomic)
                restored = true
            } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }
        guard restored else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["-u", NSUserName(), "WallpaperAgent"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw WallpaperError.message("Could not reload the restored wallpaper.") }
        return true
    }
}
