import SQLite3
import XCTest
@testable import JobApplicationWidget

final class WorkerCoordinatorTests: XCTestCase {
    private let due = ISO8601DateFormatter().date(from: "2026-09-21T09:00:00+10:00")!
    private let beforeEight = ISO8601DateFormatter().date(from: "2026-09-21T07:59:00+10:00")!

    func testScheduledRunBeforeEightExitsWithoutRunRow() async throws {
        let fixture = try Fixture(now: beforeEight)
        let exit = await fixture.coordinator().run(trigger: .scheduled)
        XCTAssertEqual(exit, .skippedNotDue)
        XCTAssertEqual(try fixture.runs(), [])
        XCTAssertEqual(fixture.gate.waitCount, 0)
        XCTAssertEqual(fixture.performer.callCount, 0)
    }

    func testScheduledRunAfterExistingSuccessExitsWithoutNewRun() async throws {
        let fixture = try Fixture(now: due)
        let id = try fixture.database.createRun(trigger: .scheduled, localDay: "2026-09-21", at: due)
        try fixture.database.finishRun(id: id, status: .succeeded, error: nil, at: due)
        let exit = await fixture.coordinator().run(trigger: .scheduled)
        XCTAssertEqual(exit, .skippedAlreadySucceeded)
        XCTAssertEqual(try fixture.runs().map(\.id), [id])
        XCTAssertEqual(fixture.gate.waitCount, 0)
    }

    func testForceAfterExistingSuccessStillRunsButWaitsForNetwork() async throws {
        let fixture = try Fixture(now: due)
        let priorID = try fixture.database.createRun(trigger: .scheduled, localDay: "2026-09-21", at: due)
        try fixture.database.finishRun(id: priorID, status: .succeeded, error: nil, at: due)
        let task = Task { await fixture.coordinator().run(trigger: .manual, force: true) }
        await fixture.gate.waitUntilWaitCount(1)
        XCTAssertEqual(fixture.performer.callCount, 0)
        fixture.gate.supplyReady()
        let exit = await task.value
        XCTAssertEqual(exit, .succeeded)
        XCTAssertEqual(fixture.performer.callCount, 1)
        XCTAssertEqual(fixture.backup.callCount, 1)
        XCTAssertEqual(fixture.backup.sawCurrentRunTerminalBeforeBackup, false)
        XCTAssertEqual(try fixture.runs().count, 2)
        XCTAssertEqual(fixture.gate.cancelCount, 1)
    }

    func testBackupFailureMarksRunFailed() async throws {
        let fixture = try Fixture(now: due)
        fixture.backup.error = TestFailure.backup
        fixture.gate.supplyReady()
        let exit = await fixture.coordinator().run(trigger: .scheduled)
        guard case let .failed(message) = exit else { return XCTFail("Expected failure, got \(exit)") }
        XCTAssertTrue(message.contains("backup"))
        XCTAssertEqual(try fixture.runs().map(\.status), [.failed])
        XCTAssertEqual(fixture.gate.cancelCount, 1)
        let releasedLock = try XCTUnwrap(try WorkerLock.acquire(url: fixture.lockURL))
        releasedLock.unlock()
    }

    func testUnavailableLockReturnsAlreadyRunningWithoutCreatingRun() async throws {
        let fixture = try Fixture(now: due)
        let heldLock = try XCTUnwrap(try WorkerLock.acquire(url: fixture.lockURL))
        defer { heldLock.unlock() }
        let exit = await fixture.coordinator().run(trigger: .scheduled)
        XCTAssertEqual(exit, .alreadyRunning)
        XCTAssertEqual(try fixture.runs(), [])
    }

    func testSuccessIsRecheckedAfterLockBeforeCreatingRun() async throws {
        let fixture = try Fixture(now: due)
        var insertedID: UUID?
        let coordinator = fixture.coordinator(acquireLock: {
            let id = try fixture.database.createRun(trigger: .manual, localDay: "2026-09-21", at: self.due)
            try fixture.database.finishRun(id: id, status: .succeeded, error: nil, at: self.due)
            insertedID = id
            return try WorkerLock.acquire(url: fixture.lockURL)
        })
        let exit = await coordinator.run(trigger: .scheduled)
        XCTAssertEqual(exit, .skippedAlreadySucceeded)
        XCTAssertEqual(try fixture.runs().map(\.id), [try XCTUnwrap(insertedID)])
        XCTAssertEqual(fixture.gate.waitCount, 0)
    }

