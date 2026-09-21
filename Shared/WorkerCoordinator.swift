import Foundation

struct WorkerCheckpoint: Equatable {
    let stage: String
    let payload: Data

    func validate() throws {
        guard !stage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkerCoordinator.Error.invalidCheckpoint("Checkpoint stage is empty")
        }
        guard (try? JSONSerialization.jsonObject(with: payload)) != nil else {
            throw WorkerCoordinator.Error.invalidCheckpoint("Checkpoint payload is not JSON")
        }
    }
}

protocol WorkerPerforming {
    func perform(
        from checkpoint: WorkerCheckpoint?,
        save: @escaping (WorkerCheckpoint) async throws -> Void,
        resources: WorkerResources
    ) async throws
}

protocol SuccessfulRunBackupWriting {
    func writeSuccessfulBackup(database: JobDatabase, runID: UUID, at: Date) throws -> URL
}

enum WorkerExit: Equatable {
    case succeeded, skippedNotDue, skippedAlreadySucceeded, alreadyRunning
    case failed(String)
}

final class WorkerCoordinator {
    enum Error: Swift.Error, Equatable { case invalidCheckpoint(String) }

    private let database: JobDatabase
    private let schedule: MelbourneSchedule
    private let acquireLock: () throws -> WorkerLock?
    private let gate: NetworkGating
    private let power: PowerEventSource
    private let performer: WorkerPerforming
    private let backup: SuccessfulRunBackupWriting
    private let resourcesFactory: () -> WorkerResources
    private let now: () -> Date
    private let onTransition: (String) -> Void

    init(
        database: JobDatabase,
        schedule: MelbourneSchedule = MelbourneSchedule(),
        lockURL: URL,
        gate: NetworkGating,
        power: PowerEventSource,
        performer: WorkerPerforming,
        backup: SuccessfulRunBackupWriting,
        resourcesFactory: @escaping () -> WorkerResources = { WorkerResources() },
        now: @escaping () -> Date = Date.init,
        onTransition: @escaping (String) -> Void = { _ in },
        acquireLock: (() throws -> WorkerLock?)? = nil
    ) {
        self.database = database
        self.schedule = schedule
        self.acquireLock = acquireLock ?? { try WorkerLock.acquire(url: lockURL) }
        self.gate = gate
        self.power = power
        self.performer = performer
        self.backup = backup
        self.resourcesFactory = resourcesFactory
        self.now = now
        self.onTransition = onTransition
    }

    func run(trigger: RunTrigger, force: Bool = false) async -> WorkerExit {
        let startedAt = now()
        let localDay = schedule.localDay(at: startedAt)
        if !force, !schedule.isDue(at: startedAt) {
            onTransition("skipped_not_due")
            return .skippedNotDue
        }
        do {
            if !force, try database.hasSuccessfulRun(localDay: localDay) {
                onTransition("skipped_already_succeeded")
                return .skippedAlreadySucceeded
            }
        } catch { return .failed(Self.message(error)) }

        let workerLock: WorkerLock
        do {
            guard let lock = try acquireLock() else {
                onTransition("already_running")
                return .alreadyRunning
            }
            workerLock = lock
        } catch { return .failed(Self.message(error)) }
        defer { workerLock.unlock() }

        do {
            if !force, try database.hasSuccessfulRun(localDay: localDay) {
                onTransition("skipped_already_succeeded")
                return .skippedAlreadySucceeded
            }
            let existing = try database.latestResumableRun(localDay: localDay)
            let runID = try existing?.id ?? database.createRun(trigger: trigger, localDay: localDay, at: startedAt)
            var checkpoint = Self.checkpoint(from: existing)
            let inbox = PowerInbox()
            let stream = power.events()
            let powerPump = Task { for await event in stream { await inbox.send(event) } }
            let result = await runAttempts(runID: runID, checkpoint: &checkpoint, inbox: inbox)
            gate.cancel()
            powerPump.cancel()
            await powerPump.value
            return result
        } catch {
            gate.cancel()
            return .failed(Self.message(error))
        }
    }

