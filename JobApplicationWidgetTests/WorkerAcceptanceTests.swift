import SQLite3
import XCTest
@testable import JobApplicationWidget

final class WorkerAcceptanceTests: XCTestCase {
    func testOfflineSleepWakeStableNetworkRunAndBackup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("jobs.sqlite3")
        let database = try JobApplicationWidget.JobDatabase(url: databaseURL)
        try database.upsert(
            JobApplicationWidget.Job(company: "Example", role: "Analyst", location: "Melbourne"),
            preservingTracking: false
        )

        let monitorStarted = expectation(description: "path monitor started")
        let timerArmed = expectation(description: "stability timer armed")
        let suspended = expectation(description: "worker suspended for sleep")
        let monitor = AcceptancePathMonitor(onStart: { monitorStarted.fulfill() })
        let timers = AcceptanceTimerScheduler(onSchedule: { timerArmed.fulfill() })
        let requester = AcceptanceRequester()
        let power = AcceptancePowerEvents()
        let performer = AcceptancePerformer()
        let clock = AcceptanceClock()
        let gate = NetworkGate(
            monitor: monitor,
            requester: requester,
            policy: ProbePolicy(
                urls: [URL(string: "https://probe-one.invalid")!, URL(string: "https://probe-two.invalid")!],
                delayBetweenProbes: 3
            ),
            timerScheduler: timers,
            now: clock.uptime,
            delay: { _ in }
        )
        let coordinator = WorkerCoordinator(
            database: database,
            lockURL: root.appendingPathComponent("worker.lock"),
            gate: gate,
            power: power,
            performer: performer,
            backup: JSONBackupWriter(directoryURL: root.appendingPathComponent("backups")),
            now: { Self.afterEight },
            onTransition: { state in
                if state == "suspended" { suspended.fulfill() }
            }
        )

        let task = Task { await coordinator.run(trigger: .scheduled) }
        await fulfillment(of: [monitorStarted])
        monitor.emit(satisfied: false)
        power.emit(.willSleep)
        await fulfillment(of: [suspended])
        power.emit(.didWake)
        monitor.emit(satisfied: true)
        await fulfillment(of: [timerArmed])

        XCTAssertEqual(performer.callCount, 0)
        XCTAssertEqual(requester.callCount, 0)
        XCTAssertEqual(timers.scheduleCount, 1)

        clock.setUptime(60)
        timers.fireLatest()
        let result = await task.value
        XCTAssertEqual(result, .succeeded)

        XCTAssertEqual(requester.callCount, 2)
        XCTAssertEqual(performer.callCount, 1)
        XCTAssertEqual(try Self.runStatuses(at: databaseURL), [.succeeded])
        let backups = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("backups"),
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        XCTAssertEqual(backups.count, 1)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(JobBackup.self, from: Data(contentsOf: backups[0])).jobs.count, 1)
    }

    func testOneOfflineHourSchedulesNoTimerOrProbeUntilPathEvent() async {
        let monitorStarted = expectation(description: "path monitor started")
        let timerArmed = expectation(description: "timer armed after path event")
        let monitor = AcceptancePathMonitor(onStart: { monitorStarted.fulfill() })
        let timers = AcceptanceTimerScheduler(onSchedule: { timerArmed.fulfill() })
        let requester = AcceptanceRequester()
        let clock = AcceptanceClock()
        let gate = NetworkGate(
            monitor: monitor,
            requester: requester,
            policy: ProbePolicy(
                urls: [URL(string: "https://probe-one.invalid")!, URL(string: "https://probe-two.invalid")!],
                delayBetweenProbes: 3
            ),
            timerScheduler: timers,
            now: clock.uptime,
            delay: { _ in }
        )
        let task = Task { try await gate.waitUntilUsable() }

        await fulfillment(of: [monitorStarted])
        clock.setUptime(3_600)
        XCTAssertEqual(timers.scheduleCount, 0)
        XCTAssertEqual(requester.callCount, 0)

        monitor.emit(satisfied: true)
        await fulfillment(of: [timerArmed])
        XCTAssertEqual(timers.scheduleCount, 1)
        XCTAssertEqual(requester.callCount, 0)

        gate.cancel()
        task.cancel()
        _ = try? await task.value
    }

    func testThirtyOneForcedRunsKeepThirtyValidBackups() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("jobs.sqlite3")
        let database = try JobApplicationWidget.JobDatabase(url: databaseURL)
        let backupDirectory = root.appendingPathComponent("backups")
        let performer = AcceptancePerformer()

        for offset in 0..<31 {
            let date = Self.afterEight.addingTimeInterval(Double(offset))
            let coordinator = WorkerCoordinator(
                database: database,
                lockURL: root.appendingPathComponent("worker.lock"),
                gate: AcceptanceReadyGate(),
                power: AcceptancePowerEvents(),
                performer: performer,
                backup: JSONBackupWriter(directoryURL: backupDirectory),
                now: { date }
            )
            let exit = await coordinator.run(trigger: .manual, force: true)
            XCTAssertEqual(exit, .succeeded)
        }

        XCTAssertEqual(performer.callCount, 31)
        XCTAssertEqual(try Self.runStatuses(at: databaseURL), Array(repeating: .succeeded, count: 31))
        let backups = try FileManager.default.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        XCTAssertEqual(backups.count, 30)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try backups.map { try decoder.decode(JobBackup.self, from: Data(contentsOf: $0)) }
        XCTAssertEqual(Set(decoded.map(\.runID)).count, 30)
        XCTAssertEqual(decoded.map(\.createdAt).min(), Self.afterEight.addingTimeInterval(1))
        XCTAssertEqual(decoded.map(\.createdAt).max(), Self.afterEight.addingTimeInterval(30))
    }

    private static let afterEight = ISO8601DateFormatter()
        .date(from: "2026-09-21T09:00:00+10:00")!

    private static func runStatuses(at url: URL) throws -> [RunStatus] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(database)
            throw AcceptanceError.database
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT status FROM runs ORDER BY started_at, id", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw AcceptanceError.database }
        defer { sqlite3_finalize(statement) }
        var statuses: [RunStatus] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0),
                  let status = RunStatus(rawValue: String(cString: text)) else {
                throw AcceptanceError.database
            }
            statuses.append(status)
        }
        return statuses
    }
}

