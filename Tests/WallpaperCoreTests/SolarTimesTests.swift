import Foundation
import Testing
@testable import WallpaperCore

struct SolarTimesTests {
    let asset = "8002C4C8-C611-4894-A068-3D3A3C03472A"
    func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    @Test func greenwichSolsticeTimesAreWithinApproximationTolerance() throws {
        let day = date("2026-06-21T12:00:00Z")
        let location = SolarLocation(latitude: 51.48, longitude: 0)
        let cal = calendar("UTC")
        let rise = try #require(SolarTimes.time(for: .morning, on: day, at: location, calendar: cal))
        let set = try #require(SolarTimes.time(for: .sunset, on: day, at: location, calendar: cal))
        #expect(abs(rise.timeIntervalSince(date("2026-06-21T03:43:00Z"))) < 10 * 60)
        #expect(abs(set.timeIntervalSince(date("2026-06-21T20:21:00Z"))) < 10 * 60)
    }

    @Test func daylightPhasesAreOrderedAndEveningIsAnHourBeforeSunset() throws {
        let day = date("2026-03-20T12:00:00Z")
        let location = SolarLocation(latitude: 37.77, longitude: -122.42)
        let cal = calendar("America/Los_Angeles")
        let phases: [SolarPhase] = [.dawn, .morning, .afternoon, .evening, .sunset, .dusk, .night]
        let times = try phases.map { try #require(SolarTimes.time(for: $0, on: day, at: location, calendar: cal)) }
        #expect(times == times.sorted())
        // Declination is refined at each event, so the difference may vary by seconds.
        #expect(abs(times[4].timeIntervalSince(times[3]) - 3600) < 60)
    }

    @Test func allEventsBelongToRequestedLocalDayAcrossDateLineAndDST() throws {
        for (zone, location) in [
            ("Pacific/Apia", SolarLocation(latitude: -13.83, longitude: -171.75)),
            ("Pacific/Auckland", SolarLocation(latitude: -36.85, longitude: 174.76)),
            ("America/Los_Angeles", SolarLocation(latitude: 34.05, longitude: -118.24))
        ] {
            let cal = calendar(zone)
            for value in ["2026-03-08T12:00:00Z", "2026-11-01T12:00:00Z"] {
                let day = date(value)
                for phase in SolarPhase.allCases {
                    let event = try #require(SolarTimes.time(for: phase, on: day, at: location, calendar: cal))
                    #expect(cal.isDate(event, inSameDayAs: day))
                }
            }
        }
    }

    @Test func polarMissingEventsAreSkippedWithoutInventingTimes() {
        let location = SolarLocation(latitude: 69.65, longitude: 18.95)
        let cal = calendar("Europe/Oslo")
        let summer = date("2026-07-01T12:00:00Z")
        #expect(SolarTimes.time(for: .morning, on: summer, at: location, calendar: cal) == nil)
        #expect(SolarTimes.time(for: .sunset, on: summer, at: location, calendar: cal) == nil)
        #expect(SolarTimes.time(for: .night, on: summer, at: location, calendar: cal) == nil)
        #expect(SolarTimes.time(for: .afternoon, on: summer, at: location, calendar: cal) != nil)
        #expect(SolarTimes.time(for: .morning, on: date("2026-12-21T12:00:00Z"), at: location, calendar: cal) == nil)
    }

    @Test func solarOnlyScheduleCatchesUpAcrossLongPolarGaps() throws {
        var state = ScheduleState()
        state.location = SolarLocation(latitude: 69.65, longitude: 18.95)
        state.entries = [ScheduleEntry(assetID: asset, name: "Sunrise", hour: 7, minute: 0, solarPhase: .morning)]
        let now = date("2026-07-01T12:00:00Z")
        let occurrence = try #require(DailySchedule.current(in: state, now: now, calendar: calendar("Europe/Oslo")))
        #expect(occurrence.date < now.addingTimeInterval(-30 * 86400))
        #expect(occurrence.date > now.addingTimeInterval(-180 * 86400))
    }

    @Test func manualSolarOverrideSurvivesCoordinateDriftUntilNextPhase() throws {
        let cal = calendar("America/Los_Angeles")
        let now = date("2026-10-30T10:00:00-07:00")
        var state = ScheduleState()
        state.location = SolarLocation(latitude: 37.77, longitude: -122.42)
        state.entries = [
            ScheduleEntry(assetID: asset, name: "Morning", hour: 7, minute: 0, solarPhase: .morning),
            ScheduleEntry(assetID: asset, name: "Sunset", hour: 19, minute: 0, solarPhase: .sunset)
        ]
        state.manualOverrideKey = try #require(DailySchedule.current(in: state, now: now, calendar: cal)).suppressionKey(calendar: cal)
        state.location = SolarLocation(latitude: 37.78, longitude: -122.41)
        let relaunched = try JSONDecoder().decode(ScheduleState.self, from: JSONEncoder().encode(state))
        #expect(DailySchedule.pending(in: relaunched, now: now, calendar: cal) == nil)
        #expect(DailySchedule.pending(in: relaunched, now: date("2026-10-30T20:00:00-07:00"), calendar: cal)?.entry.solarPhase == .sunset)
    }

    @Test func oldFixedTimeScheduleMigratesWithoutChangingEntries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistence = SchedulePersistence(url: directory.appendingPathComponent("Schedule.json"))
        let legacy = """
        {"version":1,"enabled":true,"entries":[{"id":"D9D18918-F608-4410-AD1C-E90145F06845","assetID":"\(asset)","name":"Old wallpaper","hour":7,"minute":30,"enabled":true}]}
        """
        try Data(legacy.utf8).write(to: persistence.url)
        let loaded = try persistence.load()
        #expect(loaded.version == 2)
        #expect(loaded.entries.first?.minuteOfDay == 450)
        #expect(loaded.entries.first?.solarPhase == nil)
        #expect(loaded.location == nil)
        #expect(try Data(contentsOf: persistence.url) == Data(legacy.utf8))
    }

    @Test func rejectsInvalidCoordinatesAndDuplicatePhasesButAllowsFixedAndSolarTogether() throws {
        #expect(!SolarLocation(latitude: .nan, longitude: 0).isValid)
        #expect(!SolarLocation(latitude: 0, longitude: 181).isValid)
        var state = ScheduleState()
        state.entries = [
            ScheduleEntry(assetID: asset, name: "Solar", hour: 7, minute: 0, solarPhase: .morning),
            ScheduleEntry(assetID: asset, name: "Fixed", hour: 7, minute: 0)
        ]
        try state.validate()
        state.entries[1].solarPhase = .morning
        #expect(throws: WallpaperError.self) { try state.validate() }
    }
}
