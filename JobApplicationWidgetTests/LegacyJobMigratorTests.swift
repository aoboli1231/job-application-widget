import XCTest
@testable import JobApplicationWidget

final class LegacyJobMigratorTests: XCTestCase {
    private let marker = "legacy-v1-complete"

    func testMigrationPreservesAppliedWestpacAndAllNineJobs() throws {
        let database = try TestDatabase.open()
        var legacy = initialApplications
        let westpacIndex = try XCTUnwrap(legacy.firstIndex { $0.company == "Westpac" })
        legacy[westpacIndex].applied = true
        legacy[westpacIndex].status = "Applied"
        legacy[westpacIndex].notes = "Applied through Workday"

        let result = try LegacyJobMigrator().migrate(legacy: legacy, agent: [], into: database)
        let jobs = try database.jobs()
        let westpac = try XCTUnwrap(jobs.first { $0.company == "Westpac" })

        XCTAssertEqual(result.inserted, 9)
        XCTAssertEqual(jobs.count, 9)
        XCTAssertEqual(westpac.status, .applied)
        XCTAssertEqual(westpac.notes, "Applied through Workday")
        XCTAssertNil(westpac.appliedAt, "Legacy data contains no truthful application date")
        XCTAssertEqual(westpac.priority, 1)
        XCTAssertEqual(westpac.isFullTime, true)
        XCTAssertEqual(westpac.workType, "Full-time")
        XCTAssertEqual(westpac.matchScore, 86)
        XCTAssertFalse(westpac.matchReason.isEmpty)
        XCTAssertEqual(try database.metadata(forKey: marker), "1")
    }

    func testAgentRefreshCannotOverwriteLocalTracking() throws {
        let database = try TestDatabase.open()
        let url = try XCTUnwrap(URL(string: "https://example.com/job/1"))
        var local = Job(company: "Westpac", role: "Analyst", location: "Melbourne")
        local.status = .applied
        local.notes = "Keep local note"
        local.appliedAt = Date(timeIntervalSince1970: 100)
        local.canonicalURL = url
        try database.upsert(local, preservingTracking: false)

        var source = Job(company: "Westpac", role: "Updated analyst", location: "Melbourne")
        source.status = .new
        source.notes = "Agent note"
        source.canonicalURL = url
        _ = try LegacyJobMigrator().migrate(legacy: [], agentJobs: [source], into: database)

        let saved = try XCTUnwrap(try database.jobs().first)
        XCTAssertEqual(saved.role, "Updated analyst")
        XCTAssertEqual(saved.status, .applied)
        XCTAssertEqual(saved.notes, local.notes)
        XCTAssertEqual(saved.appliedAt, local.appliedAt)
    }

    func testAgentWithSameUUIDCannotOverwriteTrackingImportedInSameMigration() throws {
        let database = try TestDatabase.open()
        let id = UUID()
        let legacy = JobApplication(
            id: id,
            company: "Westpac",
            role: "Old role",
            location: "Melbourne",
            priority: 1,
            match: 80,
            fullTime: true,
            applied: true,
            status: "Applied",
            notes: "Keep legacy note"
        )
        let agent = JobApplication(
            id: id,
            company: "Westpac",
            role: "Updated role",
            location: "Melbourne",
            priority: 1,
            match: 90,
            fullTime: true,
            applied: false,
            status: "Not applied"
        )

        _ = try LegacyJobMigrator().migrate(legacy: [legacy], agent: [agent], into: database)

        let saved = try XCTUnwrap(try database.jobs().first)
        XCTAssertEqual(saved.role, "Updated role")
        XCTAssertEqual(saved.matchScore, 90)
        XCTAssertEqual(saved.status, .applied)
        XCTAssertEqual(saved.notes, "Keep legacy note")
    }