private final class AcceptanceClock {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    func uptime() -> TimeInterval { lock.withLock { value } }
    func setUptime(_ value: TimeInterval) { lock.withLock { self.value = value } }
}

private final class AcceptancePathMonitor: NetworkPathMonitoring {
    var updateHandler: ((Bool) -> Void)?
    private let onStart: () -> Void

    init(onStart: @escaping () -> Void) { self.onStart = onStart }
    func start(queue: DispatchQueue) { onStart() }
    func cancel() {}
    func emit(satisfied: Bool) { updateHandler?(satisfied) }
}

private final class AcceptanceTimerScheduler: OneShotTimerScheduling {
    private final class Token: NetworkGateCancellation {
        let handler: () -> Void
        private(set) var isCancelled = false
        init(handler: @escaping () -> Void) { self.handler = handler }
        func cancel() { isCancelled = true }
    }

    private let lock = NSLock()
    private var tokens: [Token] = []
    private let onSchedule: () -> Void
    var scheduleCount: Int { lock.withLock { tokens.count } }

    init(onSchedule: @escaping () -> Void) { self.onSchedule = onSchedule }

    func schedule(after interval: TimeInterval, handler: @escaping () -> Void) -> NetworkGateCancellation {
        lock.withLock { tokens.append(Token(handler: handler)) }
        onSchedule()
        return lock.withLock { tokens.last! }
    }

    func fireLatest() {
        let token = lock.withLock { tokens.last }
        if token?.isCancelled == false { token?.handler() }
    }
}

private final class AcceptanceRequester: HTTPSRequesting {
    private let lock = NSLock()
    private var calls = 0
    var callCount: Int { lock.withLock { calls } }

    func statusCode(for url: URL) async throws -> Int {
        lock.withLock { calls += 1 }
        return 204
    }
}

private final class AcceptanceReadyGate: NetworkGating {
    func waitUntilUsable() async throws -> NetworkLease { NetworkLease() }
    func reset() {}
    func cancel() {}
}

private final class AcceptancePowerEvents: PowerEventSource {
    private let stream: AsyncStream<PowerEvent>
    private let continuation: AsyncStream<PowerEvent>.Continuation

    init() {
        var captured: AsyncStream<PowerEvent>.Continuation!
        stream = AsyncStream { captured = $0 }
        continuation = captured
    }

    func events() -> AsyncStream<PowerEvent> { stream }
    func emit(_ event: PowerEvent) { continuation.yield(event) }
}

private final class AcceptancePerformer: WorkerPerforming {
    private let lock = NSLock()
    private var calls = 0
    var callCount: Int { lock.withLock { calls } }

    func perform(
        from checkpoint: WorkerCheckpoint?,
        save: @escaping (WorkerCheckpoint) async throws -> Void,
        resources: WorkerResources
    ) async throws {
        lock.withLock { calls += 1 }
        try await save(WorkerCheckpoint(
            stage: "acceptance-complete",
            payload: Data(#"{"completed":true}"#.utf8)
        ))
    }
}

private enum AcceptanceError: Error { case database }