    private func runAttempts(
        runID: UUID,
        checkpoint: inout WorkerCheckpoint?,
        inbox: PowerInbox
    ) async -> WorkerExit {
        while !Task.isCancelled {
            do {
                if await inbox.isAsleep { try await inbox.waitUntilWake() }
                onTransition("waiting_for_network")
                switch try await waitForReadinessOrSleep(inbox: inbox) {
                case let .ready(lease):
                    try database.setRunStatus(id: runID, status: .running, at: now())
                    onTransition("running")
                    let resources = resourcesFactory()
                    let state = AttemptState(database: database, runID: runID, checkpoint: checkpoint, now: now)
                    let outcome = await raceAttempt(lease: lease, inbox: inbox, resources: resources, state: state)
                    checkpoint = state.latestCheckpoint
                    resources.cancelAll()
                    switch outcome {
                    case .succeeded:
                        do {
                            _ = try backup.writeSuccessfulBackup(database: database, runID: runID, at: now())
                            try database.finishRun(id: runID, status: .succeeded, error: nil, at: now())
                            onTransition("succeeded")
                            return .succeeded
                        } catch { return finishFailed(runID: runID, error: error) }
                    case let .failed(message):
                        return finishFailed(runID: runID, message: message)
                    case .interrupted:
                        onTransition("suspended")
                        gate.reset()
                        if await inbox.isAsleep { try await inbox.waitUntilWake() }
                    case .lost:
                        return finishFailed(runID: runID, message: "Worker attempt ended without a result")
                    }
                case .sleep:
                    try database.setRunStatus(id: runID, status: .suspended, at: now())
                    onTransition("suspended")
                    gate.reset()
                    try await inbox.waitUntilWake()
                }
            } catch is CancellationError {
                return finishFailed(runID: runID, message: "Worker was cancelled")
            } catch { return finishFailed(runID: runID, error: error) }
        }
        return finishFailed(runID: runID, message: "Worker was cancelled")
    }

    private func waitForReadinessOrSleep(inbox: PowerInbox) async throws -> ReadinessOutcome {
        try await withThrowingTaskGroup(of: ReadinessOutcome.self) { group in
            group.addTask { .ready(try await self.gate.waitUntilUsable()) }
            group.addTask { try await inbox.waitUntilSleep(); return .sleep }
            guard let first = try await group.next() else { throw CancellationError() }
            group.cancelAll()
            while (try? await group.next()) != nil {}
            return first
        }
    }

    private func raceAttempt(
        lease: NetworkLease,
        inbox: PowerInbox,
        resources: WorkerResources,
        state: AttemptState
    ) async -> AttemptOutcome {
        await withTaskGroup(of: AttemptOutcome.self) { group in
            group.addTask {
                do {
                    try await self.performer.perform(
                        from: state.latestCheckpoint,
                        save: { try state.save($0) },
                        resources: resources
                    )
                    let asleep = await inbox.isAsleep
                    return state.claimTerminal(unless: { asleep || lease.isInvalidated }) ? .succeeded : .lost
                } catch {
                    let asleep = await inbox.isAsleep
                    return state.claimTerminal(unless: { asleep || lease.isInvalidated })
                        ? .failed(Self.message(error))
                        : .lost
                }
            }
            group.addTask {
                do { try await lease.waitForInvalidation() } catch { return .lost }
                return self.claimInterruption(state: state, resources: resources)
            }
            group.addTask {
                do { try await inbox.waitUntilSleep() } catch { return .lost }
                return self.claimInterruption(state: state, resources: resources)
            }
            var winner = AttemptOutcome.lost
            while let result = await group.next() {
                if result != .lost {
                    winner = result
                    group.cancelAll()
                    break
                }
            }
            while await group.next() != nil {}
            return winner
        }
    }

