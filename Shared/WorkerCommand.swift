import Foundation

enum WorkerCommand: Equatable {
    enum Error: Swift.Error, Equatable, LocalizedError {
        case invalidArguments

        var errorDescription: String? { "usage: job-scout --scheduled | --force" }
    }

    case run(trigger: RunTrigger, force: Bool)

    init(arguments: [String]) throws {
        guard arguments.count == 2 else { throw Error.invalidArguments }
        switch arguments[1] {
        case "--scheduled": self = .run(trigger: .scheduled, force: false)
        case "--force": self = .run(trigger: .manual, force: true)
        default: throw Error.invalidArguments
        }
    }
}

enum WorkerResultToken: String {
    static let prefix = "job-scout-result:"

    case succeeded
    case skippedNotDue = "skipped_not_due"
    case skippedAlreadySucceeded = "skipped_already_succeeded"
    case alreadyRunning = "already_running"
    case failed

    var line: String { Self.prefix + rawValue }

    static func parse(_ output: String) -> WorkerResultToken? {
        output.split(whereSeparator: \.isNewline)
            .compactMap { line in
                guard line.hasPrefix(prefix) else { return nil }
                return WorkerResultToken(rawValue: String(line.dropFirst(prefix.count)))
            }
            .last
    }
}