    func testManualAndScheduledRaceCreatesOnlyOneRun() async throws {
        let databaseURL = TestDatabase.uniqueURL()
        let firstDatabase = try JobApplicationWidget.JobDatabase(url: databaseURL)
        let secondDatabase = try JobApplicationWidget.JobDatabase(url: databaseURL)
        let lockURL = databaseURL.deletingPathExtension().appendingPathExtension("lock")
        let firstGate = FakeNetworkGate()
        let secondGate = FakeNetworkGate()
        firstGate.supplyReady()
        secondGate.supplyReady()
        let first = WorkerCoordinator(
            database: firstDatabase, lockURL: lockURL, gate: firstGate,
            power: FakePowerEvents(), performer: ImmediatePerformer(), backup: BackupSpy(),
            now: { self.due }
        )
        let second = WorkerCoordinator(
            database: secondDatabase, lockURL: lockURL, gate: secondGate,
            power: FakePowerEvents(), performer: ImmediatePerformer(), backup: BackupSpy(),
            now: { self.due }
        )

        async let scheduled = first.run(trigger: .scheduled)
        async let manual = second.run(trigger: .manual)
        let exits = await [scheduled, manual]

        XCTAssertTrue(exits.contains(.succeeded))
        XCTAssertEqual(try RunSnapshot.all(at: databaseURL).count, 1)
    }

    func testExistingSuspendedRunResumesItsIDAndCheckpoint() async throws {
        let performer = ImmediatePerformer()
        let fixture = try Fixture(now: due, performer: performer)
        let runID = try fixture.database.createRun(trigger: .scheduled, localDay: "2026-09-21", at: due)
        try fixture.database.saveCheckpoint(
            runID: runID,
            stage: "saved-stage",
            payload: Data(#"{"cursor":"abc"}"#.utf8),
            at: due
        )
        try fixture.database.setRunStatus(id: runID, status: .suspended, at: due)
        fixture.gate.supplyReady()

        let exit = await fixture.coordinator().run(trigger: .scheduled)

        XCTAssertEqual(exit, .succeeded)
        XCTAssertEqual(performer.receivedStages, ["saved-stage"])
        XCTAssertEqual(try fixture.runs().map(\.id), [runID])
    }

    func testNetworkLossPersistsCheckpointThenResumesSameRunWithFreshResources() async throws {
        let performer = InterruptThenSucceedPerformer()
        let fixture = try Fixture(now: due, performer: performer)
        fixture.gate.supplyReady()
        let task = Task { await fixture.coordinator().run(trigger: .scheduled) }
        await performer.waitUntilSaved()
        fixture.gate.latestLease?.invalidate()
        await performer.waitUntilCancelCount(1)
        fixture.gate.supplyReady()
        let exit = await task.value
        XCTAssertEqual(exit, .succeeded)
        XCTAssertEqual(performer.callCount, 2)
        XCTAssertEqual(performer.receivedStages, [nil, "page-1"])
        XCTAssertEqual(fixture.resourceCount, 2)
        let runs = try fixture.runs()
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.status, .succeeded)
        XCTAssertEqual(runs.first?.checkpointStage, "page-1")
        XCTAssertEqual(Array(performer.events.prefix(2)), ["saved", "cancelled"])
    }

    func testNetworkLossWinsOverConcurrentPerformerError() async throws {
        let performer = NetworkErrorThenSucceedPerformer()
        let fixture = try Fixture(now: due, performer: performer)
        fixture.gate.supplyReady()
        let task = Task { await fixture.coordinator().run(trigger: .scheduled) }
        await performer.waitUntilFirstAttemptStarts()

        fixture.gate.latestLease?.invalidate()
        performer.failFirstAttempt()
        await fixture.gate.waitUntilWaitCount(2)
        fixture.gate.supplyReady()

        let exit = await task.value
        XCTAssertEqual(exit, .succeeded)
        XCTAssertEqual(performer.callCount, 2)
        XCTAssertEqual(try fixture.runs().count, 1)
        XCTAssertEqual(try fixture.runs().first?.status, .succeeded)
    }