    private func claimInterruption(state: AttemptState, resources: WorkerResources) -> AttemptOutcome {
        do {
            guard try state.claimInterruption() else { return .lost }
            resources.cancelAll()
            return .interrupted
        } catch {
            resources.cancelAll()
            return .failed(Self.message(error))
        }
    }

    private func finishFailed(runID: UUID, error: Swift.Error) -> WorkerExit {
        finishFailed(runID: runID, message: Self.message(error))
    }

    private func finishFailed(runID: UUID, message: String) -> WorkerExit {
        do {
            try database.finishRun(id: runID, status: .failed, error: message, at: now())
            onTransition("failed")
            return .failed(message)
        } catch {
            onTransition("failed")
            return .failed("\(message); could not persist failure: \(Self.message(error))")
        }
    }

    private static func checkpoint(from run: RunRecord?) -> WorkerCheckpoint? {
        guard let stage = run?.checkpointStage, let payload = run?.checkpointPayload else { return nil }
        return WorkerCheckpoint(stage: stage, payload: payload)
    }

    private static func message(_ error: Swift.Error) -> String { String(describing: error) }
}

private enum ReadinessOutcome { case ready(NetworkLease), sleep }
private enum AttemptOutcome: Equatable { case succeeded, failed(String), interrupted, lost }

private final class AttemptState {
    private let lock = NSLock()
    private let database: JobDatabase
    private let runID: UUID
    private let now: () -> Date
    private var active = true
    private var checkpoint: WorkerCheckpoint?

    init(database: JobDatabase, runID: UUID, checkpoint: WorkerCheckpoint?, now: @escaping () -> Date) {
        self.database = database
        self.runID = runID
        self.checkpoint = checkpoint
        self.now = now
    }

    var latestCheckpoint: WorkerCheckpoint? {
        lock.lock(); defer { lock.unlock() }
        return checkpoint
    }

    func save(_ newCheckpoint: WorkerCheckpoint) throws {
        try newCheckpoint.validate()
        lock.lock(); defer { lock.unlock() }
        guard active else { throw CancellationError() }
        try database.saveCheckpoint(
            runID: runID,
            stage: newCheckpoint.stage,
            payload: newCheckpoint.payload,
            at: now()
        )
        checkpoint = newCheckpoint
    }

    func claimTerminal(unless interrupted: () -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard active else { return false }
        guard !interrupted() else { return false }
        active = false
        return true
    }

    func claimInterruption() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard active else { return false }
        try database.setRunStatus(id: runID, status: .suspended, at: now())
        active = false
        return true
    }
}

private actor PowerInbox {
    private var queued: [PowerEvent] = []
    private var waiter: (id: UUID, continuation: CheckedContinuation<PowerEvent, Swift.Error>)?
    private var cancelledIDs: Set<UUID> = []
    private(set) var isAsleep = false

    func send(_ event: PowerEvent) {
        isAsleep = event == .willSleep
        if let waiter {
            self.waiter = nil
            waiter.continuation.resume(returning: event)
        } else { queued.append(event) }
    }

    func waitUntilSleep() async throws {
        if isAsleep { return }
        while try await next() != .willSleep {}
    }

    func waitUntilWake() async throws {
        if !isAsleep { return }
        while try await next() != .didWake {}
    }

    private func next() async throws -> PowerEvent {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled || cancelledIDs.remove(id) != nil {
                    continuation.resume(throwing: CancellationError())
                } else if !queued.isEmpty {
                    continuation.resume(returning: queued.removeFirst())
                } else if waiter != nil {
                    continuation.resume(throwing: CancellationError())
                } else { waiter = (id, continuation) }
            }
        } onCancel: { Task { await self.cancelWaiter(id: id) } }
    }

    private func cancelWaiter(id: UUID) {
        if waiter?.id == id {
            let continuation = waiter?.continuation
            waiter = nil
            continuation?.resume(throwing: CancellationError())
        } else { cancelledIDs.insert(id) }
    }
}
