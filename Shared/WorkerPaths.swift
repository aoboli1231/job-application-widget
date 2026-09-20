import Foundation

struct WorkerPaths {
    let root: URL

    init(containerURL: URL) {
        root = containerURL.appendingPathComponent(
            "Library/Application Support/JobApplicationCopilot",
            isDirectory: true
        )
    }

    var lockURL: URL { root.appendingPathComponent("worker.lock") }
    var backupDirectoryURL: URL { root.appendingPathComponent("Backups", isDirectory: true) }
    var launchAgentPlistURL: URL { root.appendingPathComponent("com.aobo.JobApplicationCopilot.worker.plist") }
}
