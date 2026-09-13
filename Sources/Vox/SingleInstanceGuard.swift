import Darwin
import Foundation

final class SingleInstanceGuard {
    static let shared = SingleInstanceGuard()

    let isPrimary: Bool

    private var fileDescriptor: Int32 = -1

    private init() {
        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.satomi.vox.instance.lock")
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR,
            S_IRUSR | S_IWUSR
        )

        // Failing open is preferable to making Vox unusable because the cache
        // directory is temporarily unavailable.
        guard descriptor >= 0 else {
            isPrimary = true
            return
        }

        _ = Darwin.fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        if Self.setLock(on: descriptor, type: F_WRLCK) {
            fileDescriptor = descriptor
            isPrimary = true
        } else {
            Darwin.close(descriptor)
            isPrimary = false
        }
    }

    deinit {
        guard fileDescriptor >= 0 else { return }
        _ = Self.setLock(on: fileDescriptor, type: F_UNLCK)
        Darwin.close(fileDescriptor)
    }

    private static func setLock(on descriptor: Int32, type: Int32) -> Bool {
        var lock = Darwin.flock()
        lock.l_type = Int16(type)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0
        return Darwin.fcntl(descriptor, F_SETLK, &lock) != -1
    }
}
