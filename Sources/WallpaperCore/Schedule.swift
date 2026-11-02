import Foundation

public struct ScheduleEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var assetID: String
    public var name: String
    public var hour: Int
    public var minute: Int
    public var enabled: Bool
    public var solarPhase: SolarPhase?

    public init(id: UUID = UUID(), assetID: String, name: String, hour: Int, minute: Int, enabled: Bool = true, solarPhase: SolarPhase? = nil) {
        self.id = id; self.assetID = assetID; self.name = name
        self.hour = hour; self.minute = minute; self.enabled = enabled
        self.solarPhase = solarPhase
    }

    public var minuteOfDay: Int { hour * 60 + minute }
    public var triggerKey: String { solarPhase.map { "solar:\($0.rawValue)" } ?? "clock:\(minuteOfDay)" }
}

public struct ScheduleState: Codable, Equatable, Sendable {
    public var version = 2
    public var enabled = true
    public var entries: [ScheduleEntry] = []
    /// A manual choice suppresses only the occurrence active when it was applied.
    public var manualOverrideKey: String?
    public var location: SolarLocation?
    public var usesCurrentLocation: Bool?
    public init() {}

    public func validate() throws {
        guard version == 2,
              entries.allSatisfy({ (0...23).contains($0.hour) && (0...59).contains($0.minute) && UUID(uuidString: $0.assetID) != nil }),
              Set(entries.map(\.id)).count == entries.count,
              Set(entries.map(\.triggerKey)).count == entries.count,
              location?.isValid != false else {
            throw WallpaperError.message("The saved schedule has an unsupported format or duplicate times. Your saved file has been left unchanged.")
        }
    }
}

public struct ScheduleOccurrence: Equatable, Sendable {
    public let entry: ScheduleEntry
    public let date: Date
    public var key: String { "\(entry.id.uuidString):\(entry.assetID):\(date.timeIntervalSince1970)" }
    public func suppressionKey(calendar: Calendar = .autoupdatingCurrent) -> String {
        let day = calendar.dateComponents([.era, .year, .month, .day], from: date)
        return "\(entry.id.uuidString):\(entry.assetID):day:\(day.era ?? 1):\(day.year ?? 0):\(day.month ?? 0):\(day.day ?? 0)"
    }
}

public enum DailySchedule {
    public static func time(for entry: ScheduleEntry, on day: Date, in state: ScheduleState, calendar: Calendar = .autoupdatingCurrent) -> Date? {
        if let phase = entry.solarPhase {
            guard let location = state.location else { return nil }
            return SolarTimes.time(for: phase, on: day, at: location, calendar: calendar)
        }
        return calendar.date(bySettingHour: entry.hour, minute: entry.minute, second: 0, of: day,
                             matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
    }
    public static func pending(in state: ScheduleState, now: Date, calendar: Calendar = .autoupdatingCurrent) -> ScheduleOccurrence? {
        guard let occurrence = current(in: state, now: now, calendar: calendar),
              occurrence.key != state.manualOverrideKey,
              occurrence.suppressionKey(calendar: calendar) != state.manualOverrideKey else { return nil }
        return occurrence
    }

    /// First occurrence in a repeated hour; advance nonexistent spring times to the next real time.
    /// Dates, rather than hour/minute comparison, prevent reverting during the repeated autumn hour.
    public static func current(in state: ScheduleState, now: Date, calendar: Calendar = .autoupdatingCurrent) -> ScheduleOccurrence? {
        guard state.enabled else { return nil }
        let start = calendar.startOfDay(for: now)
        let entries = state.entries.filter { $0.enabled && ($0.solarPhase == nil || state.location != nil) }
        guard !entries.isEmpty else { return nil }
        // At polar latitudes an event may not occur for months. Find the latest actual
        // event rather than inventing a fallback clock time. Ordinary days exit immediately.
        let lookback = entries.contains(where: { $0.solarPhase == nil }) ? 1 : 370
        for offset in 0...lookback {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: start) else { continue }
            let occurrences = entries.compactMap { entry -> ScheduleOccurrence? in
                guard let date = time(for: entry, on: day, in: state, calendar: calendar),
                      date <= now else { return nil }
                return ScheduleOccurrence(entry: entry, date: date)
            }
            if let latest = occurrences.max(by: {
                if $0.date == $1.date { return $0.entry.triggerKey < $1.entry.triggerKey }
                return $0.date < $1.date
            }) { return latest }
        }
        return nil
    }
}

public struct SchedulePersistence {
    public let url: URL
    public init(url: URL = WallpaperEngine.supportURL.appendingPathComponent("Schedule.json")) { self.url = url }

    public func load() throws -> ScheduleState {
        guard FileManager.default.fileExists(atPath: url.path) else { return ScheduleState() }
        var state = try JSONDecoder().decode(ScheduleState.self, from: Data(contentsOf: url))
        if state.version == 1 { state.version = 2 }
        try state.validate()
        return state
    }

    public func save(_ state: ScheduleState) throws {
        try state.validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}
