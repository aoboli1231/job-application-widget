import Darwin
import Foundation

struct JobBackup: Codable, Equatable {
    let schemaVersion: Int
    let runID: UUID
    let createdAt: Date
    let jobs: [Job]
}

struct BackupFileOperations {
    var contentsOfDirectory: (URL) throws -> [URL]
    var isRegularFile: (URL) throws -> Bool
    var openExclusive: (URL) throws -> Int32
    var write: (Int32, Data) throws -> Void
    var synchronize: (Int32) throws -> Void
    var close: (Int32) throws -> Void
    var rename: (URL, URL) throws -> Void
    var remove: (URL) throws -> Void

    static func live(fileManager: FileManager) -> BackupFileOperations {
        BackupFileOperations(
            contentsOfDirectory: {
                try fileManager.contentsOfDirectory(
                    at: $0,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
            },
            isRegularFile: {
                let values = try $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                return values.isRegularFile == true && values.isSymbolicLink != true
            },
            openExclusive: { url in
                let descriptor = Darwin.open(url.path, O_CREAT | O_EXCL | O_WRONLY, S_IRUSR | S_IWUSR)
                guard descriptor >= 0 else { throw JSONBackupWriter.Error.systemCall("open", errno) }
                guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                    let code = errno
                    _ = Darwin.close(descriptor)
                    _ = Darwin.unlink(url.path)
                    throw JSONBackupWriter.Error.systemCall("fchmod", code)
                }
                return descriptor
            },
            write: { descriptor, data in
                try data.withUnsafeBytes { rawBuffer in
                    guard let baseAddress = rawBuffer.baseAddress else { return }
                    var written = 0
                    while written < rawBuffer.count {
                        let count = Darwin.write(
                            descriptor,
                            baseAddress.advanced(by: written),
                            rawBuffer.count - written
                        )
                        if count < 0, errno == EINTR { continue }
                        guard count > 0 else { throw JSONBackupWriter.Error.systemCall("write", errno) }
                        written += count
                    }
                }
            },
            synchronize: { descriptor in
                guard Darwin.fsync(descriptor) == 0 else {
                    throw JSONBackupWriter.Error.systemCall("fsync", errno)
                }
            },
            close: { descriptor in
                guard Darwin.close(descriptor) == 0 else {
                    throw JSONBackupWriter.Error.systemCall("close", errno)
                }
            },
            rename: { source, destination in
                guard Darwin.rename(source.path, destination.path) == 0 else {
                    throw JSONBackupWriter.Error.systemCall("rename", errno)
                }
            },
            remove: { try fileManager.removeItem(at: $0) }
        )
    }
}

final class JSONBackupWriter: SuccessfulRunBackupWriting {
    enum Error: Swift.Error, Equatable {
        case invalidRetentionLimit(Int)
        case couldNotCreateDirectory(String)
        case systemCall(String, Int32)
    }

    private static let retentionLimit = 30
    private static let filenameRegex = try! NSRegularExpression(
        pattern: #"^jobs-(\d{8}T\d{6}\.\d{3}Z)-([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})\.json$"#
    )

    let directoryURL: URL
    private let fileManager: FileManager
    private let operations: BackupFileOperations
    private let encode: (JobBackup) throws -> Data
    private let temporaryID: () -> UUID

    init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        operations: BackupFileOperations? = nil,
        encode: ((JobBackup) throws -> Data)? = nil,
        temporaryID: @escaping () -> UUID = UUID.init
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.operations = operations ?? .live(fileManager: fileManager)
        self.encode = encode ?? Self.encode
        self.temporaryID = temporaryID
    }

    func writeSuccessfulBackup(database: JobDatabase, runID: UUID, at date: Date) throws -> URL {
        let backup = JobBackup(
            schemaVersion: 1,
            runID: runID,
            createdAt: date,
            jobs: try database.jobs()
        )
        let data = try encode(backup)
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw Error.couldNotCreateDirectory(directoryURL.path)
        }

        let finalURL = directoryURL.appendingPathComponent(Self.filename(date: date, runID: runID))
        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(finalURL.lastPathComponent).\(temporaryID().uuidString).tmp"
        )
        let descriptor = try operations.openExclusive(temporaryURL)
        var descriptorIsOpen = true
        defer {
            if descriptorIsOpen { try? operations.close(descriptor) }
            try? operations.remove(temporaryURL)
        }

        try operations.write(descriptor, data)
        try operations.synchronize(descriptor)
        descriptorIsOpen = false
        try operations.close(descriptor)
        try operations.rename(temporaryURL, finalURL)
        try pruneKeepingNewest(Self.retentionLimit)
        return finalURL
    }

    func pruneKeepingNewest(_ limit: Int) throws {
        guard limit >= 0 else { throw Error.invalidRetentionLimit(limit) }
        let completed = try operations.contentsOfDirectory(directoryURL)
            .filter { try operations.isRegularFile($0) && Self.sortKey(for: $0.lastPathComponent) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in completed.prefix(max(0, completed.count - limit)) {
            try operations.remove(url)
        }
    }

    private static func encode(_ backup: JobBackup) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(backup)
    }

    private static func filename(date: Date, runID: UUID) -> String {
        "jobs-\(timestampFormatter.string(from: date))-\(runID.uuidString).json"
    }

    private static func sortKey(for filename: String) -> String? {
        let range = NSRange(filename.startIndex..., in: filename)
        guard let match = filenameRegex.firstMatch(in: filename, range: range),
              let timestampRange = Range(match.range(at: 1), in: filename),
              let uuidRange = Range(match.range(at: 2), in: filename) else { return nil }
        let timestamp = String(filename[timestampRange])
        let uuidText = String(filename[uuidRange])
        guard timestampFormatter.date(from: timestamp).map({ timestampFormatter.string(from: $0) }) == timestamp,
              UUID(uuidString: uuidText)?.uuidString == uuidText else { return nil }
        return "\(timestamp)-\(uuidText)"
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        formatter.isLenient = false
        return formatter
    }()
}
