import Foundation
import Testing
@testable import WallpaperCore

struct LaunchdPlanTests {
    let asset = "8002C4C8-C611-4894-A068-3D3A3C03472A"
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return value
    }
    @Test func fixedRulesAreDirectRecurringCalendarEvents() {
        var state = ScheduleState()
        state.entries = [ScheduleEntry(assetID: asset, name: "Morning", hour: 7, minute: 30)]
        #expect(LaunchdPlan.intervals(for: state, now: Date(), calendar: calendar) == [["Hour": 7, "Minute": 30]])
        state.enabled = false
        #expect(LaunchdPlan.intervals(for: state, now: Date(), calendar: calendar).isEmpty)
    }
    @Test func solarRulesRoundUpAndIncludeFutureDays() throws {
        var state = ScheduleState()
        state.location = SolarLocation(latitude: 37.77, longitude: -122.42)
        let entry = ScheduleEntry(assetID: asset, name: "Sunset", hour: 0, minute: 0, solarPhase: .sunset)
        state.entries = [entry]
        let now = ISO8601DateFormatter().date(from: "2026-11-01T12:00:00-08:00")!
        let event = try #require(DailySchedule.time(for: entry, on: now, in: state, calendar: calendar))
        let launch = Date(timeIntervalSince1970: ceil(event.timeIntervalSince1970 / 60) * 60)
        let parts = calendar.dateComponents([.hour, .minute, .day, .month], from: launch)
        let intervals = LaunchdPlan.intervals(for: state, now: now, calendar: calendar)
        #expect(intervals.count == 8)
        #expect(intervals.contains(["Hour": parts.hour!, "Minute": parts.minute!, "Day": parts.day!, "Month": parts.month!]))
        #expect(launch >= event && launch.timeIntervalSince(event) < 60)
    }
    @Test func jobsNeverKeepAProcessAliveAndMaintenanceIsHourly() {
        let helper = URL(fileURLWithPath: "/Applications/Wallpaper Schedule.app/Contents/Helpers/WallpaperScheduler")
        let planner = LaunchdPlan.planner(helper: helper)
        #expect(planner["KeepAlive"] == nil)
        #expect(planner["RunAtLoad"] as? Bool == true)
        #expect(planner["StartCalendarInterval"] as? [String: Int] == ["Minute": 0])
        let worker = LaunchdPlan.worker(helper: helper, intervals: [["Hour": 7, "Minute": 0]])
        #expect(worker["KeepAlive"] == nil)
        #expect(worker["RunAtLoad"] == nil)
        #expect(worker["ProgramArguments"] as? [String] == [helper.path, "run"])
    }

    @Test func replanningIsIdempotentAndEditsRemoveOldEvents() {
        var state = ScheduleState()
        state.entries = [ScheduleEntry(assetID: asset, name: "Morning", hour: 7, minute: 30)]
        let now = Date()
        #expect(LaunchdPlan.intervals(for: state, now: now, calendar: calendar) == LaunchdPlan.intervals(for: state, now: now, calendar: calendar))
        state.entries[0].hour = 9
        #expect(LaunchdPlan.intervals(for: state, now: now, calendar: calendar) == [["Hour": 9, "Minute": 30]])
        state.entries[0].enabled = false
        #expect(LaunchdPlan.intervals(for: state, now: now, calendar: calendar).isEmpty)
        state.entries = []
        #expect(LaunchdPlan.intervals(for: state, now: now, calendar: calendar).isEmpty)
    }

    @Test func datedWorkerPlanRefusesNextYearAndDifferentTimeZone() {
        let now = ISO8601DateFormatter().date(from: "2026-12-30T12:00:00-08:00")!
        let window = WorkerPlanWindow(now: now, calendar: calendar)
        #expect(window.contains(now, calendar: calendar))
        #expect(!window.contains(calendar.date(byAdding: .year, value: 1, to: now)!, calendar: calendar))
        var different = calendar
        different.timeZone = TimeZone(identifier: "Pacific/Auckland")!
        #expect(!window.contains(now, calendar: different))
    }

    @Test func subprocessFailureAndTimeoutReturnWithoutLeavingTheCallerStuck() throws {
        let failed = try SystemCommand.run("/usr/bin/false", [])
        #expect(failed.status != 0)
        let start = Date()
        #expect(throws: WallpaperError.self) { try SystemCommand.run("/bin/sleep", ["10"], timeout: 0.05) }
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func failedWorkerReplacementDoesNotFreshenPreviousValidityWindow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let windowURL = directory.appendingPathComponent("Window.json")
        let oldWindow = Data("previous-plan-validity".utf8)
        try oldWindow.write(to: windowURL)
        let controller = LaunchdController(helper: URL(fileURLWithPath: "/Applications/Wallpaper Schedule.app/Contents/Helpers/WallpaperScheduler"), agentsDirectory: directory, windowURL: windowURL, command: { arguments in
            if arguments.first == "print" { return CommandResult(status: 0, output: "loaded old worker") }
            return CommandResult(status: 1, output: "bootout refused")
        })
        var state = ScheduleState()
        state.entries = [ScheduleEntry(assetID: asset, name: "Morning", hour: 7, minute: 30)]
        #expect(throws: WallpaperError.self) { try controller.configureWorker(state: state) }
        #expect(try Data(contentsOf: windowURL) == oldWindow)
    }

    @Test func refusedBootoutKeepsOldDiskPlanAndRetryActuallyLoadsNewTime() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let helper = URL(fileURLWithPath: "/Applications/Wallpaper Schedule.app/Contents/Helpers/WallpaperScheduler")
        let workerURL = directory.appendingPathComponent(LaunchdPlan.workerLabel + ".plist")
        let windowURL = directory.appendingPathComponent("Window.json")
        let old = try PropertyListSerialization.data(fromPropertyList: LaunchdPlan.worker(helper: helper, intervals: [["Hour": 7, "Minute": 30]]), format: .xml, options: 0)
        try old.write(to: workerURL)
        let oldWindow = Data("previous-validity".utf8)
        try oldWindow.write(to: windowURL)
        var loaded = true
        var refuseBootout = true
        var loadedIntervals: [[String: Int]] = [["Hour": 7, "Minute": 30]]
        let controller = LaunchdController(helper: helper, agentsDirectory: directory, windowURL: windowURL, command: { arguments in
            switch arguments.first {
            case "print": return CommandResult(status: loaded ? 0 : 1, output: "")
            case "bootout":
                if refuseBootout { refuseBootout = false; return CommandResult(status: 1, output: "refused") }
                loaded = false
            case "bootstrap":
                let dictionary = try PropertyListSerialization.propertyList(from: Data(contentsOf: workerURL), format: nil) as! [String: Any]
                loadedIntervals = dictionary["StartCalendarInterval"] as! [[String: Int]]
                loaded = true
            default: break
            }
            return CommandResult(status: 0, output: "")
        })
        var state = ScheduleState()
        state.entries = [ScheduleEntry(assetID: asset, name: "Morning", hour: 9, minute: 0)]
        #expect(throws: WallpaperError.self) { try controller.configureWorker(state: state) }
        #expect(try Data(contentsOf: workerURL) == old)
        #expect(try Data(contentsOf: windowURL) == oldWindow)
        try controller.configureWorker(state: state)
        #expect(loadedIntervals == [["Hour": 9, "Minute": 0]])
        #expect(try JSONDecoder().decode(WorkerPlanWindow.self, from: Data(contentsOf: windowURL)).contains(Date()))
    }

    @Test func stopRemovesOnlyBothOwnedJobsAndTheirManifest() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let windowURL = directory.appendingPathComponent("Window.json")
        let sentinel = directory.appendingPathComponent("unrelated.plist")
        try Data("keep".utf8).write(to: sentinel)
        try Data().write(to: windowURL)
        let labels = Set([LaunchdPlan.plannerLabel, LaunchdPlan.workerLabel])
        for label in labels { try Data().write(to: directory.appendingPathComponent(label + ".plist")) }
        var bootedOut = Set<String>()
        let controller = LaunchdController(helper: URL(fileURLWithPath: "/helper"), agentsDirectory: directory, windowURL: windowURL, command: { arguments in
            if arguments.first == "bootout", let target = arguments.last { bootedOut.insert(String(target.split(separator: "/").last!)) }
            return CommandResult(status: 0, output: "")
        })
        try controller.stop()
        #expect(bootedOut == labels)
        for label in labels { #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(label + ".plist").path)) }
        #expect(!FileManager.default.fileExists(atPath: windowURL.path))
        #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
    }
}
