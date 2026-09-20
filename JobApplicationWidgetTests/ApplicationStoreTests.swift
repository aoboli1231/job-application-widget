import XCTest
@testable import JobApplicationWidget

@MainActor
final class ApplicationStoreTests: XCTestCase {
    func testSettingAppliedPersistsAndReloads() throws {
        let database = try TestDatabase.open()
        let job = Job(company: "Westpac", role: "Analyst", location: "Melbourne")
        try database.upsert(job, preservingTracking: false)
        let store = try ApplicationStore(database: database)

        store.setStatus(.applied, for: job.id)

        let reloaded = try ApplicationStore(database: database)
        XCTAssertEqual(reloaded.jobs.first?.status, .applied)
        XCTAssertNotNil(reloaded.jobs.first?.appliedAt)
        XCTAssertNil(store.errorMessage)
    }

    func testDatabaseFailureIsExposedToUI() {
        let store = ApplicationStore(failingWith: TestError.expected)

        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(store.jobs.isEmpty)
    }

    func testReloadReadsExternalDatabaseChanges() throws {
        let database = try TestDatabase.open()
        let store = try ApplicationStore(database: database)
        let job = Job(company: "Company", role: "Role", location: "Remote")
        try database.upsert(job, preservingTracking: false)

        store.reload()

        XCTAssertEqual(store.jobs.map(\.id), [job.id])
    }

    func testAddPersistsValidJob() throws {
        let database = try TestDatabase.open()
        let store = try ApplicationStore(database: database)
        var job = Job(company: "Company", role: "Role", location: "Remote")
        job.canonicalURL = URL(string: "https://example.com/jobs/1")

        store.add(job)

        let reloaded = try ApplicationStore(database: database)
        let saved = try XCTUnwrap(reloaded.jobs.first)
        XCTAssertEqual(reloaded.jobs.count, 1)
        XCTAssertEqual(saved.id, job.id)
        XCTAssertEqual(saved.company, job.company)
        XCTAssertEqual(saved.canonicalURL, job.canonicalURL)
        XCTAssertNil(store.errorMessage)
    }

    func testAddRejectsInvalidURLWithoutPoisoningDatabase() throws {
        let database = try TestDatabase.open()
        let existing = Job(company: "Existing", role: "Role", location: "Melbourne")
        try database.upsert(existing, preservingTracking: false)
        let store = try ApplicationStore(database: database)
        var invalid = Job(company: "Invalid", role: "Role", location: "Remote")
        invalid.canonicalURL = URL(string: "abc")

        store.add(invalid)

        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.jobs.map(\.id), [existing.id])
        XCTAssertEqual(try ApplicationStore(database: database).jobs.map(\.id), [existing.id])
    }
}
