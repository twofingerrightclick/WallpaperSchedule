import Foundation
import Testing
@testable import WallpaperCore

struct InstanceLeaseTests {
    @Test func schedulerWaitHasABoundedTimeout() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Operation.lock")
        let lease = try InstanceLease.acquire(at: url)
        defer { withExtendedLifetime(lease) {} }
        let start = Date()
        #expect(throws: POSIXError.self) { try InstanceLease.acquire(at: url, wait: true, timeout: 0.05) }
        #expect(Date().timeIntervalSince(start) < 1)
    }
    @Test func preventsDuplicateInstancesAndReleasesOnExit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Instance.lock")
        var lease = try InstanceLease.acquire(at: url)
        #expect(lease != nil)
        #expect(try InstanceLease.acquire(at: url) == nil)
        lease = nil
        let replacement = try InstanceLease.acquire(at: url)
        #expect(replacement != nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
