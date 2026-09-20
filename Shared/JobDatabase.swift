import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class JobDatabase {
    enum ConnectionMode { case readWrite, readOnly }
    enum Error: Swift.Error, Equatable { case sqlite(String), invalidData(String) }

    private var db: OpaquePointer?
    private var inTransaction = false

    init(url: URL, mode: ConnectionMode = .readWrite) throws {
        if mode == .readWrite {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }

        var handle: OpaquePointer?
        let flags = mode == .readWrite
            ? SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            let message = Self.message(handle)
            sqlite3_close(handle)
            throw Error.sqlite(message)
        }
        db = handle

        do {
            if mode == .readWrite {
                try execute("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;")
                try migrate()
            }
        } catch {
            sqlite3_close(handle)
            db = nil
            throw error
        }
    }

    deinit { sqlite3_close(db) }

    func migrate() throws {
        try withTransaction {
            try execute("""
                CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS jobs (
                  id TEXT PRIMARY KEY,
                  company TEXT NOT NULL,
                  role TEXT NOT NULL,
                  location TEXT NOT NULL,
                  priority INTEGER NOT NULL,
                  work_type TEXT,
                  is_full_time INTEGER,
                  status TEXT NOT NULL,
                  notes TEXT NOT NULL,
                  applied_at REAL,
                  published_at REAL,
                  deadline REAL,
                  match_score INTEGER CHECK(match_score BETWEEN 0 AND 100),
                  match_reason TEXT NOT NULL,
                  risk TEXT NOT NULL,
                  eligibility TEXT NOT NULL,
                  canonical_url TEXT,
                  platform_job_id TEXT,
                  updated_at REAL NOT NULL
                );
                CREATE UNIQUE INDEX IF NOT EXISTS jobs_platform_id
                  ON jobs(platform_job_id) WHERE platform_job_id IS NOT NULL;
                CREATE UNIQUE INDEX IF NOT EXISTS jobs_canonical_url
                  ON jobs(canonical_url) WHERE canonical_url IS NOT NULL;
                INSERT INTO schema_version(version)
                  SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM schema_version);
                """)
            let versions = try schemaVersions()
            guard versions == [1] else {
                throw Error.invalidData("Unsupported schema versions: \(versions)")
            }
        }
    }

    func withTransaction<T>(_ body: () throws -> T) throws -> T {
        let ownsTransaction = !inTransaction
        if ownsTransaction {
            try execute("BEGIN IMMEDIATE;")
            inTransaction = true
        }
        do {
            let result = try body()
            if ownsTransaction {
                try execute("COMMIT;")
                inTransaction = false
            }
            return result
        } catch {
            if ownsTransaction {
                _ = try? execute("ROLLBACK;")
                inTransaction = false
            }
            throw error
        }
    }

    func upsert(_ job: Job, preservingTracking: Bool) throws {
        try write { try bindAndUpsert(job, preservingTracking: preservingTracking) }
    }

    func delete(id: UUID) throws {
        try write {
            let statement = try prepare("DELETE FROM jobs WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            try bind(id.uuidString, to: statement, at: 1)
            try stepToDone(statement)
        }
    }

    func setStatus(id: UUID, status: JobStatus, at: Date = Date()) throws {
        try write {
            let statement = try prepare("""
                UPDATE jobs
                SET status = ?,
                    applied_at = CASE WHEN ? = 'applied' THEN ? ELSE applied_at END,
                    updated_at = ?
                WHERE id = ?
                """)
            defer { sqlite3_finalize(statement) }
            try bind(status.rawValue, to: statement, at: 1)
            try bind(status.rawValue, to: statement, at: 2)
            try bind(at.timeIntervalSince1970, to: statement, at: 3)
            try bind(at.timeIntervalSince1970, to: statement, at: 4)
            try bind(id.uuidString, to: statement, at: 5)
            try stepToDone(statement)
        }
    }

    func setMetadata(_ value: String, forKey key: String) throws {
        try write {
            let statement = try prepare("""
                INSERT INTO metadata(key, value) VALUES(?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """)
            defer { sqlite3_finalize(statement) }
            try bind(key, to: statement, at: 1)
            try bind(value, to: statement, at: 2)
            try stepToDone(statement)
        }
    }

    func metadata(forKey key: String) throws -> String? {
        let statement = try prepare("SELECT value FROM metadata WHERE key = ?")
        defer { sqlite3_finalize(statement) }
        try bind(key, to: statement, at: 1)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return try requiredText(statement, 0, "metadata.value")
        case SQLITE_DONE:
            return nil
        default:
            throw Error.sqlite(Self.message(db))
        }
    }

    func journalMode() throws -> String {
        let statement = try prepare("PRAGMA journal_mode")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw Error.sqlite(Self.message(db))
        }
        return try requiredText(statement, 0, "journal_mode")
    }

    func jobs() throws -> [Job] {
        let statement = try prepare("""
            SELECT id, company, role, location, priority, work_type, is_full_time,
                   status, notes, applied_at, published_at, deadline, match_score,
                   match_reason, risk, eligibility, canonical_url, platform_job_id,
                   updated_at
            FROM jobs ORDER BY priority, id
            """)
        defer { sqlite3_finalize(statement) }

        var result = [Job]()
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                result.append(try decode(statement))
            case SQLITE_DONE:
                return result
            default:
                throw Error.sqlite(Self.message(db))
            }
        }
    }

    func summary(limit: Int) throws -> WidgetSummary {
        let all = try jobs()
        let inactive: [JobStatus] = [.applied, .rejected, .archived]
        return WidgetSummary(
            openCount: all.filter { !inactive.contains($0.status) }.count,
            topJobs: Array(all.prefix(max(0, limit))),
            refreshedAt: Date()
        )
    }

    private func write(_ body: () throws -> Void) throws {
        if inTransaction { try body() } else { try withTransaction(body) }
    }

    private func bindAndUpsert(_ job: Job, preservingTracking: Bool) throws {
        if let url = job.canonicalURL {
            guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
                throw Error.invalidData("Invalid jobs.canonical_url: \(url.absoluteString)")
            }
        }
        let trackingUpdate = preservingTracking ? "" : """
            status = excluded.status,
            notes = excluded.notes,
            applied_at = excluded.applied_at,
            """
        let statement = try prepare("""
            INSERT INTO jobs VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              company = excluded.company,
              role = excluded.role,
              location = excluded.location,
              priority = excluded.priority,
              work_type = excluded.work_type,
              is_full_time = excluded.is_full_time,
              \(trackingUpdate)
              published_at = excluded.published_at,
              deadline = excluded.deadline,
              match_score = excluded.match_score,
              match_reason = excluded.match_reason,
              risk = excluded.risk,
              eligibility = excluded.eligibility,
              canonical_url = excluded.canonical_url,
              platform_job_id = excluded.platform_job_id,
              updated_at = excluded.updated_at
            """)
        defer { sqlite3_finalize(statement) }

        let values: [Any?] = [
            job.id.uuidString, job.company, job.role, job.location, job.priority,
            job.workType, job.isFullTime.map { $0 ? 1 : 0 }, job.status.rawValue,
            job.notes, job.appliedAt?.timeIntervalSince1970,
            job.publishedAt?.timeIntervalSince1970, job.deadline?.timeIntervalSince1970,
            job.matchScore, job.matchReason, job.risk.rawValue,
            job.eligibility.rawValue, job.canonicalURL?.absoluteString,
            job.platformJobID, job.updatedAt.timeIntervalSince1970
        ]
        for (offset, value) in values.enumerated() {
            try bind(value, to: statement, at: Int32(offset + 1))
        }
        try stepToDone(statement)
    }

    private func decode(_ statement: OpaquePointer) throws -> Job {
        let idText = try requiredText(statement, 0, "jobs.id")
        guard let id = UUID(uuidString: idText) else {
            throw Error.invalidData("Invalid jobs.id: \(idText)")
        }
        let statusText = try requiredText(statement, 7, "jobs.status")
        let riskText = try requiredText(statement, 14, "jobs.risk")
        let eligibilityText = try requiredText(statement, 15, "jobs.eligibility")
        guard let status = JobStatus(rawValue: statusText) else {
            throw Error.invalidData("Invalid jobs.status: \(statusText)")
        }
        guard let risk = RiskLevel(rawValue: riskText) else {
            throw Error.invalidData("Invalid jobs.risk: \(riskText)")
        }
        guard let eligibility = Eligibility(rawValue: eligibilityText) else {
            throw Error.invalidData("Invalid jobs.eligibility: \(eligibilityText)")
        }

        var job = Job(
            id: id,
            company: try requiredText(statement, 1, "jobs.company"),
            role: try requiredText(statement, 2, "jobs.role"),
            location: try requiredText(statement, 3, "jobs.location")
        )
        job.priority = try requiredInt(statement, 4, "jobs.priority")
        job.workType = try optionalText(statement, 5, "jobs.work_type")
        if let fullTime = try optionalInt(statement, 6, "jobs.is_full_time") {
            guard fullTime == 0 || fullTime == 1 else {
                throw Error.invalidData("Invalid jobs.is_full_time: \(fullTime)")
            }
            job.isFullTime = fullTime == 1
        }
        job.status = status
        job.notes = try requiredText(statement, 8, "jobs.notes")
        job.appliedAt = try optionalDate(statement, 9, "jobs.applied_at")
        job.publishedAt = try optionalDate(statement, 10, "jobs.published_at")
        job.deadline = try optionalDate(statement, 11, "jobs.deadline")
        job.matchScore = try optionalInt(statement, 12, "jobs.match_score")
        job.matchReason = try requiredText(statement, 13, "jobs.match_reason")
        job.risk = risk
        job.eligibility = eligibility
        if let urlText = try optionalText(statement, 16, "jobs.canonical_url") {
            guard let url = URL(string: urlText),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme) else {
                throw Error.invalidData("Invalid jobs.canonical_url: \(urlText)")
            }
            job.canonicalURL = url
        }
        job.platformJobID = try optionalText(statement, 17, "jobs.platform_job_id")
        job.updatedAt = try requiredDate(statement, 18, "jobs.updated_at")
        return job
    }

    private func schemaVersions() throws -> [Int] {
        let statement = try prepare("SELECT version FROM schema_version ORDER BY version")
        defer { sqlite3_finalize(statement) }
        var versions = [Int]()
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                versions.append(try requiredInt(statement, 0, "schema_version.version"))
            case SQLITE_DONE:
                return versions
            default:
                throw Error.sqlite(Self.message(db))
            }
        }
    }

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? Self.message(db)
            sqlite3_free(error)
            throw Error.sqlite(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw Error.sqlite(Self.message(db))
        }
        return statement
    }

    private func stepToDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw Error.sqlite(Self.message(db))
        }
    }

    private func bind(_ value: Any?, to statement: OpaquePointer, at index: Int32) throws {
        let result: Int32
        switch value {
        case let value as String:
            result = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
        case let value as Int:
            result = sqlite3_bind_int64(statement, index, sqlite3_int64(value))
        case let value as Double:
            result = sqlite3_bind_double(statement, index, value)
        case nil:
            result = sqlite3_bind_null(statement, index)
        default:
            throw Error.invalidData("Unsupported bind value at parameter \(index)")
        }
        guard result == SQLITE_OK else {
            throw Error.sqlite("Bind parameter \(index): \(Self.message(db))")
        }
    }

    private func requiredText(_ statement: OpaquePointer, _ index: Int32, _ column: String) throws -> String {
        guard sqlite3_column_type(statement, index) == SQLITE_TEXT,
              let pointer = sqlite3_column_text(statement, index) else {
            throw Error.invalidData("Invalid or missing \(column)")
        }
        return String(cString: pointer)
    }

    private func optionalText(_ statement: OpaquePointer, _ index: Int32, _ column: String) throws -> String? {
        if sqlite3_column_type(statement, index) == SQLITE_NULL { return nil }
        return try requiredText(statement, index, column)
    }

    private func requiredInt(_ statement: OpaquePointer, _ index: Int32, _ column: String) throws -> Int {
        guard sqlite3_column_type(statement, index) == SQLITE_INTEGER else {
            throw Error.invalidData("Invalid or missing \(column)")
        }
        return Int(sqlite3_column_int64(statement, index))
    }

    private func optionalInt(_ statement: OpaquePointer, _ index: Int32, _ column: String) throws -> Int? {
        if sqlite3_column_type(statement, index) == SQLITE_NULL { return nil }
        return try requiredInt(statement, index, column)
    }

    private func requiredDate(_ statement: OpaquePointer, _ index: Int32, _ column: String) throws -> Date {
        guard let date = try optionalDate(statement, index, column) else {
            throw Error.invalidData("Missing \(column)")
        }
        return date
    }

    private func optionalDate(_ statement: OpaquePointer, _ index: Int32, _ column: String) throws -> Date? {
        let type = sqlite3_column_type(statement, index)
        if type == SQLITE_NULL { return nil }
        guard type == SQLITE_FLOAT || type == SQLITE_INTEGER else {
            throw Error.invalidData("Invalid \(column)")
        }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    }

    private static func message(_ db: OpaquePointer?) -> String {
        guard let db, let pointer = sqlite3_errmsg(db) else { return "SQLite error" }
        return String(cString: pointer)
    }
}
