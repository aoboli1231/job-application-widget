import XCTest
@testable import JobApplicationWidget

final class JobDatabaseTests: XCTestCase {
    func testFullyPopulatedJobRoundTrips() throws {
        let db = try TestDatabase.open()
        var job = Job(company: "Company", role: "Role", location: "Melbourne")
        job.priority = 2
        job.workType = "Hybrid"
        job.isFullTime = false
        job.status = .interview
        job.notes = "Local note"
        job.appliedAt = Date(timeIntervalSince1970: 1)
        job.publishedAt = Date(timeIntervalSince1970: 2)
        job.deadline = Date(timeIntervalSince1970: 3)
        job.matchScore = 77
        job.matchReason = "Strong fit"
        job.risk = .low
        job.eligibility = .eligible
        job.canonicalURL = URL(string: "https://example.com/job/1")
        job.platformJobID = "platform-1"
        job.updatedAt = Date(timeIntervalSince1970: 4)

        try db.upsert(job, preservingTracking: false)

        XCTAssertEqual(try db.jobs(), [job])
    }

    func testNullableJobRoundTrips() throws {
        let db = try TestDatabase.open()
        var job = Job(company: "Company", role: "Role", location: "Remote")
        job.updatedAt = Date(timeIntervalSince1970: 1)
        try db.upsert(job, preservingTracking: false)
        XCTAssertEqual(try db.jobs(), [job])
    }

    func testRollbackRemovesJobAndMetadataButKeepsCommittedRows() throws {
        let db = try TestDatabase.open()
        let committed = Job(company: "Existing", role: "Role", location: "Melbourne")
        try db.upsert(committed, preservingTracking: false)

        XCTAssertThrowsError(try db.withTransaction {
            try db.upsert(Job(company: "New", role: "Role", location: "Remote"), preservingTracking: false)
            try db.setMetadata("value", forKey: "key")
            throw TestError.expected
        })

        let saved = try db.jobs()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.id, committed.id)
        XCTAssertEqual(saved.first?.company, committed.company)
        XCTAssertNil(try db.metadata(forKey: "key"))
    }

    func testReaderSeesOnlyCommittedWALSnapshot() throws {
        let pair = try TestDatabase.openPair()
        XCTAssertEqual(try pair.writer.journalMode().lowercased(), "wal")
        try pair.writer.withTransaction {
            try pair.writer.upsert(Job(company: "A", role: "B", location: "C"), preservingTracking: true)
            XCTAssertTrue(try pair.reader.jobs().isEmpty)
        }
        XCTAssertEqual(try pair.reader.jobs().count, 1)
    }

    func testReadOnlyConnectionCannotCreateOrMigrate() {
        let url = TestDatabase.uniqueURL()
        XCTAssertThrowsError(try JobDatabase(url: url, mode: .readOnly))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testReadOnlyConnectionReadsButCannotWrite() throws {
        let url = TestDatabase.uniqueURL()
        let writer = try JobDatabase(url: url, mode: .readWrite)
        let job = Job(company: "Company", role: "Role", location: "Melbourne")
        try writer.upsert(job, preservingTracking: false)

        let reader = try JobDatabase(url: url, mode: .readOnly)
        XCTAssertEqual(try reader.jobs().first?.id, job.id)
        XCTAssertThrowsError(try reader.upsert(Job(company: "Other", role: "Role", location: "Remote"), preservingTracking: false))
        XCTAssertEqual(try reader.jobs().count, 1)
    }

    func testWritesInsideExplicitTransactionDoNotNestTransactions() throws {
        let db = try TestDatabase.open()
        try db.withTransaction {
            try db.upsert(Job(company: "A", role: "B", location: "C"), preservingTracking: true)
            try db.setMetadata("value", forKey: "key")
        }
        XCTAssertEqual(try db.metadata(forKey: "key"), "value")
    }

    func testInvalidScoreRollsBackAndDatabaseReopens() throws {
        let url = TestDatabase.uniqueURL()
        let db = try JobDatabase(url: url, mode: .readWrite)
        var job = Job(company: "A", role: "B", location: "C")
        job.matchScore = 101
        XCTAssertThrowsError(try db.upsert(job, preservingTracking: true))
        XCTAssertTrue(try JobDatabase(url: url, mode: .readWrite).jobs().isEmpty)
    }

    func testPreservingTrackingStillUpdatesSourceDates() throws {
        let db = try TestDatabase.open()
        var local = Job(company: "Company", role: "Role", location: "Melbourne")
        local.status = .applied
        local.notes = "Keep me"
        local.appliedAt = Date(timeIntervalSince1970: 1)
        try db.upsert(local, preservingTracking: false)

        var incoming = local
        incoming.status = .new
        incoming.notes = "Replace me"
        incoming.appliedAt = nil
        incoming.publishedAt = Date(timeIntervalSince1970: 2)
        incoming.deadline = Date(timeIntervalSince1970: 3)
        try db.upsert(incoming, preservingTracking: true)

        let saved = try XCTUnwrap(try db.jobs().first)
        XCTAssertEqual(saved.status, .applied)
        XCTAssertEqual(saved.notes, "Keep me")
        XCTAssertEqual(saved.appliedAt, local.appliedAt)
        XCTAssertEqual(saved.publishedAt, incoming.publishedAt)
        XCTAssertEqual(saved.deadline, incoming.deadline)
    }

    func testNonAppliedStatusDoesNotInventAppliedDate() throws {
        let db = try TestDatabase.open()
        let job = Job(company: "Company", role: "Role", location: "Melbourne")
        try db.upsert(job, preservingTracking: false)
        try db.setStatus(id: job.id, status: .review)
        XCTAssertNil(try db.jobs().first?.appliedAt)
    }

    func testCorruptUUIDThrowsInsteadOfCrashing() throws {
        let url = TestDatabase.uniqueURL()
        let db = try JobDatabase(url: url, mode: .readWrite)
        try TestDatabase.executeRaw(at: url, Self.corruptRowSQL(id: "not-a-uuid", status: "new"))
        XCTAssertThrowsError(try db.jobs())
    }

    func testCorruptEnumThrowsInsteadOfCrashing() throws {
        let url = TestDatabase.uniqueURL()
        let db = try JobDatabase(url: url, mode: .readWrite)
        try TestDatabase.executeRaw(at: url, Self.corruptRowSQL(id: UUID().uuidString, status: "invented"))
        XCTAssertThrowsError(try db.jobs())
    }

    func testMetadataSchemaErrorIsNotReportedAsMissingKey() throws {
        let url = TestDatabase.uniqueURL()
        let db = try JobDatabase(url: url, mode: .readWrite)
        try TestDatabase.executeRaw(at: url, "DROP TABLE metadata")
        XCTAssertThrowsError(try db.metadata(forKey: "key"))
    }

    func testFutureSchemaVersionIsRejected() throws {
        let url = TestDatabase.uniqueURL()
        try TestDatabase.executeRaw(
            at: url,
            "CREATE TABLE schema_version(version INTEGER NOT NULL); INSERT INTO schema_version VALUES(3);"
        )
        XCTAssertThrowsError(try JobDatabase(url: url, mode: .readWrite))
    }

    private static func corruptRowSQL(id: String, status: String) -> String {
        """
        INSERT INTO jobs VALUES (
          '\(id)', 'Company', 'Role', 'Melbourne', 1, NULL, NULL,
          '\(status)', '', NULL, NULL, NULL, NULL, '',
          'needsReview', 'unclear', NULL, NULL, 1
        )
        """
    }
}

enum TestError: Error { case expected }
