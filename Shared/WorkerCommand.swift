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
