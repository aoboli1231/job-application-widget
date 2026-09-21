import Darwin
import Foundation
import OSLog

private struct FoundationBackupPerformer: WorkerPerforming {
    func perform(
        from checkpoint: WorkerCheckpoint?,
        save: @escaping (WorkerCheckpoint) async throws -> Void,
        resources: WorkerResources
    ) async throws {
        if checkpoint?.stage == "foundation-backup" { return }
        try await save(WorkerCheckpoint(
            stage: "foundation-backup",
            payload: Data(#"{"schemaVersion":1}"#.utf8)
        ))
    }
}

private let logger = Logger(subsystem: "com.aobo.JobApplicationCopilot", category: "worker")

private func run() async -> Int32 {
    do {
        let command = try WorkerCommand(arguments: CommandLine.arguments)
        let (trigger, force): (RunTrigger, Bool)
        switch command {
        case let .run(value, shouldForce): (trigger, force) = (value, shouldForce)
        }

        let location = DatabaseLocation()
        let containerURL = try location.containerURL()
        let paths = WorkerPaths(containerURL: containerURL)
        let database = try JobDatabase(url: paths.root.appendingPathComponent("jobs.sqlite3"))
        let coordinator = WorkerCoordinator(
            database: database,
            lockURL: paths.lockURL,
            gate: NetworkGate(),
            power: WorkspacePowerEvents(),
            performer: FoundationBackupPerformer(),
            backup: JSONBackupWriter(directoryURL: paths.backupDirectoryURL),
            onTransition: { state in
                logger.info("event=worker_transition state=\(state, privacy: .public)")
            }
        )

        logger.info("event=worker_started trigger=\(trigger.rawValue, privacy: .public) force=\(force)")
        let result = await coordinator.run(trigger: trigger, force: force)
        switch result {
        case .succeeded:
            logger.info("event=worker_finished result=succeeded")
            return 0
        case .skippedNotDue:
            logger.info("event=worker_finished result=skipped_not_due")
            return 0
        case .skippedAlreadySucceeded:
            logger.info("event=worker_finished result=skipped_already_succeeded")
            return 0
        case .alreadyRunning:
            logger.info("event=worker_finished result=already_running")
            return 0
        case let .failed(message):
            logger.error("event=worker_finished result=failed error=\(message, privacy: .public)")
            fputs("job-scout: \(message)\n", stderr)
            return 1
        }
    } catch {
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        fputs("job-scout: \(message)\n", stderr)
        return error is WorkerCommand.Error ? 64 : 1
    }
}

Task {
    let status = await run()
    exit(status)
}
dispatchMain()
