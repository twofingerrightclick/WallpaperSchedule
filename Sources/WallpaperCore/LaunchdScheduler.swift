import Foundation
import Darwin

public struct CommandResult: Sendable {
    public let status: Int32
    public let output: String
}

public enum SystemCommand {
    public static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 10) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let ended = DispatchSemaphore(value: 0)
        let read = DispatchSemaphore(value: 0)
        let output = CommandOutput()
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        DispatchQueue.global().async {
            output.set(pipe.fileHandleForReading.readDataToEndOfFile())
            read.signal()
        }
        guard ended.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if ended.wait(timeout: .now() + 1) != .success { kill(process.processIdentifier, SIGKILL) }
            throw WallpaperError.message("A scheduler command timed out: \(URL(fileURLWithPath: path).lastPathComponent). Try again.")
        }
        guard read.wait(timeout: .now() + 1) == .success else {
            throw WallpaperError.message("A scheduler command did not close its output. Try again.")
        }
        return CommandResult(status: process.terminationStatus, output: String(decoding: output.get(), as: UTF8.self))
    }

    private final class CommandOutput: @unchecked Sendable {
        let lock = NSLock()
        var data = Data()
        func set(_ value: Data) { lock.lock(); defer { lock.unlock() }; data = value }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }
}

public struct WorkerPlanWindow: Codable, Sendable {
    public let validFrom: Date
    public let validUntil: Date
    public let timeZoneIdentifier: String
    public init(now: Date, calendar: Calendar = .autoupdatingCurrent) {
        validFrom = calendar.startOfDay(for: now)
        validUntil = calendar.date(byAdding: .day, value: 9, to: validFrom)!
        timeZoneIdentifier = calendar.timeZone.identifier
    }
    public func contains(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        date >= validFrom && date < validUntil && calendar.timeZone.identifier == timeZoneIdentifier
    }
}

public enum LaunchdPlan {
    public static var plannerLabel: String { AppIdentity.identifier + ".planner" }
    public static var workerLabel: String { AppIdentity.identifier + ".worker" }

    /// Calendar entries use wall-clock minutes. Round solar seconds upward so the
    /// worker never wakes just before the event it needs to evaluate.
    public static func intervals(for state: ScheduleState, now: Date, calendar: Calendar = .autoupdatingCurrent) -> [[String: Int]] {
        guard state.enabled else { return [] }
        var values = Set<CalendarEntry>()
        let day = calendar.startOfDay(for: now)
        for entry in state.entries where entry.enabled {
            if entry.solarPhase == nil {
                values.insert(CalendarEntry(hour: entry.hour, minute: entry.minute, day: nil, month: nil))
            } else {
                // Tomorrow's early event is already scheduled before maintenance at midnight.
                // A week of lookahead also tolerates a missed/failed maintenance launch.
                for offset in 0..<8 {
                    guard let date = calendar.date(byAdding: .day, value: offset, to: day),
                          let event = DailySchedule.time(for: entry, on: date, in: state, calendar: calendar) else { continue }
                    let minute = Date(timeIntervalSince1970: ceil(event.timeIntervalSince1970 / 60) * 60)
                    let components = calendar.dateComponents([.month, .day, .hour, .minute], from: minute)
                    values.insert(CalendarEntry(hour: components.hour!, minute: components.minute!, day: components.day!, month: components.month!))
                }
            }
        }
        return values.sorted().map(\.dictionary)
    }

    public static func planner(helper: URL) -> [String: Any] {
        ["Label": plannerLabel, "ProgramArguments": [helper.path, "plan"],
         "RunAtLoad": true, "StartCalendarInterval": ["Minute": 0],
         "ProcessType": "Background", "LimitLoadToSessionType": "Aqua"]
    }

    public static func worker(helper: URL, intervals: [[String: Int]]) -> [String: Any] {
        ["Label": workerLabel, "ProgramArguments": [helper.path, "run"],
         "StartCalendarInterval": intervals, "ProcessType": "Background", "LimitLoadToSessionType": "Aqua"]
    }

    private struct CalendarEntry: Hashable, Comparable {
        let hour: Int
        let minute: Int
        let day: Int?
        let month: Int?
        var dictionary: [String: Int] {
            var result = ["Hour": hour, "Minute": minute]
            result["Day"] = day; result["Month"] = month
            return result
        }
        static func < (a: Self, b: Self) -> Bool {
            [a.month ?? 0, a.day ?? 0, a.hour, a.minute].lexicographicallyPrecedes([b.month ?? 0, b.day ?? 0, b.hour, b.minute])
        }
    }
}

