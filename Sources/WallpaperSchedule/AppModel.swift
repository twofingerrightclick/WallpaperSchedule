import AppKit
import ServiceManagement
import SwiftUI
import WallpaperCore

@MainActor
final class AppModel: ObservableObject {
    @Published var aerials: [Aerial] = []
    @Published var selectedID: String?
    @Published var applying = false
    @Published var error: String?
    @Published var status = ""
    @Published private(set) var state = ScheduleState()
    @Published private(set) var persistenceAvailable = true
    @Published private(set) var scheduleWarning: String?
    @Published private(set) var catalogWarning: String?
    @Published private(set) var displayDate = Date()
    let locationService = LocationService()
    private let helper = SchedulerClient()
    private let persistence = SchedulePersistence()
    private var activeObserver: NSObjectProtocol?
    private var pendingLocation: SolarLocation?

    var selected: Aerial? { aerials.first { $0.id == selectedID } }
    var sortedEntries: [ScheduleEntry] {
        state.entries.sorted {
            let a = DailySchedule.time(for: $0, on: displayDate, in: state) ?? .distantFuture
            let b = DailySchedule.time(for: $1, on: displayDate, in: state) ?? .distantFuture
            return a == b ? $0.triggerKey < $1.triggerKey : a < b
        }
    }

    var solarNotice: String? {
        let solarEntries = state.entries.filter { $0.enabled && $0.solarPhase != nil }
        guard !solarEntries.isEmpty else { return nil }
        guard state.location != nil else { return "Set a daylight location to activate your sun-based entries. Fixed times still work." }
        if state.usesCurrentLocation == true && locationService.errorMessage != nil {
            return "Location refresh failed. Scheduling uses the last saved coordinates."
        }
        if solarEntries.contains(where: { DailySchedule.time(for: $0, on: displayDate, in: state) == nil }) {
            return "Some daylight events do not occur here today. Those entries are skipped; other entries still run."
        }
        return nil
    }

