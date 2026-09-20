import XCTest
@testable import JobApplicationWidget

final class NetworkGateTests: XCTestCase {
    private let urls = [URL(string: "https://one.test/")!, URL(string: "https://two.test/")!]

    func testLeaseRemembersInvalidationBeforeWaiterRegisters() async throws {
        let lease = NetworkLease()
        lease.invalidate()
        try await lease.waitForInvalidation()
    }

    func testCancellingLeaseWaiterDoesNotInvalidateLease() async throws {
        let lease = NetworkLease()
        let first = Task { try await lease.waitForInvalidation() }
        first.cancel()
        do {
            try await first.value
            XCTFail("Cancelled waiter unexpectedly succeeded")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let second = Task { try await lease.waitForInvalidation() }
        lease.invalidate()
        try await second.value
    }

    func testLeaseRejectsASecondConcurrentWaiter() async throws {
        let lease = NetworkLease()
        let first = Task { try await lease.waitForInvalidation() }
        while !lease.hasWaiter { await Task.yield() }
        do {
            try await lease.waitForInvalidation()
            XCTFail("Second waiter unexpectedly succeeded")
        } catch NetworkLease.Error.waiterAlreadyRegistered {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        lease.invalidate()
        try await first.value
    }

    func testReadyLeaseRemembersImmediatePathLoss() async throws {
        let started = expectation(description: "monitor started")
        let armed = expectation(description: "timer armed")
        let monitor = FakePathMonitor(onStart: { started.fulfill() })
        let timers = FakeTimerScheduler(onSchedule: { armed.fulfill() })
        let requester = ScriptedRequester(results: [.success(204), .success(204)])
        var now: TimeInterval = 0
        let gate = makeGate(monitor, timers, requester, now: { now })
        let readyTask = Task { try await gate.waitUntilUsable() }

        await fulfillment(of: [started])
        monitor.emit(satisfied: true)
        await fulfillment(of: [armed])
        now = 60
        timers.fireLatest()
        let lease = try await readyTask.value

        monitor.emit(satisfied: false)
        try await lease.waitForInvalidation()
    }

    func testRepeatedReadyWaitReturnsSameLease() async throws {
        let started = expectation(description: "monitor started")
        let armed = expectation(description: "timer armed")
        let monitor = FakePathMonitor(onStart: { started.fulfill() })
        let timers = FakeTimerScheduler(onSchedule: { armed.fulfill() })
        let requester = ScriptedRequester(results: [.success(204), .success(204)])
        var now: TimeInterval = 0
        let gate = makeGate(monitor, timers, requester, now: { now })
        let readyTask = Task { try await gate.waitUntilUsable() }

        await fulfillment(of: [started])
        monitor.emit(satisfied: true)
        await fulfillment(of: [armed])
        now = 60
        timers.fireLatest()
        let first = try await readyTask.value
        let second = try await gate.waitUntilUsable()

        XCTAssertTrue(first === second)
    }

    func testPathDropAtSecondFiftyNineRestartsFullWindow() {
        var machine = NetworkStabilityMachine(stableInterval: 60)
        XCTAssertEqual(machine.handle(.pathSatisfied, now: 0), .arm(deadline: 60))
        XCTAssertEqual(machine.handle(.pathUnsatisfied, now: 59), .cancelTimer)
        XCTAssertEqual(machine.handle(.pathSatisfied, now: 60), .arm(deadline: 120))
        XCTAssertEqual(machine.handle(.timerFired, now: 119), .none)
        XCTAssertEqual(machine.handle(.timerFired, now: 120), .beginProbes)
    }

    func testSleepAndWakeResetSatisfiedPath() {
        var machine = NetworkStabilityMachine(stableInterval: 60)
        _ = machine.handle(.pathSatisfied, now: 0)
        XCTAssertEqual(machine.handle(.sleep, now: 30), .cancelAll)
        XCTAssertEqual(machine.handle(.wake, now: 100), .awaitPathEvent)
        XCTAssertEqual(machine.state, .offline)
    }

    func testRepeatedSatisfiedDoesNotExtendDeadline() {
        var machine = NetworkStabilityMachine(stableInterval: 60)
        XCTAssertEqual(machine.handle(.pathSatisfied, now: 0), .arm(deadline: 60))
        XCTAssertEqual(machine.handle(.pathSatisfied, now: 30), .none)
        XCTAssertEqual(machine.handle(.timerFired, now: 60), .beginProbes)
    }

    func testTwoSuccessfulProbesProduceReadyOnce() async throws {
        let started = expectation(description: "monitor started")
        let armed = expectation(description: "one-shot armed")
        let ready = expectation(description: "ready")
        ready.assertForOverFulfill = true
        let monitor = FakePathMonitor(onStart: { started.fulfill() })
        let timers = FakeTimerScheduler(onSchedule: { armed.fulfill() })
        let requester = ScriptedRequester(results: [.success(204), .success(302)])
        let delay = RecordingDelay()
        var now: TimeInterval = 0
        let gate = makeGate(monitor, timers, requester, now: { now }, delay: delay.call)

        Task {
            try await gate.waitUntilUsable()
            ready.fulfill()
        }
        await fulfillment(of: [started])
        monitor.emit(satisfied: true)
        await fulfillment(of: [armed])
        now = 60
        timers.fireLatest()
        await fulfillment(of: [ready])

        XCTAssertEqual(requester.callCount, 2)
        XCTAssertEqual(delay.values, [3])
        XCTAssertEqual(monitor.startCount, 1)
        XCTAssertEqual(timers.scheduleCount, 1)
    }

    func testFirstProbeFailureDoesNotCallSecondOrRetry() async {
        let started = expectation(description: "monitor started")
        let armed = expectation(description: "one-shot armed")
        let firstCall = expectation(description: "first probe")
        let cancelled = expectation(description: "waiter cancelled")
        let monitor = FakePathMonitor(onStart: { started.fulfill() })
        let timers = FakeTimerScheduler(onSchedule: { armed.fulfill() })
        let requester = ScriptedRequester(results: [.success(500), .success(204)], onCall: { firstCall.fulfill() })
        var now: TimeInterval = 0
        let gate = makeGate(monitor, timers, requester, now: { now })

        Task {
            do { try await gate.waitUntilUsable() }
            catch is CancellationError { cancelled.fulfill() }
            catch { XCTFail("Unexpected error: \(error)") }
        }
        await fulfillment(of: [started])
        monitor.emit(satisfied: true)
        await fulfillment(of: [armed])
        now = 60
        timers.fireLatest()
        await fulfillment(of: [firstCall])

        XCTAssertEqual(requester.callCount, 1)
        XCTAssertEqual(timers.scheduleCount, 1)
        gate.cancel()
        await fulfillment(of: [cancelled])
    }

    func testPathLossDuringProbeCancelsAndRequiresFullWindowAgain() async throws {
        let started = expectation(description: "monitor started")
        let firstArm = expectation(description: "first arm")
        let secondArm = expectation(description: "second arm")
        let delayEntered = expectation(description: "delay entered")
        let ready = expectation(description: "ready after reconnect")
        let monitor = FakePathMonitor(onStart: { started.fulfill() })
        var armCount = 0
        let timers = FakeTimerScheduler(onSchedule: {
            armCount += 1
            (armCount == 1 ? firstArm : secondArm).fulfill()
        })
        let requester = ScriptedRequester(results: [.success(204), .success(204), .success(204)])
        let delay = FirstCallSuspendingDelay(onEntered: { delayEntered.fulfill() })
        var now: TimeInterval = 0
        let gate = makeGate(monitor, timers, requester, now: { now }, delay: delay.call)

        Task {
            try await gate.waitUntilUsable()
            ready.fulfill()
        }
        await fulfillment(of: [started])
        monitor.emit(satisfied: true)
        await fulfillment(of: [firstArm])
        now = 60
        timers.fireLatest()
        await fulfillment(of: [delayEntered])

        monitor.emit(satisfied: false)
        now = 61
        monitor.emit(satisfied: true)
        await fulfillment(of: [secondArm])
        XCTAssertEqual(timers.latestInterval, 60)
        now = 121
        timers.fireLatest()
        await fulfillment(of: [ready])
        XCTAssertEqual(requester.callCount, 3)
    }

    func testCancelledTimerCallbackCannotStartProbes() async {
        let started = expectation(description: "monitor started")
        let armed = expectation(description: "timer armed")
        let cancelled = expectation(description: "waiter cancelled")
        let monitor = FakePathMonitor(onStart: { started.fulfill() })
        let timers = FakeTimerScheduler(onSchedule: { armed.fulfill() })
        let requester = ScriptedRequester(results: [.success(204), .success(204)])
        var now: TimeInterval = 0
        let gate = makeGate(monitor, timers, requester, now: { now })

        Task {
            do { try await gate.waitUntilUsable() }
            catch is CancellationError { cancelled.fulfill() }
            catch { XCTFail("Unexpected error: \(error)") }
        }
        await fulfillment(of: [started])
        monitor.emit(satisfied: true)
        await fulfillment(of: [armed])
        monitor.emit(satisfied: false)
        now = 60
        timers.fireLatest(evenIfCancelled: true)
        gate.cancel()
        await fulfillment(of: [cancelled])
        XCTAssertEqual(requester.callCount, 0)
    }

    func testPathLossDuringSecondProbeIgnoresItsLateSuccess() async {
        let started = expectation(description: "monitor started")
        let firstArm = expectation(description: "first arm")
        let secondArm = expectation(description: "full window rearmed")
        let secondProbe = expectation(description: "second probe started")
        let cancelled = expectation(description: "waiter cancelled")
        var armCount = 0
        let monitor = FakePathMonitor(onStart: { started.fulfill() })
        let timers = FakeTimerScheduler(onSchedule: {
            armCount += 1
            (armCount == 1 ? firstArm : secondArm).fulfill()
        })
        let requester = SuspendingSecondRequester(onSecondCall: { secondProbe.fulfill() })
        var now: TimeInterval = 0
        let gate = NetworkGate(
            monitor: monitor,
            requester: requester,
            policy: ProbePolicy(urls: urls, delayBetweenProbes: 3),
            timerScheduler: timers,
            now: { now },
            delay: { _ in }
        )

        Task {
            do { try await gate.waitUntilUsable() }
            catch is CancellationError { cancelled.fulfill() }
            catch { XCTFail("Unexpected error: \(error)") }
        }
        await fulfillment(of: [started])
        monitor.emit(satisfied: true)
        await fulfillment(of: [firstArm])
        now = 60
        timers.fireLatest()
        await fulfillment(of: [secondProbe])

        monitor.emit(satisfied: false)
        requester.finishSecond(with: 204)
        now = 61
        monitor.emit(satisfied: true)
        await fulfillment(of: [secondArm])
        XCTAssertEqual(timers.latestInterval, 60)
        XCTAssertEqual(requester.callCount, 2)

        gate.cancel()
        await fulfillment(of: [cancelled])
    }

    func testSecondWaiterIsRejectedAndCancelResumesFirstOnce() async {
        let started = expectation(description: "monitor started")
        let firstCancelled = expectation(description: "first cancelled")
        firstCancelled.assertForOverFulfill = true
        let monitor = FakePathMonitor(onStart: { started.fulfill() })
        let timers = FakeTimerScheduler()
        let requester = ScriptedRequester(results: [])
        let gate = makeGate(monitor, timers, requester, now: { 0 })

        Task {
            do { try await gate.waitUntilUsable() }
            catch is CancellationError { firstCancelled.fulfill() }
            catch { XCTFail("Unexpected first waiter error: \(error)") }
        }
        await fulfillment(of: [started])
        do {
            try await gate.waitUntilUsable()
            XCTFail("Second waiter unexpectedly succeeded")
        } catch NetworkGate.Error.waiterAlreadyRegistered {
        } catch {
            XCTFail("Unexpected second waiter error: \(error)")
        }

        gate.cancel()
        gate.cancel()
        await fulfillment(of: [firstCancelled])
        XCTAssertEqual(monitor.startCount, 1)
        XCTAssertEqual(monitor.cancelCount, 1)
    }

    func testReadyThenResetCanCompleteAgainWithSameMonitor() async throws {
        let started = expectation(description: "monitor started")
        let firstArm = expectation(description: "first arm")
        let secondArm = expectation(description: "second arm")
        let firstReady = expectation(description: "first ready")
        let secondReady = expectation(description: "second ready")
        var armCount = 0
        let monitor = FakePathMonitor(onStart: { started.fulfill() })
        let timers = FakeTimerScheduler(onSchedule: {
            armCount += 1
            (armCount == 1 ? firstArm : secondArm).fulfill()
        })
        let requester = ScriptedRequester(results: [.success(204), .success(204), .success(204), .success(204)])
        var now: TimeInterval = 0
        let gate = makeGate(monitor, timers, requester, now: { now })

        let firstTask = Task { let lease = try await gate.waitUntilUsable(); firstReady.fulfill(); return lease }
        await fulfillment(of: [started])
        monitor.emit(satisfied: true)
        await fulfillment(of: [firstArm])
        now = 60
        timers.fireLatest()
        await fulfillment(of: [firstReady])
        let firstLease = try await firstTask.value

        gate.reset()
        let secondTask = Task { let lease = try await gate.waitUntilUsable(); secondReady.fulfill(); return lease }
        await fulfillment(of: [secondArm])
        now = 120
        timers.fireLatest()
        await fulfillment(of: [secondReady])
        let secondLease = try await secondTask.value
        try await firstLease.waitForInvalidation()

        XCTAssertEqual(monitor.startCount, 1)
        XCTAssertEqual(requester.callCount, 4)
        XCTAssertFalse(firstLease === secondLease)
    }

    func testLatePathEventAfterCancelCannotArmTimer() async {
        let started = expectation(description: "monitor started")
        let cancelled = expectation(description: "waiter cancelled")
        let queue = DispatchQueue(label: "NetworkGateTests.cancel-race")
        let monitor = FakePathMonitor(onStart: { started.fulfill() })
        let timers = FakeTimerScheduler()
        let requester = ScriptedRequester(results: [])
        let gate = NetworkGate(
            queue: queue,
            monitor: monitor,
            requester: requester,
            policy: ProbePolicy(urls: urls, delayBetweenProbes: 3),
            timerScheduler: timers,
            now: { 0 },
            delay: { _ in }
        )

        Task {
            do { try await gate.waitUntilUsable() }
            catch is CancellationError { cancelled.fulfill() }
            catch { XCTFail("Unexpected error: \(error)") }
        }
        await fulfillment(of: [started])
        gate.cancel()
        monitor.emit(satisfied: true)
        queue.sync {}
        await fulfillment(of: [cancelled])
        XCTAssertEqual(timers.scheduleCount, 0)
        XCTAssertEqual(requester.callCount, 0)
    }

    func testCancellingWaitingTaskCancelsGateExactlyOnce() async {
        let started = expectation(description: "monitor started")
        let cancelled = expectation(description: "task cancelled")
        let monitor = FakePathMonitor(onStart: { started.fulfill() })
        let gate = makeGate(monitor, FakeTimerScheduler(), ScriptedRequester(results: []), now: { 0 })
        let task = Task {
            do { try await gate.waitUntilUsable() }
            catch is CancellationError { cancelled.fulfill() }
            catch { XCTFail("Unexpected error: \(error)") }
        }

        await fulfillment(of: [started])
        task.cancel()
        await fulfillment(of: [cancelled])
        gate.cancel()
        XCTAssertEqual(monitor.cancelCount, 1)
    }

    private func makeGate(
        _ monitor: FakePathMonitor,
        _ timers: FakeTimerScheduler,
        _ requester: HTTPSRequesting,
        now: @escaping () -> TimeInterval,
        delay: @escaping NetworkGate.Delay = { _ in }
    ) -> NetworkGate {
        NetworkGate(
            monitor: monitor,
            requester: requester,
            policy: ProbePolicy(urls: urls, delayBetweenProbes: 3),
            timerScheduler: timers,
            now: now,
            delay: delay
        )
    }
}

private final class FakePathMonitor: NetworkPathMonitoring {
    var updateHandler: ((Bool) -> Void)?
    private let onStart: () -> Void
    private(set) var startCount = 0
    private(set) var cancelCount = 0

    init(onStart: @escaping () -> Void = {}) { self.onStart = onStart }
    func start(queue: DispatchQueue) { startCount += 1; onStart() }
    func cancel() { cancelCount += 1 }
    func emit(satisfied: Bool) { updateHandler?(satisfied) }
}

private final class FakeTimerScheduler: OneShotTimerScheduling {
    private final class Entry: NetworkGateCancellation {
        let interval: TimeInterval
        let handler: () -> Void
        private(set) var cancelled = false
        init(interval: TimeInterval, handler: @escaping () -> Void) {
            self.interval = interval
            self.handler = handler
        }
        func cancel() { cancelled = true }
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private let onSchedule: () -> Void
    init(onSchedule: @escaping () -> Void = {}) { self.onSchedule = onSchedule }

    var scheduleCount: Int { lock.withLock { entries.count } }
    var latestInterval: TimeInterval? { lock.withLock { entries.last?.interval } }

    func schedule(after interval: TimeInterval, handler: @escaping () -> Void) -> NetworkGateCancellation {
        let entry = Entry(interval: interval, handler: handler)
        lock.withLock { entries.append(entry) }
        onSchedule()
        return entry
    }

    func fireLatest(evenIfCancelled: Bool = false) {
        let entry = lock.withLock { entries.last }
        if evenIfCancelled || entry?.cancelled == false { entry?.handler() }
    }
}

private final class ScriptedRequester: HTTPSRequesting {
    private let lock = NSLock()
    private var results: [Result<Int, Swift.Error>]
    private let onCall: () -> Void
    private(set) var callCount = 0

    init(results: [Result<Int, Swift.Error>], onCall: @escaping () -> Void = {}) {
        self.results = results
        self.onCall = onCall
    }

    func statusCode(for url: URL) async throws -> Int {
        let result: Result<Int, Swift.Error> = lock.withLock {
            callCount += 1
            return results.isEmpty ? .failure(TestError.unscriptedRequest) : results.removeFirst()
        }
        onCall()
        return try result.get()
    }

    private enum TestError: Swift.Error { case unscriptedRequest }
}

private final class RecordingDelay {
    private let lock = NSLock()
    private(set) var values: [TimeInterval] = []
    func call(_ value: TimeInterval) async throws { lock.withLock { values.append(value) } }
}

private final class SuspendingSecondRequester: HTTPSRequesting {
    private let lock = NSLock()
    private var secondContinuation: CheckedContinuation<Int, Swift.Error>?
    private let onSecondCall: () -> Void
    private(set) var callCount = 0

    init(onSecondCall: @escaping () -> Void) { self.onSecondCall = onSecondCall }

    func statusCode(for url: URL) async throws -> Int {
        let call = lock.withLock { () -> Int in
            callCount += 1
            return callCount
        }
        guard call == 2 else { return 204 }
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { secondContinuation = continuation }
            onSecondCall()
        }
    }

    func finishSecond(with status: Int) {
        let continuation = lock.withLock { () -> CheckedContinuation<Int, Swift.Error>? in
            defer { secondContinuation = nil }
            return secondContinuation
        }
        continuation?.resume(returning: status)
    }
}

private final class FirstCallSuspendingDelay {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Swift.Error>?
    private var isFirst = true
    private let onEntered: () -> Void

    init(onEntered: @escaping () -> Void) { self.onEntered = onEntered }

    func call(_ value: TimeInterval) async throws {
        let shouldSuspend = lock.withLock { () -> Bool in
            defer { isFirst = false }
            return isFirst
        }
        guard shouldSuspend else { return }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { self.continuation = continuation }
                onEntered()
            }
        } onCancel: {
            let continuation = self.lock.withLock { () -> CheckedContinuation<Void, Swift.Error>? in
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
