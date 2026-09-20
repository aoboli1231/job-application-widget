import XCTest
@testable import JobApplicationWidget

final class JobModelTests: XCTestCase {
    func testJobRoundTripsWithoutLosingTrackingFields() throws {
        var job = Job(company: "Westpac", role: "Data Analyst", location: "Melbourne")
        job.priority = 1; job.workType = "Hybrid"; job.isFullTime = true
        job.status = .applied; job.notes = "Applied through Workday"
        job.matchReason = "Strong fit"; job.appliedAt = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(try JSONDecoder().decode(Job.self, from: JSONEncoder().encode(job)), job)
    }
}
