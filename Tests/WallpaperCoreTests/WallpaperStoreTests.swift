import Foundation
import Testing
@testable import WallpaperCore

struct WallpaperStoreTests {
    let first = "E99FA658-A59A-4A2D-9F3B-58E7BDC71A9A"
    let second = "8002C4C8-C611-4894-A068-3D3A3C03472A"

    func fixture() throws -> [String: Any] {
        let config = try PropertyListSerialization.data(fromPropertyList: ["assetID": first, "futureNativeField": "keep"], format: .binary, options: 0)
        let entry: [String: Any] = ["Type": "linked", "Linked": ["Content": ["Choices": [["Provider": "com.apple.wallpaper.choice.aerials", "Files": [], "Configuration": config]], "Shuffle": ["Type": "afterDuration"]], "Unknown": "preserve"]]
        return ["AllSpacesAndDisplays": entry, "SystemDefault": entry, "Spaces": [String: Any](), "Displays": [String: Any](), "Other": "preserve"]
    }

    func encode(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }

    @Test func testChangesBothLinkedEntriesPreservingUnknownFieldsAndDisablingShuffle() throws {
        let result = try WallpaperStore.selecting(second, in: encode(fixture()))
        #expect(try WallpaperStore.selectedAsset(in: result) == second)
        let store = try #require(PropertyListSerialization.propertyList(from: result, format: nil) as? [String: Any])
        #expect(store["Other"] as? String == "preserve")
        for key in ["AllSpacesAndDisplays", "SystemDefault"] {
            let entry = try #require(store[key] as? [String: Any])
            let linked = try #require(entry["Linked"] as? [String: Any])
            #expect(linked["Unknown"] as? String == "preserve")
            let content = try #require(linked["Content"] as? [String: Any])
            #expect(content["Shuffle"] == nil)
            let choices = try #require(content["Choices"] as? [[String: Any]])
            let config = try #require(choices.first?["Configuration"] as? Data)
            let parsed = try #require(PropertyListSerialization.propertyList(from: config, format: nil) as? [String: String])
            #expect(parsed["assetID"] == second)
            #expect(parsed["futureNativeField"] == "keep")
        }
    }

    @Test func testRejectsOverridesInsteadOfDiscardingOtherSpaceSettings() throws {
        var store = try fixture()
        store["Spaces"] = ["other-space": ["sentinel": true]]
        #expect(throws: (any Error).self) { try WallpaperStore.selecting(second, in: encode(store)) }
    }

    @Test func testRejectsUnknownProviderAndMalformedData() throws {
        var store = try fixture()
        store["SystemDefault"] = ["Type": "individual"]
        #expect(throws: (any Error).self) { try WallpaperStore.selecting(second, in: encode(store)) }
        #expect(throws: (any Error).self) { try WallpaperStore.selecting(second, in: Data("not a plist".utf8)) }
        #expect(throws: (any Error).self) { try WallpaperStore.selecting("../invalid", in: encode(fixture())) }
    }
}
