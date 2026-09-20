import AppKit
import XCTest
@testable import JobApplicationWidget

final class PowerAndResourceTests: XCTestCase {
    func testWorkspaceNotificationsMapToPowerEvents() async {
        let center = NotificationCenter()
        let source = WorkspacePowerEvents(center: center)
        let stream = source.events()
        let task = Task { () -> [PowerEvent] in
            var events: [PowerEvent] = []
            for await event in stream {
                events.append(event)
                if events.count == 2 { break }
            }
            return events
        }

        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)

        XCTAssertEqual(await task.value, [.willSleep, .didWake])
    }

    func testCancellingOneSubscriberDoesNotAffectAnother() async {
        let center = NotificationCenter()
        let source = WorkspacePowerEvents(center: center)
        let firstReceived = expectation(description: "first subscriber received sleep")
        let first = Task {
            for await event in source.events() where event == .willSleep {
                firstReceived.fulfill()
            }
        }
        let second = Task { () -> [PowerEvent] in
            var events: [PowerEvent] = []
            for await event in source.events() {
                events.append(event)
                if events.count == 2 { break }
            }
            return events
        }

        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        await fulfillment(of: [firstReceived])
        first.cancel()
        await first.value
        center.post(name: NSWorkspace.didWakeNotification, object: nil)

        XCTAssertEqual(await second.value, [.willSleep, .didWake])
    }

    func testCancelAllCancelsAndTerminatesExplicitResourcesOnce() {
        let waiter = FakeProcessWaiter()
        let process = FakeWorkerProcess()
        let resources = WorkerResources(processWaiter: waiter)
        var cancellationCount = 0
        resources.register(process: process)
        resources.registerCancellation { cancellationCount += 1 }

        resources.cancelAll()
        resources.cancelAll()

        XCTAssertEqual(cancellationCount, 1)
        XCTAssertEqual(process.terminateCount, 1)
        XCTAssertEqual(process.interruptCount, 0)
        XCTAssertEqual(waiter.requests.map(\.timeout), [5])
        waiter.completeAll(exited: false)
        XCTAssertEqual(process.interruptCount, 1)
    }

    func testProcessThatExitsDuringGracePeriodIsNotInterrupted() {
        let waiter = FakeProcessWaiter()
        let process = FakeWorkerProcess()
        let resources = WorkerResources(processWaiter: waiter)
        resources.register(process: process)

        resources.cancelAll()
        process.finish()
        waiter.completeAll(exited: true)

        XCTAssertEqual(process.terminateCount, 1)
        XCTAssertEqual(process.interruptCount, 0)
    }

    func testTimeoutRaceRechecksProcessBeforeInterrupting() {
        let waiter = FakeProcessWaiter()
        let process = FakeWorkerProcess()
        let resources = WorkerResources(processWaiter: waiter)
        resources.register(process: process)

        resources.cancelAll()
        process.finish()
        waiter.completeAll(exited: false)

        XCTAssertEqual(process.interruptCount, 0)
    }

    func testProcessAlreadyExitedIsIgnored() {
        let waiter = FakeProcessWaiter()
        let process = FakeWorkerProcess(running: false)
        let resources = WorkerResources(processWaiter: waiter)
        resources.register(process: process)

        resources.cancelAll()

        XCTAssertEqual(process.terminateCount, 0)
        XCTAssertTrue(waiter.requests.isEmpty)
    }

    func testRegistrationAfterCancellationIsCancelledImmediately() {
        let waiter = FakeProcessWaiter()
        let resources = WorkerResources(processWaiter: waiter)
        resources.cancelAll()
        let process = FakeWorkerProcess()
        var cancellationCount = 0

        resources.register(process: process)
        resources.registerCancellation { cancellationCount += 1 }

        XCTAssertEqual(process.terminateCount, 1)
        XCTAssertEqual(waiter.requests.count, 1)
        XCTAssertEqual(cancellationCount, 1)
    }

    func testCancellationClosureCanReenterWithoutDeadlock() {
        let waiter = FakeProcessWaiter()
        let resources = WorkerResources(processWaiter: waiter)
        let process = FakeWorkerProcess()
        resources.registerCancellation {
            resources.register(process: process)
            resources.cancelAll()
        }

        resources.cancelAll()

        XCTAssertEqual(process.terminateCount, 1)
    }

    func testConcurrentRegistrationCannotEscapeCancellation() {
        let waiter = FakeProcessWaiter()
        let resources = WorkerResources(processWaiter: waiter)
        let processes = (0..<50).map { _ in FakeWorkerProcess() }
        let queue = DispatchQueue(label: "WorkerResourcesTests", attributes: .concurrent)
        let group = DispatchGroup()

        for process in processes {
            group.enter()
            queue.async {
                resources.register(process: process)
                group.leave()
            }
        }
        group.enter()
        queue.async {
            resources.cancelAll()
            group.leave()
        }
        group.wait()

        XCTAssertTrue(processes.allSatisfy { $0.terminateCount == 1 })
    }
}

private final class FakeWorkerProcess: WorkerProcess {
    private let lock = NSLock()
    private var running: Bool
    private var terminateCalls = 0
    private var interruptCalls = 0

    init(running: Bool = true) { self.running = running }
    var isRunning: Bool { lock.withLock { running } }
    var terminateCount: Int { lock.withLock { terminateCalls } }
    var interruptCount: Int { lock.withLock { interruptCalls } }

    func terminate() { lock.withLock { terminateCalls += 1 } }
    func interrupt() { lock.withLock { interruptCalls += 1; running = false } }
    func finish() { lock.withLock { running = false } }
}

private final class FakeProcessWaiter: WorkerProcessWaiting {
    struct Request {
        let process: WorkerProcess
        let timeout: TimeInterval
        let completion: (Bool) -> Void
    }

    private let lock = NSLock()
    private var storedRequests: [Request] = []
    var requests: [Request] { lock.withLock { storedRequests } }

    func waitForExit(
        of process: WorkerProcess,
        timeout: TimeInterval,
        completion: @escaping (Bool) -> Void
    ) {
        lock.withLock {
            storedRequests.append(Request(process: process, timeout: timeout, completion: completion))
        }
    }

    func completeAll(exited: Bool) {
        let requests = lock.withLock { () -> [Request] in
            defer { storedRequests.removeAll() }
            return storedRequests
        }
        requests.forEach { $0.completion(exited) }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
