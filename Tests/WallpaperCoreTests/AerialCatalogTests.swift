import Foundation
import Testing
@testable import WallpaperCore

struct AerialCatalogTests {
    @Test func downloadedAerialsHaveLocalizedNamesAndExcludeMissingAndEmptyVideos() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let customer = root.appendingPathComponent("Customer")
        let videos = customer.appendingPathComponent("4KSDR240FPS")
        let strings = customer.appendingPathComponent("TVIdleScreenStrings.bundle/en.lproj")
        try FileManager.default.createDirectory(at: videos, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: strings, withIntermediateDirectories: true)
        let ids = (0..<3).map { _ in UUID().uuidString }
        let assets = ids.map { ["id": $0, "localizedNameKey": $0, "accessibilityLabel": "Fallback"] }
        let data = try JSONSerialization.data(withJSONObject: ["assets": assets])
        try data.write(to: customer.appendingPathComponent("entries.json"))
        try Data([1]).write(to: videos.appendingPathComponent(ids[0] + ".mov"))
        try Data().write(to: videos.appendingPathComponent(ids[1] + ".mov"))
        let names = try PropertyListSerialization.data(fromPropertyList: [ids[0]: "Grand Canyon River Valley"], format: .binary, options: 0)
        try names.write(to: strings.appendingPathComponent("Localizable.nocache.strings"))
        let loaded = try AerialCatalog(root: root).load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.id == ids[0])
        #expect(loaded.first?.name == "Grand Canyon River Valley")
        #expect(loaded.first?.previewURL == nil)
    }

    @Test func missingCatalogHasActionableError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(throws: WallpaperError.self) { try AerialCatalog(root: root).load() }
    }
}
