import Foundation
import Testing
@testable import WallpaperCore

struct AppIdentityTests {
    @Test func customBundleIdentityKeepsIndependentBuildNamespaces() throws {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        defer { try? FileManager.default.removeItem(at: bundle) }
        let contents = bundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "example.wallpaper.custom"], format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        #expect(AppIdentity.identifier(in: bundle) == "example.wallpaper.custom")
    }

    @Test func missingOrInvalidBundleIdentityUsesPublicDefault() throws {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        defer { try? FileManager.default.removeItem(at: bundle) }
        #expect(AppIdentity.identifier(in: bundle) == AppIdentity.defaultIdentifier)
        let contents = bundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "../invalid namespace"], format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        #expect(AppIdentity.identifier(in: bundle) == AppIdentity.defaultIdentifier)
    }
}