    init() {
        do { state = try persistence.load() }
        catch {
            persistenceAvailable = false
            state.enabled = false
            self.error = "Couldn’t read your saved schedule. The file has been left unchanged. \(error.localizedDescription)"
        }
        refresh()
        locationService.onLocation = { [weak self] location in
            self?.setLocation(location, current: true)
            self?.evaluateSchedule()
        }
        locationService.onCompletion = { [weak self] in self?.evaluateSchedule() }
        if state.usesCurrentLocation == true { locationService.requestIfAuthorized() }
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        Task {
            do {
                if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                    try SMAppService.mainApp.unregister()
                }
            } catch { self.error = "Couldn’t remove the old settings-app login item. \(error.localizedDescription)" }
            evaluateSchedule()
        }
    }

    func refresh() {
        displayDate = Date()
        if !applying {
            if let saved = try? persistence.load() { state = saved }
            let result = SchedulerStatus.load()
            scheduleWarning = result.error
            if let message = result.message { status = message }
        }
        do {
            aerials = try AerialCatalog().load()
            catalogWarning = nil
            if !aerials.contains(where: { $0.id == selectedID }) {
                let current = try? WallpaperStore.selectedAsset(in: Data(contentsOf: WallpaperEngine.storeURL))
                selectedID = aerials.first(where: { $0.id == current })?.id ?? aerials.first?.id
            }
        } catch { catalogWarning = error.localizedDescription }
    }

    func addEntry(at date: Date, phase: SolarPhase? = nil) {
        guard let aerial = selected else { return }
        guard phase == nil || state.location != nil else { error = "Set your daylight location first."; return }
        let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: date)
        var next = state
        next.entries.append(ScheduleEntry(assetID: aerial.id, name: aerial.name, hour: components.hour ?? 0, minute: components.minute ?? 0, solarPhase: phase))
        if commit(next) { status = "Added \(aerial.name) to your daily schedule." }
    }

    func changePhase(_ id: UUID, to phase: SolarPhase?) {
        guard phase == nil || state.location != nil else { error = "Set your daylight location first."; return }
        var next = state
        guard let index = next.entries.firstIndex(where: { $0.id == id }) else { return }
        next.entries[index].solarPhase = phase
        _ = commit(next)
    }

    @discardableResult
    func setLocation(_ location: SolarLocation, current: Bool) -> Bool {
        guard location.isValid else { error = "Enter a latitude from −90 to 90 and longitude from −180 to 180."; return false }
        if applying, current { pendingLocation = location; return false }
        guard !applying else { return false }
        var next = state
        next.location = location
        next.usesCurrentLocation = current
        if next.location == state.location && next.usesCurrentLocation == state.usesCurrentLocation {
            if !current { locationService.cancel() }
            return true
        }
        let saved = commit(next, resetOverride: false)
        if saved, !current { locationService.cancel() }
        return saved
    }

    func changeTime(_ id: UUID, to date: Date) {
        var next = state
        guard let index = next.entries.firstIndex(where: { $0.id == id }) else { return }
        let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: date)
        next.entries[index].hour = components.hour ?? 0
        next.entries[index].minute = components.minute ?? 0
        _ = commit(next)
    }

    func toggleEntry(_ id: UUID, enabled: Bool) {
        var next = state
        guard let index = next.entries.firstIndex(where: { $0.id == id }) else { return }
        next.entries[index].enabled = enabled
        _ = commit(next)
    }

    func deleteEntry(_ id: UUID) {
        var next = state
        next.entries.removeAll { $0.id == id }
        _ = commit(next)
    }

    func setEnabled(_ enabled: Bool) {
        var next = state
        next.enabled = enabled
        _ = commit(next)
    }

    @discardableResult
    private func commit(_ next: ScheduleState, resetOverride: Bool = true) -> Bool {
        guard persistenceAvailable, !applying else { return false }
        guard SchedulerClient.helperURL != nil else {
            error = "Install the updated app in Applications before saving schedules."
            return false
        }
        guard Set(next.entries.map(\.triggerKey)).count == next.entries.count else {
            error = "There’s already a wallpaper at that time or daylight phase. Choose another option, or remove the existing entry first."
            return false
        }
        do {
            var next = next
            if resetOverride { next.manualOverrideKey = nil }
            try persistence.save(next)
            state = next
            scheduleWarning = nil
            evaluateSchedule(force: resetOverride)
            return true
        } catch {
            self.error = "Couldn’t save your schedule. \(error.localizedDescription)"
            return false
        }
    }

    /// Settings only asks the OS scheduler to reconfigure; it never owns a schedule timer.
    func evaluateSchedule(force: Bool = false) {
        guard persistenceAvailable, !applying, !locationService.locating else { return }
        launchHelper(["configure"] + (force ? ["--force"] : []), manual: false)
    }

    func applySelected() {
        guard let aerial = selected, !applying else { return }
        launchHelper(["manual", aerial.id], manual: true)
    }

    private func launchHelper(_ arguments: [String], manual: Bool) {
        guard SchedulerClient.helperURL != nil else {
            scheduleWarning = "Install the updated Applications copy to enable macOS scheduling."
            return
        }
        applying = true
        Task {
            defer {
                applying = false
                if let location = pendingLocation {
                    pendingLocation = nil
                    setLocation(location, current: true)
                }
            }
            do {
                let message = try await helper.run(arguments)
                state = try persistence.load()
                let result = SchedulerStatus.load()
                scheduleWarning = result.error
                status = message.isEmpty ? (result.message ?? "macOS scheduling is ready.") : message
            } catch {
                let message = error.localizedDescription
                scheduleWarning = message
                if manual { self.error = message }
                else { self.error = "Your schedule is saved, but macOS scheduling needs attention. \(message)" }
            }
        }
    }

    func openWallpaperSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}