    func testSleepWaitsForWakeAndFreshNetworkBeforeResumingSameRun() async throws {
        let performer = InterruptThenSucceedPerformer()
        let fixture = try Fixture(now: due, performer: performer)
        fixture.gate.supplyReady()
        let task = Task { await fixture.coordinator().run(trigger: .scheduled) }
        await performer.waitUntilSaved()
        fixture.power.emit(.willSleep)
        await performer.waitUntilCancelCount(1)
        fixture.gate.supplyReady()
        await Task.yield()
        XCTAssertEqual(performer.callCount, 1)
        fixture.power.emit(.didWake)
        let exit = await task.value
        XCTAssertEqual(exit, .succeeded)
        XCTAssertEqual(performer.callCount, 2)
        XCTAssertEqual(performer.receivedStages, [nil, "page-1"])
        XCTAssertEqual(try fixture.runs().count, 1)
    }

    func testSleepBeforeReadinessCancelsWaitAndDoesNotStartWorkUntilWake() async throws {
        let fixture = try Fixture(now: due)
        let task = Task { await fixture.coordinator().run(trigger: .scheduled) }
        await fixture.gate.waitUntilWaitCount(1)

        fixture.power.emit(.willSleep)
        await fixture.gate.waitUntilCancelledWaitCount(1)
        fixture.gate.supplyReady()
        await Task.yield()
        XCTAssertEqual(fixture.performer.callCount, 0)

        fixture.power.emit(.didWake)
        let exit = await task.value
        XCTAssertEqual(exit, .succeeded)
        XCTAssertEqual(fixture.performer.callCount, 1)
        XCTAssertEqual(try fixture.runs().count, 1)
    }

}

private final class Fixture {
    let databaseURL = TestDatabase.uniqueURL()
    let database: JobApplicationWidget.JobDatabase
    let lockURL: URL
    let gate = FakeNetworkGate()
    let power = FakePowerEvents()
    let performer: CountedPerformer
    let backup = BackupSpy()
    private let now: Date
    private let resourceLock = NSLock()
    private var resources: [WorkerResources] = []

    init(now: Date, performer: CountedPerformer = ImmediatePerformer()) throws {
        self.now = now
        self.performer = performer
        database = try JobApplicationWidget.JobDatabase(url: databaseURL)
        lockURL = databaseURL.deletingPathExtension().appendingPathExtension("lock")
    }

    var resourceCount: Int { resourceLock.withLock { resources.count } }

    func coordinator(acquireLock: (() throws -> WorkerLock?)? = nil) -> WorkerCoordinator {
        WorkerCoordinator(
            database: database, lockURL: lockURL, gate: gate, power: power,
            performer: performer, backup: backup,
            resourcesFactory: {
                let resource = WorkerResources()
                self.resourceLock.withLock { self.resources.append(resource) }
                return resource
            },
            now: { self.now }, acquireLock: acquireLock
        )
    }

    func runs() throws -> [RunSnapshot] { try RunSnapshot.all(at: databaseURL) }
}

private protocol CountedPerformer: WorkerPerforming { var callCount: Int { get } }

private final class FakeNetworkGate: NetworkGating {
    private let lock = NSLock()
    private var queued: [NetworkLease] = []
    private var waiter: (id: UUID, continuation: CheckedContinuation<NetworkLease, Swift.Error>)?
    private var cancelledIDs: Set<UUID> = []
    private var latest: NetworkLease?
    private var waits = 0
    private var resets = 0
    private var cancels = 0
    private var cancelledWaits = 0
    private var waitObservers: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var cancellationObservers: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
    var latestLease: NetworkLease? { lock.withLock { latest } }
    var waitCount: Int { lock.withLock { waits } }
    var resetCount: Int { lock.withLock { resets } }
    var cancelCount: Int { lock.withLock { cancels } }

    func supplyReady() {
        let lease = NetworkLease()
        let continuation: CheckedContinuation<NetworkLease, Swift.Error>? = lock.withLock {
            latest = lease
            if let waiter { self.waiter = nil; return waiter.continuation }
            queued.append(lease)
            return nil
        }
        continuation?.resume(returning: lease)
    }

