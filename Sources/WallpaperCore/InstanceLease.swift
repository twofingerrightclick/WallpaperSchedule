import Darwin
import Foundation

/// Keep the lock file in place: unlinking it can allow two processes to lock different inodes.
public final class InstanceLease {
    private let descriptor: Int32
    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { close(descriptor) }

    public static func acquire(at url: URL, wait: Bool = false, timeout: TimeInterval = 15) throws -> InstanceLease? {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return InstanceLease(descriptor: descriptor) }
            let code = errno
            guard code == EWOULDBLOCK else {
                close(descriptor)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            if !wait { close(descriptor); return nil }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                close(descriptor)
                throw POSIXError(.ETIMEDOUT)
            }
            usleep(25_000)
        }
    }
}