public struct SchedulerStatus: Codable, Sendable {
    public var lastCheck: Date?
    public var lastApplied: Date?
    public var lastHandledKey: String?
    public var failedKey: String?
    public var failedAttempts = 0
    public var lastAttempt: Date?
    public var message: String?
    public var error: String?
    public init() {}

    public static var url: URL { WallpaperEngine.supportURL.appendingPathComponent("SchedulerStatus.json") }
    public static func load(from url: URL = Self.url) -> Self {
        guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    public func save(to url: URL = Self.url) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

public struct LaunchdController {
    public let helper: URL
    public let agentsDirectory: URL
    public let domain: String
    public let windowURL: URL
    private let command: ([String]) throws -> CommandResult

    public init(helper: URL, agentsDirectory: URL? = nil, windowURL: URL? = nil, uid: UInt32 = getuid(), command: (([String]) throws -> CommandResult)? = nil) {
        self.helper = helper
        self.agentsDirectory = agentsDirectory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        self.domain = "gui/\(uid)"
        self.windowURL = windowURL ?? WallpaperEngine.supportURL.appendingPathComponent("WorkerPlanWindow.json")
        self.command = command ?? { try SystemCommand.run("/bin/launchctl", $0) }
    }

    public func configurePlanner() throws {
        try install(label: LaunchdPlan.plannerLabel, dictionary: LaunchdPlan.planner(helper: helper))
    }

    public func configureWorker(state: ScheduleState, now: Date = Date()) throws {
        let intervals = LaunchdPlan.intervals(for: state, now: now)
        if intervals.isEmpty { try remove(label: LaunchdPlan.workerLabel); return }
        try install(label: LaunchdPlan.workerLabel, dictionary: LaunchdPlan.worker(helper: helper, intervals: intervals))
        // Never freshen an old worker's validity if replacement/bootout was refused.
        try FileManager.default.createDirectory(at: windowURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(WorkerPlanWindow(now: now)).write(to: windowURL, options: .atomic)
    }

    public func stop() throws {
        try remove(label: LaunchdPlan.workerLabel)
        try remove(label: LaunchdPlan.plannerLabel)
        if FileManager.default.fileExists(atPath: windowURL.path) { try FileManager.default.removeItem(at: windowURL) }
    }

    private func loaded(_ label: String) throws -> Bool {
        try command(["print", "\(domain)/\(label)"]).status == 0
    }

    private func install(label: String, dictionary: [String: Any]) throws {
        try FileManager.default.createDirectory(at: agentsDirectory, withIntermediateDirectories: true)
        let url = agentsDirectory.appendingPathComponent(label + ".plist")
        let previousData = try? Data(contentsOf: url)
        let changed: Bool
        if let data = previousData,
           let existing = try? PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary {
            changed = !existing.isEqual(to: dictionary)
        } else { changed = true }
        let isLoaded = try loaded(label)
        // Keep disk and loaded service in agreement if launchd refuses bootout.
        // Otherwise a retry could see the new disk contents and incorrectly assume
        // the still-loaded old calendar definition already matches.
        if changed && isLoaded { try checked(["bootout", "\(domain)/\(label)"]) }
        do {
            if changed {
                let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
                try data.write(to: url, options: .atomic)
            }
            if changed || !isLoaded { try checked(["bootstrap", domain, url.path]) }
        } catch {
            if changed {
                do {
                    if try loaded(label) { try checked(["bootout", "\(domain)/\(label)"]) }
                    if let previousData { try previousData.write(to: url, options: .atomic) }
                    else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                    if isLoaded && previousData != nil { try checked(["bootstrap", domain, url.path]) }
                } catch let recoveryError {
                    throw WallpaperError.message("The scheduler update failed and its previous definition could not be restored: \(recoveryError.localizedDescription). Open settings and retry.")
                }
            }
            throw error
        }
    }

    private func remove(label: String) throws {
        if try loaded(label) { try checked(["bootout", "\(domain)/\(label)"]) }
        let url = agentsDirectory.appendingPathComponent(label + ".plist")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private func checked(_ arguments: [String]) throws {
        let result = try command(arguments)
        guard result.status == 0 else {
            throw WallpaperError.message("Couldn’t update macOS’s scheduler: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}
