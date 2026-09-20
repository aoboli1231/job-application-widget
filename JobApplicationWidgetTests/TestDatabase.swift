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
}
