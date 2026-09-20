import XCTest
@testable import JobApplicationWidget

final class RunDatabaseTests: XCTestCase {
    func testMelbourneScheduleUsesEightAMAcrossDSTBoundaries() throws {
        let schedule = MelbourneSchedule()
        let dstEndBefore = try date("2026-04-04T21:59:00Z")
        let dstEndAtEight = try date("2026-04-04T22:00:00Z")
        let dstStartBefore = try date("2026-10-03T20:59:00Z")
        let dstStartAtEight = try date("2026-10-03T21:00:00Z")

        XCTAssertEqual(schedule.localDay(at: dstEndAtEight), "2026-04-05")
        XCTAssertFalse(schedule.isDue(at: dstEndBefore))
        XCTAssertTrue(schedule.isDue(at: dstEndAtEight))
        XCTAssertEqual(schedule.localDay(at: dstStartAtEight), "2026-10-04")
        XCTAssertFalse(schedule.isDue(at: dstStartBefore))
        XCTAssertTrue(schedule.isDue(at: dstStartAtEight))
    }

    func testNewDatabaseStartsAtVersionTwo() throws {
        let url = TestDatabase.uniqueURL()
        let database = try JobDatabase(url: url)

        XCTAssertEqual(try database.schemaVersion(), 2)
        XCTAssertTrue(try TestDatabase.tableExists(at: url, named: "runs"))
    }

    func testVersionOneDatabaseUpgradesWithoutChangingJobs() throws {
        let fixture = try TestDatabase.versionOneWithJob()

        let database = try JobDatabase(url: fixture.url)

        XCTAssertEqual(try database.schemaVersion(), 2)
        XCTAssertEqual(try database.jobs(), [fixture.job])
        XCTAssertTrue(try TestDatabase.tableExists(at: fixture.url, named: "runs"))
    }

    func testFailedUpgradeRollsBackVersionAndRunsTable() throws {
        let fixture = try TestDatabase.versionOneWithJob()
        try TestDatabase.executeRaw(
            at: fixture.url,
            "CREATE INDEX runs_local_day_status ON jobs(company)"
        )

        XCTAssertThrowsError(try JobDatabase(url: fixture.url))
        XCTAssertEqual(try TestDatabase.rawSchemaVersions(at: fixture.url), [1])
        XCTAssertFalse(try TestDatabase.tableExists(at: fixture.url, named: "runs"))
    }

    func testReadOnlyVersionOneDatabaseIsNotMigrated() throws {
        let fixture = try TestDatabase.versionOneWithJob()

        let database = try JobDatabase(url: fixture.url, mode: .readOnly)

        XCTAssertEqual(try database.schemaVersion(), 1)
        XCTAssertFalse(try TestDatabase.tableExists(at: fixture.url, named: "runs"))
    }

    func testCheckpointRoundTripsAndInitialStatusWaitsForNetwork() throws {
        let database = try TestDatabase.open()
        let started = Date(timeIntervalSince1970: 100)
        let checkpointed = Date(timeIntervalSince1970: 200)
        let payload = try JSONEncoder().encode(["cursor": "mail-42"])
        let id = try database.createRun(
            trigger: .scheduled,
            localDay: "2026-09-20",
            at: started
        )

        try database.saveCheckpoint(
            runID: id,
            stage: "outlook",
            payload: payload,
            at: checkpointed
        )

        let run = try XCTUnwrap(database.latestResumableRun(localDay: "2026-09-20"))
        XCTAssertEqual(run.id, id)
        XCTAssertEqual(run.trigger, .scheduled)
        XCTAssertEqual(run.status, .waitingForNetwork)
        XCTAssertEqual(run.checkpointStage, "outlook")
        XCTAssertEqual(run.checkpointPayload, payload)
        XCTAssertEqual(run.startedAt, started)
        XCTAssertEqual(run.updatedAt, checkpointed)
        XCTAssertNil(run.finishedAt)
        XCTAssertNil(run.error)
    }

    func testLatestResumableRunIsDeterministicAndExcludesTerminalRuns() throws {
        let database = try TestDatabase.open()
        let older = try database.createRun(
            trigger: .scheduled,
            localDay: "2026-09-20",
            at: Date(timeIntervalSince1970: 1)
        )
        try database.setRunStatus(
            id: older,
            status: .suspended,
            at: Date(timeIntervalSince1970: 2)
        )
        let newer = try database.createRun(
            trigger: .manual,
            localDay: "2026-09-20",
            at: Date(timeIntervalSince1970: 3)
        )
        try database.setRunStatus(
            id: newer,
            status: .running,
            at: Date(timeIntervalSince1970: 4)
        )

        XCTAssertEqual(try database.latestResumableRun(localDay: "2026-09-20")?.id, newer)
        try database.finishRun(
            id: newer,
            status: .failed,
            error: "offline",
            at: Date(timeIntervalSince1970: 5)
        )
        XCTAssertEqual(try database.latestResumableRun(localDay: "2026-09-20")?.id, older)
        try database.finishRun(
            id: older,
            status: .succeeded,
            error: nil,
            at: Date(timeIntervalSince1970: 6)
        )
        XCTAssertNil(try database.latestResumableRun(localDay: "2026-09-20"))
    }

