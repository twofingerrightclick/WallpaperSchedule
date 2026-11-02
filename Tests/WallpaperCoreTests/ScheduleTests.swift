import Foundation
import Testing
@testable import WallpaperCore

struct ScheduleTests {
    let asset = "8002C4C8-C611-4894-A068-3D3A3C03472A"
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return value
    }
    func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
    func state(_ times: [(Int, Int)]) -> ScheduleState {
        var s = ScheduleState()
        s.entries = times.map { ScheduleEntry(assetID: asset, name: "Aerial", hour: $0.0, minute: $0.1) }
        return s
    }

    @Test func testBeforeFirstTimeUsesPreviousEveningAndExactBoundaryUsesNewEntry() throws {
        let s = state([(7, 0), (19, 0)])
        let early = try #require(DailySchedule.current(in: s, now: date("2026-10-30T06:00:00-07:00"), calendar: calendar))
        #expect(early.entry.id == s.entries[1].id)
        #expect(early.date == date("2026-10-29T19:00:00-07:00"))
        #expect(DailySchedule.current(in: s, now: date("2026-10-30T07:00:00-07:00"), calendar: calendar)?.entry.id == s.entries[0].id)
    }

    @Test func testDisabledEntriesAndPausedScheduleAreSkipped() {
        var s = state([(7, 0), (19, 0)])
        s.entries[1].enabled = false
        #expect(DailySchedule.current(in: s, now: date("2026-10-30T20:00:00-07:00"), calendar: calendar)?.entry.id == s.entries[0].id)
        s.enabled = false
        #expect(DailySchedule.current(in: s, now: Date(), calendar: calendar) == nil)
        #expect(DailySchedule.current(in: ScheduleState(), now: Date(), calendar: calendar) == nil)
    }

    @Test func testFallBackDoesNotRevertDuringSecondRepeatedHour() {
        let s = state([(0, 0), (1, 30)])
        let now = date("2026-11-01T01:15:00-08:00")
        let occurrence = DailySchedule.current(in: s, now: now, calendar: calendar)
        #expect(occurrence?.entry.id == s.entries[1].id)
        #expect(occurrence?.date == date("2026-11-01T01:30:00-07:00"))
    }

    @Test func testSpringForwardUsesNextValidTime() {
        let s = state([(0, 0), (2, 30)])
        #expect(DailySchedule.current(in: s, now: date("2026-03-08T03:00:00-07:00"), calendar: calendar)?.entry.id == s.entries[1].id)
    }

    @Test func testPersistenceRoundTripAndMalformedFileIsNotOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = SchedulePersistence(url: directory.appendingPathComponent("Schedule.json"))
        #expect(try persistence.load() == ScheduleState())
        let original = state([(7, 0)])
        try persistence.save(original)
        #expect(try persistence.load() == original)
        let badData = Data("{invalid}".utf8)
        try badData.write(to: persistence.url)
        #expect(throws: (any Error).self) { try persistence.load() }
        #expect(try Data(contentsOf: persistence.url) == badData)
    }

    @Test func testRejectsDuplicateAndInvalidTimes() throws {
        #expect(throws: (any Error).self) { try state([(7, 0), (7, 0)]).validate() }
        #expect(throws: (any Error).self) { try state([(24, 0)]).validate() }
        #expect(throws: (any Error).self) { try state([(7, -1)]).validate() }
    }

    @Test func manualOverrideSurvivesWakeRefreshAndRelaunchUntilNextOccurrence() throws {
        var s = state([(7, 0), (19, 0)])
        let now = date("2026-10-30T10:00:00-07:00")
        s.manualOverrideKey = try #require(DailySchedule.current(in: s, now: now, calendar: calendar)).key
        // Relaunch uses exactly the serialized state. Wake/Refresh ask for pending work again.
        let relaunched = try JSONDecoder().decode(ScheduleState.self, from: JSONEncoder().encode(s))
        #expect(DailySchedule.pending(in: relaunched, now: now, calendar: calendar) == nil)
        #expect(DailySchedule.pending(in: relaunched, now: date("2026-10-30T18:59:59-07:00"), calendar: calendar) == nil)
        #expect(DailySchedule.pending(in: relaunched, now: date("2026-10-30T19:00:00-07:00"), calendar: calendar)?.entry.id == s.entries[1].id)
    }
}
