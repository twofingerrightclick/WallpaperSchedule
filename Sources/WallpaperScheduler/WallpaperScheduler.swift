import Foundation
import AVFoundation
import WallpaperCore

@main
struct WallpaperScheduler {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let mode = arguments.first ?? "run"
        let force = arguments.contains("--force")
        var operationLease: InstanceLease?
        defer { withExtendedLifetime(operationLease) {} }
        // Even an unexpected stalled OS API must not leave a resident scheduler.
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) { exit(124) }
        do {
            if mode == "preview", arguments.count == 2 {
                let state = try SchedulePersistence(url: URL(fileURLWithPath: arguments[1])).load()
                let data = try PropertyListSerialization.data(fromPropertyList: LaunchdPlan.worker(helper: helperURL, intervals: LaunchdPlan.intervals(for: state, now: Date())), format: .xml, options: 0)
                FileHandle.standardOutput.write(data)
                return
            }
            if mode == "status" {
                print(SchedulerStatus.load().message ?? "No scheduler run yet.")
                return
            }
            guard ["configure", "plan", "run", "manual", "stop"].contains(mode) else {
                throw WallpaperError.message("Usage: WallpaperScheduler configure|plan|run|manual <assetID>|stop|status|preview <schedule.json> [--force]")
            }
            operationLease = try InstanceLease.acquire(at: WallpaperEngine.supportURL.appendingPathComponent("SchedulerOperation.lock"), wait: true)
            let controller = LaunchdController(helper: helperURL)
            if mode == "stop" { try controller.stop(); return }
            if mode == "run" {
                guard let data = try? Data(contentsOf: controller.windowURL),
                      let window = try? JSONDecoder().decode(WorkerPlanWindow.self, from: data), window.contains(Date()) else {
                    throw WallpaperError.message("The event plan is out of date. Hourly maintenance will rebuild it, or open settings and click Refresh.")
                }
            }
            let persistence = SchedulePersistence()
            var state = try persistence.load()
            var status = SchedulerStatus.load()
            if mode == "manual" {
                guard arguments.count == 2 else { throw WallpaperError.message("Choose a downloaded Apple aerial.") }
                let id = arguments[1]
                let occurrence = DailySchedule.current(in: state, now: Date())
                let aerial = try downloaded(id)
                try await applyIfNeeded(aerial)
                state.manualOverrideKey = occurrence?.suppressionKey()
                try persistence.save(state)
                status.lastHandledKey = occurrence?.key
                status.lastApplied = Date(); status.lastCheck = Date()
                status.message = "Applied \(aerial.name). Manual choice lasts until the next scheduled change."
                status.error = nil; status.failedKey = nil; status.failedAttempts = 0
                try status.save()
                print(status.message!)
                return
            }
            let active = state.enabled && state.entries.contains(where: \.enabled)
            if mode == "configure" {
                if active { try controller.configurePlanner() }
                else { try controller.stop() }
            }
            if mode == "configure" || mode == "plan" {
                if active { try controller.configureWorker(state: state) }
                else if mode == "plan" { try controller.configureWorker(state: state) }
            }
            status.lastCheck = Date()
            guard let occurrence = DailySchedule.pending(in: state, now: Date()) else {
                status.message = active ? "macOS scheduling is ready. No change is due." : "Schedule paused or empty. No background process is needed."
                status.error = nil
                try status.save()
                print(status.message!)
                return
            }
            if !force && status.lastHandledKey == occurrence.key { try status.save(); return }
            if !force && status.failedKey == occurrence.key {
                if status.failedAttempts >= 3 { try status.save(); return }
                if let attempt = status.lastAttempt, Date().timeIntervalSince(attempt) < 60 { try status.save(); return }
            }
            do {
                let aerial = try downloaded(occurrence.entry.assetID)
                try await applyIfNeeded(aerial)
                status.lastHandledKey = occurrence.key
                status.lastApplied = Date()
                status.message = "Applied \(aerial.name). macOS will run the next scheduled change."
                status.error = nil; status.failedKey = nil; status.failedAttempts = 0
                try status.save()
                print(status.message!)
            } catch {
                status.failedAttempts = status.failedKey == occurrence.key ? status.failedAttempts + 1 : 1
                status.failedKey = occurrence.key; status.lastAttempt = Date()
                status.error = error.localizedDescription
                status.message = "Scheduled change needs attention. Open Wallpaper Schedule to retry."
                try status.save()
                throw error
            }
        } catch {
            if operationLease != nil {
                var status = SchedulerStatus.load()
                status.lastCheck = Date(); status.error = error.localizedDescription
                try? status.save()
            }
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    private static var helperURL: URL { URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath() }

    private static func downloaded(_ id: String) throws -> Aerial {
        guard let aerial = try AerialCatalog().load().first(where: { $0.id == id }) else {
            throw WallpaperError.message("The selected aerial is no longer downloaded. Download it in System Settings, then retry.")
        }
        return aerial
    }

    private static func applyIfNeeded(_ aerial: Aerial) async throws {
        if let data = try? Data(contentsOf: WallpaperEngine.storeURL),
           (try? WallpaperStore.selectedAsset(in: data)) == aerial.id { return }
        guard try await AVURLAsset(url: aerial.videoURL).load(.isPlayable) else {
            throw WallpaperError.message("This aerial’s video is not ready to play. Finish downloading it in System Settings, then retry.")
        }
        try await WallpaperEngine().apply(aerial)
    }
}