    func testOnlySucceededRunSatisfiesDailyGate() throws {
        let database = try TestDatabase.open()
        let failed = try database.createRun(
            trigger: .scheduled,
            localDay: "2026-09-20",
            at: Date(timeIntervalSince1970: 1)
        )
        try database.finishRun(
            id: failed,
            status: .failed,
            error: "expected",
            at: Date(timeIntervalSince1970: 2)
        )
        _ = try database.createRun(
            trigger: .scheduled,
            localDay: "2026-09-20",
            at: Date(timeIntervalSince1970: 3)
        )
        XCTAssertFalse(try database.hasSuccessfulRun(localDay: "2026-09-20"))

        let succeeded = try database.createRun(
            trigger: .manual,
            localDay: "2026-09-20",
            at: Date(timeIntervalSince1970: 4)
        )
        try database.finishRun(
            id: succeeded,
            status: .succeeded,
            error: nil,
            at: Date(timeIntervalSince1970: 5)
        )
        XCTAssertTrue(try database.hasSuccessfulRun(localDay: "2026-09-20"))
    }

    func testInvalidCheckpointAndMissingRunUpdatesThrow() throws {
        let database = try TestDatabase.open()
        let missing = UUID()

        XCTAssertThrowsError(try database.saveCheckpoint(
            runID: missing,
            stage: "source",
            payload: Data("not json".utf8),
            at: Date()
        ))
        let validPayload = try JSONEncoder().encode(["cursor": "one"])
        XCTAssertThrowsError(try database.saveCheckpoint(
            runID: missing,
            stage: "source",
            payload: validPayload,
            at: Date()
        ))
        XCTAssertThrowsError(try database.setRunStatus(id: missing, status: .running, at: Date()))
        XCTAssertThrowsError(try database.finishRun(id: missing, status: .failed, error: nil, at: Date()))
    }

    func testTerminalAndNonterminalStatusAPIsAreSeparated() throws {
        let database = try TestDatabase.open()
        let id = try database.createRun(trigger: .manual, localDay: "2026-09-20", at: Date())

        XCTAssertThrowsError(try database.setRunStatus(id: id, status: .succeeded, at: Date()))
        XCTAssertThrowsError(try database.finishRun(id: id, status: .suspended, error: nil, at: Date()))
    }

    func testInvalidLocalDayIsRejected() throws {
        let database = try TestDatabase.open()
        XCTAssertThrowsError(try database.createRun(
            trigger: .scheduled,
            localDay: "2026-02-30",
            at: Date()
        ))
    }

    func testCorruptRunFieldsThrowDuringTypedDecode() throws {
        let validID = UUID().uuidString
        let rows = [
            ("UUID", "2026-09-20", "'not-a-uuid', 'scheduled', '2026-09-20', 'running', NULL, NULL, 1, NULL, NULL, 2"),
            ("trigger", "2026-09-20", "'\(validID)', 'invented', '2026-09-20', 'running', NULL, NULL, 1, NULL, NULL, 2"),
            ("status", "2026-09-20", "'\(validID)', 'scheduled', '2026-09-20', 'invented', NULL, NULL, 1, NULL, NULL, 2"),
            ("local day", "2026-02-30", "'\(validID)', 'scheduled', '2026-02-30', 'running', NULL, NULL, 1, NULL, NULL, 2"),
            ("JSON", "2026-09-20", "'\(validID)', 'scheduled', '2026-09-20', 'running', 'source', X'6E6F74206A736F6E', 1, NULL, NULL, 2"),
            ("date", "2026-09-20", "'\(validID)', 'scheduled', '2026-09-20', 'running', NULL, NULL, 'bad', NULL, NULL, 2")
        ]

        for (field, lookupDay, values) in rows {
            let url = TestDatabase.uniqueURL()
            let database = try JobDatabase(url: url)
            try TestDatabase.executeRaw(at: url, """
                PRAGMA ignore_check_constraints = ON;
                INSERT INTO runs VALUES (\(values));
                """)
            XCTAssertThrowsError(
                try database.latestResumableRun(localDay: lookupDay),
                "Corrupt \(field) should throw"
            )
        }
    }

    func testRunCheckConstraintsRejectInvalidEnums() throws {
        let url = TestDatabase.uniqueURL()
        _ = try JobDatabase(url: url)

        XCTAssertThrowsError(try TestDatabase.executeRaw(at: url, """
            INSERT INTO runs VALUES (
              '\(UUID().uuidString)', 'invented', '2026-09-20', 'running',
              NULL, NULL, 1, NULL, NULL, 1
            )
            """))
    }

    func testSchemaVersionRejectsDuplicateRows() throws {
        let url = TestDatabase.uniqueURL()
        let database = try JobDatabase(url: url)
        try TestDatabase.executeRaw(at: url, "INSERT INTO schema_version(version) VALUES(2)")

        XCTAssertThrowsError(try database.schemaVersion())
    }

    func testSuccessfulRunQueryDoesNotSwallowSchemaErrors() throws {
        let url = TestDatabase.uniqueURL()
        let database = try JobDatabase(url: url)
        try TestDatabase.executeRaw(at: url, "DROP TABLE runs")

        XCTAssertThrowsError(try database.hasSuccessfulRun(localDay: "2026-09-20"))
    }

    private func date(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value))
    }
}
