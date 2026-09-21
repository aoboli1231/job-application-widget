import Darwin
import XCTest
@testable import JobApplicationWidget

final class JSONBackupWriterTests: XCTestCase {
    private let runID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    func testBackupContainsSortedISO8601EnvelopeAndCurrentJobs() throws {
        let fixture = try BackupFixture()
        try fixture.database.upsert(fixture.job(id: runID), preservingTracking: false)

        let url = try fixture.writer.writeSuccessfulBackup(database: fixture.database, runID: runID, at: date)

        XCTAssertEqual(
            url.lastPathComponent,
            "jobs-20260921T141320.000Z-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE.json"
        )
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(JobBackup.self, from: data)
        XCTAssertEqual(backup.schemaVersion, 1)
        XCTAssertEqual(backup.runID, runID)
        XCTAssertEqual(backup.createdAt, date)
        XCTAssertEqual(backup.jobs, try fixture.database.jobs())

        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertLessThan(try XCTUnwrap(text.range(of: #""createdAt""#)?.lowerBound),
                          try XCTUnwrap(text.range(of: #""jobs""#)?.lowerBound))
        XCTAssertLessThan(try XCTUnwrap(text.range(of: #""jobs""#)?.lowerBound),
                          try XCTUnwrap(text.range(of: #""runID""#)?.lowerBound))
    }

    func testCompletedBackupIsOwnerOnlyAndLeavesNoTemporaryFile() throws {
        let fixture = try BackupFixture()

        let url = try fixture.writer.writeSuccessfulBackup(database: fixture.database, runID: runID, at: date)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(try fixture.files().contains { $0.pathExtension == "tmp" })
    }

    func testThirtyFirstBackupDeletesOnlyOldestCompletedFile() throws {
        let fixture = try BackupFixture()
        var urls: [URL] = []
        for offset in 0..<31 {
            urls.append(try fixture.writer.writeSuccessfulBackup(
                database: fixture.database,
                runID: UUID(),
                at: date.addingTimeInterval(Double(offset))
            ))
        }

        let completed = try fixture.completedFiles()
        XCTAssertEqual(completed.count, 30)
        XCTAssertFalse(FileManager.default.fileExists(atPath: urls[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls[30].path))
    }

    func testEqualTimestampRetentionUsesCanonicalUUIDAsStableTieBreaker() throws {
        let fixture = try BackupFixture()
        let lower = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let higher = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let lowerURL = try fixture.writer.writeSuccessfulBackup(database: fixture.database, runID: lower, at: date)
        let higherURL = try fixture.writer.writeSuccessfulBackup(database: fixture.database, runID: higher, at: date)

        try fixture.writer.pruneKeepingNewest(1)

        XCTAssertFalse(FileManager.default.fileExists(atPath: lowerURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: higherURL.path))
    }

    func testPruneIgnoresMalformedTemporaryUnrelatedDirectoryAndSymlinkEntries() throws {
        let fixture = try BackupFixture()
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let unrelated = fixture.directory.appendingPathComponent("notes.json")
        try Data("keep".utf8).write(to: unrelated)
        let malformed = fixture.directory.appendingPathComponent(
            "jobs-20269999T999999.999Z-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE.json"
        )
        try Data("keep".utf8).write(to: malformed)
        let lowercase = fixture.directory.appendingPathComponent(
            "jobs-20200101T000000.000Z-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.json"
        )
        try Data("keep".utf8).write(to: lowercase)
        let temporary = fixture.directory.appendingPathComponent(".jobs-old.json.RANDOM.tmp")
        try Data("keep".utf8).write(to: temporary)
        let directory = fixture.directory.appendingPathComponent(
            "jobs-20190101T000000.000Z-11111111-1111-1111-1111-111111111111.json"
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let symlink = fixture.directory.appendingPathComponent(
            "jobs-20180101T000000.000Z-22222222-2222-2222-2222-222222222222.json"
        )
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: unrelated)

        for offset in 0..<31 {
            _ = try fixture.writer.writeSuccessfulBackup(
                database: fixture.database,
                runID: UUID(),
                at: date.addingTimeInterval(Double(offset))
            )
        }

        for url in [unrelated, malformed, lowercase, temporary, directory, symlink] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Removed \(url.lastPathComponent)")
        }
        XCTAssertEqual(try fixture.completedFiles().count, 30)
    }

    func testSameNameRetryAtomicallyReplacesCompletedBackup() throws {
        let fixture = try BackupFixture()
        try fixture.database.upsert(fixture.job(id: runID), preservingTracking: false)
        let url = try fixture.writer.writeSuccessfulBackup(database: fixture.database, runID: runID, at: date)
        let original = try Data(contentsOf: url)
        try fixture.database.upsert(fixture.job(id: UUID()), preservingTracking: false)

        let retriedURL = try fixture.writer.writeSuccessfulBackup(database: fixture.database, runID: runID, at: date)

        XCTAssertEqual(retriedURL, url)
        XCTAssertNotEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try fixture.decode(url).jobs.count, 2)
        XCTAssertFalse(try fixture.files().contains { $0.pathExtension == "tmp" })
    }

    func testEncodeAndAtomicCommitFailuresLeaveExistingBackupUntouched() throws {
        for failure in CommitFailure.allCases {
            let fixture = try BackupFixture()
            try fixture.database.upsert(fixture.job(id: runID), preservingTracking: false)
            let oldURL = try fixture.writer.writeSuccessfulBackup(database: fixture.database, runID: runID, at: date)
            let oldData = try Data(contentsOf: oldURL)
            try fixture.database.upsert(fixture.job(id: UUID()), preservingTracking: false)

            let writer = fixture.writer(failing: failure)
            XCTAssertThrowsError(try writer.writeSuccessfulBackup(
                database: fixture.database,
                runID: runID,
                at: date
            ), "Expected \(failure) failure")
            XCTAssertEqual(try Data(contentsOf: oldURL), oldData, "Changed old file for \(failure)")
            XCTAssertFalse(try fixture.files().contains { $0.pathExtension == "tmp" })
        }
    }

    func testPruneEnumerationFailurePropagatesAfterNewBackupIsDurable() throws {
        let fixture = try BackupFixture()
        var operations = BackupFileOperations.live(fileManager: .default)
        operations.contentsOfDirectory = { _ in throw BackupTestError.injected }
        let writer = JSONBackupWriter(directoryURL: fixture.directory, operations: operations)

        XCTAssertThrowsError(try writer.writeSuccessfulBackup(database: fixture.database, runID: runID, at: date))

        XCTAssertEqual(try fixture.completedFiles().count, 1)
        XCTAssertFalse(try fixture.files().contains { $0.pathExtension == "tmp" })
    }

    func testPruneDeleteFailureStopsAndKeepsNewDurableBackup() throws {
        let fixture = try BackupFixture()
        for offset in 0..<30 {
            _ = try fixture.writer.writeSuccessfulBackup(
                database: fixture.database,
                runID: UUID(),
                at: date.addingTimeInterval(Double(offset))
            )
        }
        var operations = BackupFileOperations.live(fileManager: .default)
        let liveRemove = operations.remove
        operations.remove = { url in
            if url.pathExtension == "json" { throw BackupTestError.injected }
            try liveRemove(url)
        }
        let writer = JSONBackupWriter(directoryURL: fixture.directory, operations: operations)
        let newestDate = date.addingTimeInterval(31)

        XCTAssertThrowsError(try writer.writeSuccessfulBackup(
            database: fixture.database,
            runID: runID,
            at: newestDate
        ))

        XCTAssertEqual(try fixture.completedFiles().count, 31)
        XCTAssertTrue(try fixture.completedFiles().contains {
            $0.lastPathComponent.contains("20260921T141351.000Z-AAAAAAAA")
        })
    }

    func testNegativeRetentionLimitIsRejectedWithoutDeletingFiles() throws {
        let fixture = try BackupFixture()
        let existing = fixture.directory.appendingPathComponent("notes.json")
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: existing)

        XCTAssertThrowsError(try fixture.writer.pruneKeepingNewest(-1)) { error in
            XCTAssertEqual(error as? JSONBackupWriter.Error, .invalidRetentionLimit(-1))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: existing.path))
    }
}

private enum CommitFailure: String, CaseIterable {
    case encode, open, write, synchronize, close, rename
}

private enum BackupTestError: Swift.Error { case injected }

private final class BackupFixture {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let database: JobApplicationWidget.JobDatabase
    var writer: JSONBackupWriter { JSONBackupWriter(directoryURL: directory) }

    init() throws {
        database = try JobApplicationWidget.JobDatabase(url: TestDatabase.uniqueURL())
    }

    func job(id: UUID) -> JobApplicationWidget.Job {
        JobApplicationWidget.Job(
            id: id,
            company: "Example",
            role: "Analyst",
            location: "Melbourne",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
    }

    func files() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }

    func completedFiles() throws -> [URL] {
        try files().filter { $0.lastPathComponent.hasPrefix("jobs-") && $0.pathExtension == "json" }
            .filter {
                let values = try $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                return values.isRegularFile == true && values.isSymbolicLink != true
                    && !$0.lastPathComponent.contains("999999")
                    && !$0.lastPathComponent.contains("aaaaaaaa")
            }
    }

    func decode(_ url: URL) throws -> JobBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(JobBackup.self, from: Data(contentsOf: url))
    }

    func writer(failing failure: CommitFailure) -> JSONBackupWriter {
        var operations = BackupFileOperations.live(fileManager: .default)
        let liveClose = operations.close
        let encode: ((JobBackup) throws -> Data)?
        switch failure {
        case .encode:
            encode = { _ in throw BackupTestError.injected }
        case .open:
            encode = nil
            operations.openExclusive = { _ in throw BackupTestError.injected }
        case .write:
            encode = nil
            operations.write = { _, _ in throw BackupTestError.injected }
        case .synchronize:
            encode = nil
            operations.synchronize = { _ in throw BackupTestError.injected }
        case .close:
            encode = nil
            operations.close = { descriptor in
                try liveClose(descriptor)
                throw BackupTestError.injected
            }
        case .rename:
            encode = nil
            operations.rename = { _, _ in throw BackupTestError.injected }
        }
        return JSONBackupWriter(
            directoryURL: directory,
            operations: operations,
            encode: encode,
            temporaryID: { UUID(uuidString: "99999999-9999-9999-9999-999999999999")! }
        )
    }
}
