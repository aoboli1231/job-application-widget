import Foundation

struct DatabaseLocation {
    enum Error: Swift.Error { case appGroupUnavailable(String) }
    let appGroupID: String
    private let containerURLProvider: () -> URL?

    init(appGroupID: String = "group.com.aobo.JobApplicationCopilot", fileManager: FileManager = .default) {
        self.appGroupID = appGroupID
        containerURLProvider = { fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) }
    }

    init(appGroupID: String, containerURLProvider: @escaping () -> URL?) {
        self.appGroupID = appGroupID
        self.containerURLProvider = containerURLProvider
    }

    func containerURL() throws -> URL {
        guard let container = containerURLProvider() else { throw Error.appGroupUnavailable(appGroupID) }
        return container
    }

    func databaseURL() throws -> URL {
        try containerURL().appendingPathComponent("Library/Application Support/JobApplicationCopilot/jobs.sqlite3")
    }
}