    func testDuplicateUUIDUsesLastWriteDeterministically() throws {
        let database = try TestDatabase.open()
        let id = UUID()
        let first = JobApplication(id: id, company: "First", role: "Role", location: "Here", priority: 1, match: 50, fullTime: true)
        let last = JobApplication(id: id, company: "Last", role: "Role", location: "There", priority: 2, match: 60, fullTime: false)

        let result = try LegacyJobMigrator().migrate(legacy: [first, last], agent: [], into: database)

        XCTAssertEqual(result.skippedDuplicates, 1)
        XCTAssertEqual(try database.jobs().count, 1)
        XCTAssertEqual(try database.jobs().first?.company, "Last")
        XCTAssertEqual(try database.jobs().first?.priority, 2)
    }

    func testPlatformIDMatchUpdatesOneExistingRow() throws {
        let database = try TestDatabase.open()
        var local = Job(company: "Old", role: "Role", location: "Here")
        local.platformJobID = "seek-123"
        try database.upsert(local, preservingTracking: false)
        var source = Job(company: "New", role: "Role", location: "Here")
        source.platformJobID = "seek-123"

        _ = try LegacyJobMigrator().migrate(legacy: [], agentJobs: [source], into: database)

        XCTAssertEqual(try database.jobs().count, 1)
        XCTAssertEqual(try database.jobs().first?.id, local.id)
        XCTAssertEqual(try database.jobs().first?.company, "New")
    }

    func testCanonicalURLMatchUpdatesOneExistingRow() throws {
        let database = try TestDatabase.open()
        let url = try XCTUnwrap(URL(string: "https://example.com/jobs/123"))
        var local = Job(company: "Old", role: "Role", location: "Here")
        local.canonicalURL = url
        try database.upsert(local, preservingTracking: false)
        var source = Job(company: "New", role: "Role", location: "Here")
        source.canonicalURL = url

        _ = try LegacyJobMigrator().migrate(legacy: [], agentJobs: [source], into: database)

        XCTAssertEqual(try database.jobs().count, 1)
        XCTAssertEqual(try database.jobs().first?.id, local.id)
        XCTAssertEqual(try database.jobs().first?.company, "New")
    }

    func testUUIDMatchUpdatesOneExistingRow() throws {
        let database = try TestDatabase.open()
        let id = UUID()
        let local = Job(id: id, company: "Old", role: "Role", location: "Here")
        try database.upsert(local, preservingTracking: false)
        let source = Job(id: id, company: "New", role: "Role", location: "Here")

        _ = try LegacyJobMigrator().migrate(legacy: [], agentJobs: [source], into: database)

        XCTAssertEqual(try database.jobs().count, 1)
        XCTAssertEqual(try database.jobs().first?.company, "New")
    }

    func testCrossKeyCollisionUsesOldestSurvivorAndKeepsTracking() throws {
        let database = try TestDatabase.open()
        let url = try XCTUnwrap(URL(string: "https://example.com/jobs/collision"))
        var platformRow = Job(company: "Platform", role: "Old", location: "Here")
        platformRow.platformJobID = "linkedin-42"
        platformRow.status = .review
        platformRow.notes = "Keep survivor note"
        platformRow.updatedAt = Date(timeIntervalSince1970: 1)
        var urlRow = Job(company: "URL", role: "Old", location: "Here")
        urlRow.canonicalURL = url
        urlRow.status = .applied
        urlRow.appliedAt = Date(timeIntervalSince1970: 2)
        urlRow.updatedAt = Date(timeIntervalSince1970: 3)
        try database.upsert(platformRow, preservingTracking: false)
        try database.upsert(urlRow, preservingTracking: false)

        var source = Job(company: "Fresh", role: "Updated", location: "Melbourne")
        source.platformJobID = "linkedin-42"
        source.canonicalURL = url
        _ = try LegacyJobMigrator().migrate(legacy: [], agentJobs: [source], into: database)

        let jobs = try database.jobs()
        let saved = try XCTUnwrap(jobs.first)
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(saved.id, platformRow.id)
        XCTAssertEqual(saved.company, "Fresh")
        XCTAssertEqual(saved.status, .applied)
        XCTAssertEqual(saved.notes, platformRow.notes)
        XCTAssertEqual(saved.appliedAt, urlRow.appliedAt)
        XCTAssertEqual(saved.platformJobID, source.platformJobID)
        XCTAssertEqual(saved.canonicalURL, source.canonicalURL)
    }

