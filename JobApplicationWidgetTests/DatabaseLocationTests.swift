import XCTest
@testable import JobApplicationWidget

final class DatabaseLocationTests: XCTestCase {
    func testMissingAppGroupThrows() {
        XCTAssertThrowsError(try DatabaseLocation(appGroupID: "invalid.group", containerURLProvider: { nil }).databaseURL())
    }

    func testDatabaseURLUsesOnlyInjectedContainer() throws {
        let root = URL(fileURLWithPath: "/tmp/app-group")
        XCTAssertEqual(try DatabaseLocation(appGroupID: "group.test", containerURLProvider: { root }).databaseURL(), root.appendingPathComponent("Library/Application Support/JobApplicationCopilot/jobs.sqlite3"))
    }
}