    func waitUntilUsable() async throws -> NetworkLease {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result: (NetworkLease?, [CheckedContinuation<Void, Never>], Bool) = lock.withLock {
                    waits += 1
                    let reached = waitObservers.filter { $0.target <= waits }.map(\.continuation)
                    waitObservers.removeAll { $0.target <= waits }
                    if cancelledIDs.remove(id) != nil { return (nil, reached, true) }
                    if !queued.isEmpty { return (queued.removeFirst(), reached, false) }
                    waiter = (id, continuation)
                    return (nil, reached, false)
                }
                result.1.forEach { $0.resume() }
                if result.2 { continuation.resume(throwing: CancellationError()) }
                else if let ready = result.0 { continuation.resume(returning: ready) }
            }
        } onCancel: {
            self.cancelReadinessWait(id: id)
        }
    }

    func waitUntilWaitCount(_ target: Int) async {
        await withCheckedContinuation { continuation in
            let reached = lock.withLock { () -> Bool in
                if waits >= target { return true }
                waitObservers.append((target, continuation))
                return false
            }
            if reached { continuation.resume() }
        }
    }

    func waitUntilCancelledWaitCount(_ target: Int) async {
        await withCheckedContinuation { continuation in
            let reached = lock.withLock { () -> Bool in
                if cancelledWaits >= target { return true }
                cancellationObservers.append((target, continuation))
                return false
            }
            if reached { continuation.resume() }
        }
    }

    func reset() { lock.withLock { resets += 1 } }
    func cancel() {
        let continuation: CheckedContinuation<NetworkLease, Swift.Error>? = lock.withLock {
            cancels += 1
            let owned = waiter?.continuation
            waiter = nil
            return owned
        }
        continuation?.resume(throwing: CancellationError())
    }


    private func cancelReadinessWait(id: UUID) {
        let result: (CheckedContinuation<NetworkLease, Swift.Error>?, [CheckedContinuation<Void, Never>]) = lock.withLock {
            let continuation: CheckedContinuation<NetworkLease, Swift.Error>?
            if waiter?.id == id {
                continuation = waiter?.continuation
                waiter = nil
            } else {
                cancelledIDs.insert(id)
                continuation = nil
            }
            cancelledWaits += 1
            let observers = cancellationObservers.filter { $0.target <= cancelledWaits }.map(\.continuation)
            cancellationObservers.removeAll { $0.target <= cancelledWaits }
            return (continuation, observers)
        }
        result.0?.resume(throwing: CancellationError())
        result.1.forEach { $0.resume() }
    }
}

private final class FakePowerEvents: PowerEventSource {
    private let lock = NSLock()
    private var continuation: AsyncStream<PowerEvent>.Continuation?
    func events() -> AsyncStream<PowerEvent> {
        AsyncStream { continuation in self.lock.withLock { self.continuation = continuation } }
    }
    func emit(_ event: PowerEvent) { lock.withLock { continuation?.yield(event) } }
}

private final class ImmediatePerformer: CountedPerformer {
    private let lock = NSLock()
    private var calls = 0
    private var stages: [String?] = []
    var callCount: Int { lock.withLock { calls } }
    var receivedStages: [String?] { lock.withLock { stages } }
    func perform(from checkpoint: WorkerCheckpoint?, save: @escaping (WorkerCheckpoint) async throws -> Void, resources: WorkerResources) async throws {
        lock.withLock { calls += 1; stages.append(checkpoint?.stage) }
    }
}

private final class InterruptThenSucceedPerformer: CountedPerformer {
    private let lock = NSLock()
    private var calls = 0
    private var saved = false
    private var cancellations = 0
    private var stages: [String?] = []
    private var recordedEvents: [String] = []
    private var saveWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
    var callCount: Int { lock.withLock { calls } }
    var didSave: Bool { lock.withLock { saved } }
    var cancelCount: Int { lock.withLock { cancellations } }
    var receivedStages: [String?] { lock.withLock { stages } }
    var events: [String] { lock.withLock { recordedEvents } }