    func testEmptySourcesSeedNineJobsOnlyWhenDatabaseIsEmpty() throws {
        let suite = "LegacyJobMigratorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = try TestDatabase.open()

        let result = try LegacyJobMigrator().migrateIfNeeded(defaults: defaults, database: database)

        XCTAssertEqual(result.inserted, 9)
        XCTAssertEqual(try database.jobs().count, 9)
    }

    func testAgentRowsDoNotPreventSeedImportWhenDefaultsAndDatabaseAreEmpty() throws {
        let suite = "LegacyJobMigratorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let agent = Job(company: "Agent Company", role: "New role", location: "Remote")
        try JSONEncoder().encode([agent]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let database = try TestDatabase.open()

        let result = try LegacyJobMigrator().migrateIfNeeded(
            defaults: defaults,
            agentJSONURL: url,
            database: database
        )

        let jobs = try database.jobs()
        XCTAssertEqual(result.inserted, 10)
        XCTAssertEqual(jobs.count, 10)
        XCTAssertNotNil(jobs.first { $0.company == "Westpac" })
        XCTAssertNotNil(jobs.first { $0.id == agent.id })
    }

    func testEmptySourcesDoNotSeedNonemptyDatabase() throws {
        let suite = "LegacyJobMigratorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = try TestDatabase.open()
        let existing = Job(company: "Existing", role: "Role", location: "Here")
        try database.upsert(existing, preservingTracking: false)

        let result = try LegacyJobMigrator().migrateIfNeeded(defaults: defaults, database: database)

        XCTAssertEqual(result.inserted, 0)
        XCTAssertEqual(try database.jobs().map(\.id), [existing.id])
    }

    func testCorruptDefaultsThrowWithoutWritingMarker() throws {
        let suite = "LegacyJobMigratorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not json".utf8), forKey: "jobApplicationWidget.applications.v1")
        let database = try TestDatabase.open()

        XCTAssertThrowsError(try LegacyJobMigrator().migrateIfNeeded(defaults: defaults, database: database))
        XCTAssertTrue(try database.jobs().isEmpty)
        XCTAssertNil(try database.metadata(forKey: marker))
    }

    func testCorruptAgentFileThrowsWithoutWritingMarker() throws {
        let suite = "LegacyJobMigratorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not json".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let database = try TestDatabase.open()

        XCTAssertThrowsError(try LegacyJobMigrator().migrateIfNeeded(defaults: defaults, agentJSONURL: url, database: database))
        XCTAssertTrue(try database.jobs().isEmpty)
        XCTAssertNil(try database.metadata(forKey: marker))
    }

    func testFailedMigrationRollsBackRowsAndMarker() throws {
        let database = try TestDatabase.open()
        let valid = Job(company: "Valid", role: "Role", location: "Here")
        var invalid = Job(company: "Invalid", role: "Role", location: "Here")
        invalid.matchScore = 101

        XCTAssertThrowsError(try LegacyJobMigrator().migrate(legacy: [], agentJobs: [valid, invalid], into: database))
        XCTAssertTrue(try database.jobs().isEmpty)
        XCTAssertNil(try database.metadata(forKey: marker))
    }

    func testSecondMigrationReportsCompletedAndChangesNothing() throws {
        let database = try TestDatabase.open()
        let appliedAt = Date(timeIntervalSince1970: 123)
        var source = Job(company: "Company", role: "Role", location: "Here")
        source.status = .applied
        source.notes = "Original"
        source.appliedAt = appliedAt
        source.platformJobID = "id-1"
        let migrator = LegacyJobMigrator()
        _ = try migrator.migrate(legacy: [], agentJobs: [source], into: database)
        let before = try database.jobs()

        var replacement = source
        replacement.company = "Should not replace"
        let result = try migrator.migrate(legacy: [], agentJobs: [replacement], into: database)

        XCTAssertTrue(result.alreadyCompleted)
        XCTAssertEqual(result.inserted, 0)
        XCTAssertEqual(result.updated, 0)
        XCTAssertEqual(try database.jobs(), before)
    }
}
