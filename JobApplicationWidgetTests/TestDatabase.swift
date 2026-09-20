import Foundation
import SQLite3
@testable import JobApplicationWidget

enum TestDatabase {
    static func uniqueURL() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("sqlite3") }
    static func open() throws -> JobDatabase { try JobDatabase(url: uniqueURL(), mode: .readWrite) }
    static func openPair() throws -> (writer: JobDatabase, reader: JobDatabase) {
        let url = uniqueURL(); return (try JobDatabase(url: url, mode: .readWrite), try JobDatabase(url: url, mode: .readOnly))
    }

    static func executeRaw(at url: URL, _ sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            sqlite3_close(database)
            throw TestError.expected
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw TestError.expected
        }
    }

    static func versionOneWithJob() throws -> (url: URL, job: Job) {
        let url = uniqueURL()
        try executeRaw(at: url, versionOneSchema)
        var job = Job(
            id: UUID(),
            company: "Version One Company",
            role: "Analyst",
            location: "Melbourne"
        )
        job.priority = 3
        job.status = .applied
        job.notes = "Preserve me"
        job.appliedAt = Date(timeIntervalSince1970: 10)
        job.matchScore = 88
        job.matchReason = "Strong fit"
        job.updatedAt = Date(timeIntervalSince1970: 20)
        try executeRaw(at: url, """
            INSERT INTO jobs VALUES (
              '\(job.id.uuidString)', 'Version One Company', 'Analyst', 'Melbourne', 3,
              NULL, NULL, 'applied', 'Preserve me', 10, NULL, NULL, 88,
              'Strong fit', 'needsReview', 'unclear', NULL, NULL, 20
            )
            """)
        return (url, job)
    }

    static func rawSchemaVersions(at url: URL) throws -> [Int] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(database)
            throw TestError.expected
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT version FROM schema_version ORDER BY version", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw TestError.expected }
        defer { sqlite3_finalize(statement) }
        var versions = [Int]()
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                versions.append(Int(sqlite3_column_int64(statement, 0)))
            case SQLITE_DONE:
                return versions
            default:
                throw TestError.expected
            }
        }
    }

    static func tableExists(at url: URL, named name: String) throws -> Bool {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(database)
            throw TestError.expected
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else { throw TestError.expected }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(
            statement,
            1,
            name,
            -1,
            unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        ) == SQLITE_OK else { throw TestError.expected }
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw TestError.expected
        }
    }

    private static let versionOneSchema = """
        CREATE TABLE schema_version (version INTEGER NOT NULL);
        CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE jobs (
          id TEXT PRIMARY KEY, company TEXT NOT NULL, role TEXT NOT NULL,
          location TEXT NOT NULL, priority INTEGER NOT NULL, work_type TEXT,
          is_full_time INTEGER, status TEXT NOT NULL, notes TEXT NOT NULL,
          applied_at REAL, published_at REAL, deadline REAL,
          match_score INTEGER CHECK(match_score BETWEEN 0 AND 100),
          match_reason TEXT NOT NULL, risk TEXT NOT NULL, eligibility TEXT NOT NULL,
          canonical_url TEXT, platform_job_id TEXT, updated_at REAL NOT NULL
        );
        CREATE UNIQUE INDEX jobs_platform_id
          ON jobs(platform_job_id) WHERE platform_job_id IS NOT NULL;
        CREATE UNIQUE INDEX jobs_canonical_url
          ON jobs(canonical_url) WHERE canonical_url IS NOT NULL;
        INSERT INTO schema_version(version) VALUES(1);
        """
}
