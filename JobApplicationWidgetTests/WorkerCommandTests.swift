import XCTest
@testable import JobApplicationWidget

final class WorkerCommandTests: XCTestCase {
    func testScheduledArgumentMapsToScheduledNonForceRun() throws {
        XCTAssertEqual(
            try WorkerCommand(arguments: ["job-scout", "--scheduled"]),
            .run(trigger: .scheduled, force: false)
        )
    }

    func testForceArgumentMapsOnlyToManualForceRun() throws {
        XCTAssertEqual(
            try WorkerCommand(arguments: ["job-scout", "--force"]),
            .run(trigger: .manual, force: true)
        )
    }

    func testRejectsMissingUnknownAndExtraArguments() {
        for arguments in [
            ["job-scout"],
            ["job-scout", "--unknown"],
            ["job-scout", "--scheduled", "extra"],
            ["job-scout", "--scheduled", "--force"]
        ] {
            XCTAssertThrowsError(try WorkerCommand(arguments: arguments)) { error in
                XCTAssertEqual(error as? WorkerCommand.Error, .invalidArguments)
            }
        }
    }
}
