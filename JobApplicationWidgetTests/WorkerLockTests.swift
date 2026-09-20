import XCTest
@testable import JobApplicationWidget

final class WorkerLockTests: XCTestCase {
    func testPathsStayInsideInjectedContainer() {
        let container = URL(fileURLWithPath: "/tmp/test-group")
        let paths = WorkerPaths(containerURL: container)

        XCTAssertEqual(
            paths.lockURL,
            container.appendingPathComponent("Library/Application Support/JobApplicationCopilot/worker.lock")
        )
        XCTAssertEqual(
            paths.backupDirectoryURL,
            container.appendingPathComponent(
                "Library/Application Support/JobApplicationCopilot/Backups",
                isDirectory: true
            )
        )
        XCTAssertEqual(
            paths.launchAgentPlistURL,
            container.appendingPathComponent(
                "Library/Application Support/JobApplicationCopilot/com.aobo.JobApplicationCopilot.worker.plist"
            )
        )
    }

    func testOnlyOneHandleOwnsLock() throws {
        let url = TestDatabase.uniqueURL().appendingPathExtension("lock")
        let first = try XCTUnwrap(WorkerLock.acquire(url: url))
        XCTAssertNil(try WorkerLock.acquire(url: url))
        first.unlock()
        XCTAssertNotNil(try WorkerLock.acquire(url: url))
    }

    func testAcquireCreatesParentDirectoryAndOwnerOnlyFile() throws {
        let url = TestDatabase.uniqueURL()
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("worker.lock")

        let owner = try XCTUnwrap(WorkerLock.acquire(url: url))
        defer { owner.unlock() }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
    }

    func testUnlockIsIdempotent() throws {
        let url = TestDatabase.uniqueURL().appendingPathExtension("lock")
        let owner = try XCTUnwrap(WorkerLock.acquire(url: url))

        owner.unlock()
        owner.unlock()

        XCTAssertNotNil(try WorkerLock.acquire(url: url))
    }

    func testInvalidParentThrowsInsteadOfReportingContention() throws {
        let parent = TestDatabase.uniqueURL()
        try Data("not a directory".utf8).write(to: parent)

        XCTAssertThrowsError(try WorkerLock.acquire(url: parent.appendingPathComponent("worker.lock")))
    }

    func testConcurrentAcquisitionHasOneLiveOwner() {
        let url = TestDatabase.uniqueURL().appendingPathExtension("lock")
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "worker-lock-test", attributes: .concurrent)
        let start = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var owners: [WorkerLock] = []
        var errors: [Swift.Error] = []

        for _ in 0..<20 {
            group.enter()
            queue.async {
                start.wait()
                do {
                    if let owner = try WorkerLock.acquire(url: url) {
                        resultLock.lock()
                        owners.append(owner)
                        resultLock.unlock()
                    }
                } catch {
                    resultLock.lock()
                    errors.append(error)
                    resultLock.unlock()
                }
                group.leave()
            }
        }
        for _ in 0..<20 { start.signal() }
        group.wait()

        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(owners.count, 1)
        owners.forEach { $0.unlock() }
    }
}