    func waitUntilSaved() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in
                if saved { return true }
                saveWaiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func waitUntilCancelCount(_ target: Int) async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in
                if cancellations >= target { return true }
                cancelWaiters.append((target, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func perform(from checkpoint: WorkerCheckpoint?, save: @escaping (WorkerCheckpoint) async throws -> Void, resources: WorkerResources) async throws {
        let attempt = lock.withLock { () -> Int in
            calls += 1
            stages.append(checkpoint?.stage)
            return calls
        }
        guard attempt == 1 else { return }
        let checkpoint = WorkerCheckpoint(stage: "page-1", payload: Data(#"{"page":1}"#.utf8))
        try await save(checkpoint)
        let savedObservers: [CheckedContinuation<Void, Never>] = lock.withLock {
            saved = true
            recordedEvents.append("saved")
            let owned = saveWaiters
            saveWaiters.removeAll()
            return owned
        }
        savedObservers.forEach { $0.resume() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            resources.registerCancellation {
                let observers: [CheckedContinuation<Void, Never>] = self.lock.withLock {
                    self.cancellations += 1
                    self.recordedEvents.append("cancelled")
                    let reached = self.cancelWaiters.filter { $0.target <= self.cancellations }.map(\.continuation)
                    self.cancelWaiters.removeAll { $0.target <= self.cancellations }
                    return reached
                }
                observers.forEach { $0.resume() }
                continuation.resume(throwing: CancellationError())
            }
        }
    }
}

private final class NetworkErrorThenSucceedPerformer: CountedPerformer {
    private let lock = NSLock()
    private var calls = 0
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var failureContinuation: CheckedContinuation<Void, Swift.Error>?
    var callCount: Int { lock.withLock { calls } }

    func waitUntilFirstAttemptStarts() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in
                if started { return true }
                startWaiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func failFirstAttempt() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Swift.Error>? in
            let owned = failureContinuation
            failureContinuation = nil
            return owned
        }
        continuation?.resume(throwing: TestFailure.network)
    }

    func perform(from checkpoint: WorkerCheckpoint?, save: @escaping (WorkerCheckpoint) async throws -> Void, resources: WorkerResources) async throws {
        let attempt = lock.withLock { () -> Int in calls += 1; return calls }
        guard attempt == 1 else { return }
        try await withCheckedThrowingContinuation { continuation in
            let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
                failureContinuation = continuation
                started = true
                let owned = startWaiters
                startWaiters.removeAll()
                return owned
            }
            waiters.forEach { $0.resume() }
        }
    }
}

private final class BackupSpy: SuccessfulRunBackupWriting {
    private let lock = NSLock()
    var error: Swift.Error?
    private var calls = 0
    private var sawCurrentRunTerminal = false
    var callCount: Int { lock.withLock { calls } }
    var sawCurrentRunTerminalBeforeBackup: Bool { lock.withLock { sawCurrentRunTerminal } }
    func writeSuccessfulBackup(database: JobApplicationWidget.JobDatabase, runID: UUID, at: Date) throws -> URL {
        let currentRunWasTerminal = try database.latestResumableRun(localDay: "2026-09-21")?.id != runID
        try lock.withLock {
            calls += 1
            sawCurrentRunTerminal = currentRunWasTerminal
            if let error { throw error }
        }
        return URL(fileURLWithPath: "/dev/null")
    }
}

private enum TestFailure: Swift.Error { case backup, network }

private struct RunSnapshot: Equatable {
    let id: UUID
    let status: RunStatus
    let checkpointStage: String?

    static func all(at url: URL) throws -> [RunSnapshot] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(database); throw TestFailure.backup
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT id, status, checkpoint_stage FROM runs ORDER BY started_at, id", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw TestFailure.backup }
        defer { sqlite3_finalize(statement) }
        var result: [RunSnapshot] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0),
                  let statusText = sqlite3_column_text(statement, 1),
                  let id = UUID(uuidString: String(cString: idText)),
                  let status = RunStatus(rawValue: String(cString: statusText)) else { throw TestFailure.backup }
            let stage = sqlite3_column_text(statement, 2).map { String(cString: $0) }
            result.append(RunSnapshot(id: id, status: status, checkpointStage: stage))
        }
        return result
    }
}
