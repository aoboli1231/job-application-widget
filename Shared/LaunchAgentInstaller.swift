import Darwin
import Foundation

struct LaunchAgentCommandResult: Equatable {
    let status: Int32
    let standardError: String
}

final class LaunchAgentInstaller {
    enum Error: Swift.Error, Equatable, LocalizedError {
        case invalidWorkerURL(String)
        case launchctlFailed(command: String, status: Int32, standardError: String)

        var errorDescription: String? {
            switch self {
            case let .invalidWorkerURL(path):
                return "Worker executable is unavailable: \(path)"
            case let .launchctlFailed(command, status, standardError):
                let detail = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
                return detail.isEmpty
                    ? "launchctl \(command) failed with status \(status)"
                    : "launchctl \(command) failed with status \(status): \(detail)"
            }
        }
    }

    typealias CommandRunner = (_ executable: URL, _ arguments: [String]) throws -> LaunchAgentCommandResult

    static let label = "com.aobo.JobApplicationCopilot.worker"

    private let fileManager: FileManager
    private let libraryDirectory: URL
    private let uid: uid_t
    private let commandRunner: CommandRunner

    init(
        fileManager: FileManager = .default,
        libraryDirectory: URL? = nil,
        uid: uid_t = getuid(),
        commandRunner: CommandRunner? = nil
    ) {
        self.fileManager = fileManager
        self.libraryDirectory = libraryDirectory
            ?? fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        self.uid = uid
        self.commandRunner = commandRunner ?? Self.runCommand
    }

    static func makePlist(
        workerURL: URL,
        localTimeZone: TimeZone = .current,
        startingAt date: Date = Date()
    ) -> [String: Any] {
        var melbourne = Calendar(identifier: .gregorian)
        melbourne.timeZone = MelbourneSchedule.timeZone
        var local = Calendar(identifier: .gregorian)
        local.timeZone = localTimeZone
        let firstDay = melbourne.startOfDay(for: date)
        let localMinutes = Set((0..<370).compactMap { offset -> Int? in
            guard let day = melbourne.date(byAdding: .day, value: offset, to: firstDay),
                  let eight = melbourne.date(bySettingHour: 8, minute: 0, second: 0, of: day) else {
                return nil
            }
            let components = local.dateComponents([.hour, .minute], from: eight)
            guard let hour = components.hour, let minute = components.minute else { return nil }
            return hour * 60 + minute
        })
        let intervals = localMinutes.sorted().map { ["Hour": $0 / 60, "Minute": $0 % 60] }
        let calendarInterval: Any = intervals.count == 1 ? intervals[0] : intervals
        return [
            "Label": label,
            "ProgramArguments": [workerURL.path, "--scheduled"],
            "RunAtLoad": true,
            "StartCalendarInterval": calendarInterval
        ]
    }

    func install(workerURL: URL) throws {
        guard workerURL.isFileURL, workerURL.path.hasPrefix("/"),
              fileManager.isExecutableFile(atPath: workerURL.path) else {
            throw Error.invalidWorkerURL(workerURL.path)
        }

        let directory = libraryDirectory.appendingPathComponent("LaunchAgents", isDirectory: true)
        let plistURL = directory.appendingPathComponent(Self.label).appendingPathExtension("plist")
        let plist = Self.makePlist(workerURL: workerURL)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let existingData = try? Data(contentsOf: plistURL)

        if let existingData, Self.propertyList(existingData, equals: plist) { return }
        if existingData != nil { try runLaunchctl("bootout", [domain, plistURL.path]) }

        try write(data, to: plistURL, creating: directory)
        do {
            try runLaunchctl("bootstrap", [domain, plistURL.path])
        } catch {
            if let existingData {
                try? write(existingData, to: plistURL, creating: directory)
                _ = try? runLaunchctl("bootstrap", [domain, plistURL.path])
            } else {
                try? fileManager.removeItem(at: plistURL)
            }
            throw error
        }
    }

    private var domain: String { "gui/\(uid)" }

    private func write(_ data: Data, to plistURL: URL, creating directory: URL) throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: plistURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plistURL.path)
    }

    private func runLaunchctl(_ command: String, _ arguments: [String]) throws {
        let result = try commandRunner(URL(fileURLWithPath: "/bin/launchctl"), [command] + arguments)
        guard result.status == 0 else {
            throw Error.launchctlFailed(
                command: command,
                status: result.status,
                standardError: result.standardError
            )
        }
    }

    private static func propertyList(_ data: Data, equals expected: [String: Any]) -> Bool {
        guard let decoded = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = decoded as? NSDictionary else { return false }
        return dictionary.isEqual(to: expected)
    }

    private static func runCommand(executable: URL, arguments: [String]) throws -> LaunchAgentCommandResult {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        return LaunchAgentCommandResult(
            status: process.terminationStatus,
            standardError: String(decoding: data, as: UTF8.self)
        )
    }
}
