import AppKit
import SwiftUI
import ServiceManagement
import WallpaperCore

@main
struct WallpaperScheduleLauncher {
    @MainActor static func main() {
        do {
            if CommandLine.arguments.contains("--disable-legacy-login") {
                if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                    try SMAppService.mainApp.unregister()
                }
                return
            }
            guard let lease = try InstanceLease.acquire(at: WallpaperEngine.supportURL.appendingPathComponent("Instance.lock")) else {
                try Data().write(to: showWindowRequestURL, options: .atomic)
                DistributedNotificationCenter.default().postNotificationName(showWindowNotification, object: String(getuid()), userInfo: nil, deliverImmediately: true)
                NSRunningApplication.runningApplications(withBundleIdentifier: AppIdentity.identifier)
                    .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })?
                    .activate(options: [])
                return
            }
            withExtendedLifetime(lease) { WallpaperScheduleApp.main() }
        } catch {
            if CommandLine.arguments.contains("--disable-legacy-login") {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                exit(1)
            }
            let alert = NSAlert()
            alert.messageText = "Couldn’t open Wallpaper Schedule"
            alert.informativeText = "Couldn’t check for an existing instance. \(error.localizedDescription)"
            alert.runModal()
        }
    }
}

private var showWindowNotification: Notification.Name { Notification.Name(AppIdentity.identifier + ".showWindow") }
private var showWindowRequestURL: URL { WallpaperEngine.supportURL.appendingPathComponent("ShowWindow.request") }

struct WallpaperScheduleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: AppModel

    init() {
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        delegate.model = model
    }

    var body: some Scene {
        Window("Wallpaper Schedule", id: "main") {
            MainWindowContent(model: model, delegate: delegate)
                .frame(minWidth: 880, minHeight: 620)
        }
        .defaultSize(width: 960, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

    }
}

private struct MainWindowContent: View {
    @ObservedObject var model: AppModel
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        ContentView(model: model)
            .onAppear {
                delegate.openMainWindow = { openWindow(id: "main") }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var openMainWindow: (() -> Void)? {
        didSet { if reopenRequested { requestOpen() } }
    }
    weak var model: AppModel?
    private var showObserver: NSObjectProtocol?
    private var reopenRequested = false

    private func requestOpen() {
        reopenRequested = true
        guard let openMainWindow else { return }
        reopenRequested = false
        try? FileManager.default.removeItem(at: showWindowRequestURL)
        openMainWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        showObserver = DistributedNotificationCenter.default().addObserver(forName: showWindowNotification, object: String(getuid()), queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.requestOpen()
            }
        }
        if FileManager.default.fileExists(atPath: showWindowRequestURL.path) { requestOpen() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        requestOpen()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model?.applying == true else { return .terminateNow }
        Task { @MainActor in
            while model?.applying == true { try? await Task.sleep(for: .milliseconds(100)) }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
