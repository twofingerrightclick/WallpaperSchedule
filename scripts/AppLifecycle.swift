// Installer helper: request a normal quit, then reopen the verified installed app.
import AppKit
import Foundation

@main
struct AppLifecycle {
    @MainActor static func main() async {
        do {
            let arguments = CommandLine.arguments
            if arguments.count == 3, arguments[1] == "open" {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.createsNewApplicationInstance = false
                _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: arguments[2]), configuration: configuration)
                return
            }
            guard (2...3).contains(arguments.count), arguments[1] == "quit" || arguments[1] == "status" else {
                throw WallpaperLifecycleError.message("Usage: AppLifecycle quit|status [bundle-identifier] | open <path>")
            }
            let identifier = arguments.count == 3 ? arguments[2] : "local.wallpaperschedule"
            let applications = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            if arguments[1] == "status" { print(applications.isEmpty ? "stopped" : "running"); return }
            for application in applications {
                if !application.terminate(), !application.isTerminated {
                    throw WallpaperLifecycleError.message("Could not request a normal quit. Quit Wallpaper Schedule and try again.")
                }
            }
            let deadline = Date().addingTimeInterval(20)
            while applications.contains(where: { !$0.isTerminated }), Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard applications.allSatisfy(\.isTerminated) else {
                throw WallpaperLifecycleError.message("Wallpaper Schedule did not finish quitting. No installed files were changed.")
            }
            print(applications.isEmpty ? "stopped" : "running")
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}

private enum WallpaperLifecycleError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let value): value } }
}
