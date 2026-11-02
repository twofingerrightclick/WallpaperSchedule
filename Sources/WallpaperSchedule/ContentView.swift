import AppKit
import SwiftUI
import WallpaperCore

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var newTime = Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var newPhase: SolarPhase?
    @State private var showingLocation = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 24) {
                gallery
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                schedule
                    .frame(width: 300)
            }
            .padding(24)
            Divider()
            HStack(spacing: 12) {
                Image(systemName: "clock").foregroundStyle(.secondary)
                Text("macOS runs your schedule. Closing this window quits settings.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .toolbar {
            ToolbarItemGroup {
                Button(action: model.openWallpaperSettings) { Label("Download More", systemImage: "arrow.down.circle") }
                    .help("Download more Apple aerials in System Settings.")
                Button {
                    model.refresh()
                    model.evaluateSchedule(force: true)
                } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(model.applying)
            }
        }
        .alert("Couldn’t complete that change", isPresented: Binding(
            get: { model.error != nil }, set: { if !$0 { model.error = nil } }
        )) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var gallery: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Your Apple wallpapers").font(.title2).fontWeight(.semibold)
                Text("Select a downloaded aerial to schedule.").foregroundStyle(.secondary)
            }
            if model.aerials.isEmpty {
                ContentUnavailableView {
                    Label("Download an Apple aerial", systemImage: "photo")
                } description: {
                    Text("Choose a Landscape, Cityscape, Underwater, or Earth wallpaper in System Settings. Wait for its download, then refresh here.")
                } actions: {
                    Button("Open Wallpaper Settings", action: model.openWallpaperSettings)
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 16)], spacing: 20) {
                        ForEach(model.aerials) { aerial in
                            Button {
                                model.selectedID = aerial.id
                                model.status = ""
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    AerialPreview(aerial: aerial)
                                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 8)
                                                .strokeBorder(model.selectedID == aerial.id ? Color.accentColor : .clear, lineWidth: 3)
                                        }
                                    HStack(alignment: .top) {
                                        Text(aerial.name).lineLimit(2).multilineTextAlignment(.leading)
                                        Spacer(minLength: 4)
                                        if model.selectedID == aerial.id {
                                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                                        }
                                    }.font(.body)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(aerial.name)
                            .accessibilityAddTraits(model.selectedID == aerial.id ? .isSelected : [])
                        }
                    }.padding(4)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(model.selected?.name ?? "Select a wallpaper").font(.headline)
                    Spacer()
                    if model.applying { ProgressView().controlSize(.small) }
                    Button("Apply Now", action: model.applySelected)
                        .disabled(model.selected == nil || model.applying)
                }
                HStack(spacing: 12) {
                    TriggerPicker(phase: $newPhase)
                    if newPhase == nil {
                        DatePicker("Time", selection: $newTime, displayedComponents: .hourAndMinute)
                            .labelsHidden().datePickerStyle(.field).fixedSize()
                    } else if let phase = newPhase {
                        Text(phaseTime(phase)).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                if let phase = newPhase {
                    Text(phase.explanation).font(.caption).foregroundStyle(.secondary)
                    if model.state.location == nil {
                        Button("Set Daylight Location…") { showingLocation = true }
                    }
                }
                HStack {
                    Text(model.status.isEmpty ? "Repeats daily. Saving applies the wallpaper due now." : model.status)
                        .font(.callout).foregroundStyle(.secondary)
                        .accessibilityAddTraits(.updatesFrequently)
                    Spacer()
                    Button("Add to Schedule") { model.addEntry(at: newTime, phase: newPhase) }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.selected == nil || model.applying || !model.persistenceAvailable || (newPhase != nil && model.state.location == nil))
                }
            }
        }
    }

    private func phaseTime(_ phase: SolarPhase) -> String {
        guard let location = model.state.location else { return "Location needed" }
        return SolarTimes.time(for: phase, on: model.displayDate, at: location)
            .map { "Today, \($0.formatted(date: .omitted, time: .shortened))" } ?? "No event today"
    }

    private var schedule: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Daily schedule").font(.title2).fontWeight(.semibold)
                Spacer()
                Toggle("Schedule enabled", isOn: Binding(get: { model.state.enabled }, set: { model.setEnabled($0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(!model.persistenceAvailable || model.applying)
            }
            Text(model.state.enabled ? "Changes use your Mac’s local time." : "Paused. Your wallpaper will stay as it is.")
                .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Daylight location", systemImage: "location").font(.callout).fontWeight(.medium)
                    Spacer()
                    Button(model.state.location == nil ? "Set…" : "Change…") { showingLocation = true }
                        .disabled(model.applying || !model.persistenceAvailable)
                        .popover(isPresented: $showingLocation) { LocationSettings(model: model, service: model.locationService) }
                }
                Text(locationDescription(model.state.location, current: model.state.usesCurrentLocation == true))
                    .font(.caption).foregroundStyle(.secondary)
                if let notice = model.solarNotice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let warning = model.scheduleWarning ?? model.catalogWarning {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Needs attention", systemImage: "exclamationmark.triangle").fontWeight(.medium)
                    Text(warning).font(.callout).textSelection(.enabled)
                    Button("Try Again") { model.refresh(); model.evaluateSchedule(force: true) }
                        .disabled(model.applying)
                }
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            if model.state.entries.isEmpty {
                ContentUnavailableView {
                    Label("No scheduled changes", systemImage: "clock")
                } description: {
                    Text("Select a wallpaper and add a time. Add more wallpapers for the rest of your day.")
                }
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.sortedEntries) { entry in
                            ScheduleRow(entry: entry, model: model)
                            Divider()
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct ScheduleRow: View {
    let entry: ScheduleEntry
    @ObservedObject var model: AppModel

    private var time: Date {
        Calendar.autoupdatingCurrent.date(bySettingHour: entry.hour, minute: entry.minute, second: 0, of: Date()) ?? Date()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(entry.name).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button { model.deleteEntry(entry.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(entry.name) from schedule")
            }
            HStack {
                TriggerPicker(phase: Binding(get: { entry.solarPhase }, set: { model.changePhase(entry.id, to: $0) }))
                Spacer()
                Toggle("Enable \(entry.name)", isOn: Binding(get: { entry.enabled }, set: { model.toggleEntry(entry.id, enabled: $0) }))
                    .labelsHidden().toggleStyle(.checkbox)
            }
            if let phase = entry.solarPhase {
                let today = DailySchedule.time(for: entry, on: model.displayDate, in: model.state)
                Text(today.map { "Today, \($0.formatted(date: .omitted, time: .shortened))" } ?? (model.state.location == nil ? "Set a daylight location" : "No event today · skipped"))
                    .font(.callout).foregroundStyle(.secondary)
                    .help(phase.explanation)
            } else {
                DatePicker("Time for \(entry.name)", selection: Binding(get: { time }, set: { model.changeTime(entry.id, to: $0) }), displayedComponents: .hourAndMinute)
                    .labelsHidden().datePickerStyle(.field).fixedSize()
            }
        }
        .padding(.vertical, 14)
        .disabled(model.applying || !model.persistenceAvailable)
        .opacity(entry.enabled ? 1 : 0.6)
    }
}

private struct TriggerPicker: View {
    @Binding var phase: SolarPhase?
    var body: some View {
        Picker("When", selection: $phase) {
            Text("Fixed Time").tag(SolarPhase?.none)
            Divider()
            ForEach(SolarPhase.allCases) { value in Text(value.title).tag(Optional(value)) }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .accessibilityLabel("Switch wallpaper at")
    }
}

private func locationDescription(_ location: SolarLocation?, current: Bool) -> String {
    guard let location else { return "Set a location for dawn, sunset, and other daylight events." }
    let latitude = location.latitude.formatted(.number.precision(.fractionLength(2)))
    let longitude = location.longitude.formatted(.number.precision(.fractionLength(2)))
    return "\(current ? "Saved current location" : "Manual location"): \(latitude)°, \(longitude)°"
}

private struct LocationSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var service: LocationService
    @Environment(\.dismiss) private var dismiss
    @State private var latitude = ""
    @State private var longitude = ""

    private var coordinates: SolarLocation? {
        guard let lat = Double(latitude.replacingOccurrences(of: ",", with: ".")),
              let lon = Double(longitude.replacingOccurrences(of: ",", with: ".")) else { return nil }
        let location = SolarLocation(latitude: lat, longitude: lon)
        return location.isValid ? location : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Daylight location").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            Text("Sun times use your saved coordinates and your Mac’s time zone. Current location refreshes only while settings are open; the background helper uses the last saved location.")
                .font(.callout).foregroundStyle(.secondary)
            Text(locationDescription(model.state.location, current: model.state.usesCurrentLocation == true))
                .font(.callout)
            HStack {
                Button("Use Current Location") { service.request() }
                    .disabled(service.locating || model.applying || !model.persistenceAvailable)
                if service.locating { ProgressView().controlSize(.small) }
            }
            if let error = service.errorMessage { Text(error).font(.callout).foregroundStyle(.secondary) }
            Divider()
            Text("Or enter coordinates").fontWeight(.medium)
            HStack {
                VStack(alignment: .leading) {
                    Text("Latitude").font(.caption)
                    TextField("−90 to 90", text: $latitude).accessibilityLabel("Latitude")
                }
                VStack(alignment: .leading) {
                    Text("Longitude").font(.caption)
                    TextField("−180 to 180", text: $longitude).accessibilityLabel("Longitude")
                }
            }.textFieldStyle(.roundedBorder)
            Text("North and east are positive; south and west are negative.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Save Manual Location") {
                if let coordinates, model.setLocation(coordinates, current: false) { dismiss() }
            }
            .disabled(coordinates == nil || model.applying || !model.persistenceAvailable)
        }
        .padding(20).frame(width: 360)
        .onAppear {
            if let location = model.state.location {
                latitude = String(location.latitude)
                longitude = String(location.longitude)
            }
        }
    }
}

struct AerialPreview: View {
    let aerial: Aerial
    var body: some View {
        GeometryReader { geometry in
            if let url = aerial.previewURL, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height).clipped()
            } else {
                Rectangle().fill(.quaternary)
                    .overlay { Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary) }
            }
        }
        .accessibilityHidden(true)
    }
}
