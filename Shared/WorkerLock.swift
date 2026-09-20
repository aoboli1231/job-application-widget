import Darwin
import Foundation

final class WorkerLock {
    enum Error: Swift.Error {
        case open(path: String, errno: Int32)
        case lock(path: String, errno: Int32)
    }

    private let stateLock = NSLock()
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(url: URL) throws -> WorkerLock? {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw Error.open(path: url.path, errno: errno)
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) != 0 else {
            return WorkerLock(descriptor: descriptor)
        }

        let code = errno
        close(descriptor)
        if code == EWOULDBLOCK || code == EAGAIN {
            return nil
        }
        throw Error.lock(path: url.path, errno: code)
    }

    func unlock() {
        stateLock.lock()
        guard descriptor >= 0 else {
            stateLock.unlock()
            return
        }
        let ownedDescriptor = descriptor
        descriptor = -1
        stateLock.unlock()

        _ = flock(ownedDescriptor, LOCK_UN)
        _ = close(ownedDescriptor)
    }

    deinit { unlock() }
}
