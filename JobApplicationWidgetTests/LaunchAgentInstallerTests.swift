import Darwin
import XCTest
@testable import JobApplicationWidget

final class LaunchAgentInstallerTests: XCTestCase {
    func testPlistHasOnlyLoginAndEightAMTriggers() throws {
        let workerURL = URL(fileURLWithPath: "/Applications/Test App.app/Contents/Helpers/job-scout")
        let plist = LaunchAgentInstaller.makePlist(
            workerURL: workerURL,
            localTimeZone: MelbourneSchedule.timeZone
        )

        XCTAssertEqual(Set(plist.keys), ["Label", "ProgramArguments", "RunAtLoad", "StartCalendarInterval"])
        XCTAssertEqual(plist["Label"] as? String, LaunchAgentInstaller.label)
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [workerURL.path, "--scheduled"])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual((plist["StartCalendarInterval"] as? [String: Int])?["Hour"], 8)
        XCTAssertEqual((plist["StartCalendarInterval"] as? [String: Int])?["Minute"], 0)
        for forbidden in ["StartInterval", "KeepAlive", "WatchPaths", "QueueDirectories"] {
            XCTAssertNil(plist[forbidden])
        }
    }

    func testShanghaiClockCoversMelbourneEightAcrossDaylightSaving() throws {
        let workerURL = URL(fileURLWithPath: "/tmp/job-scout")
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-24T00:00:00Z"))
        let plist = LaunchAgentInstaller.makePlist(
            workerURL: workerURL,
            localTimeZone: shanghai,
            startingAt: start
        )

        XCTAssertEqual(plist["StartCalendarInterval"] as? [[String: Int]], [
            ["Hour": 5, "Minute": 0],
            ["Hour": 6, "Minute": 0]
        ])
        XCTAssertEqual(Set(plist.keys), ["Label", "ProgramArguments", "RunAtLoad", "StartCalendarInterval"])
    }

    func testPlistRoundTripsAsXML() throws {
        let expected = LaunchAgentInstaller.makePlist(workerURL: URL(fileURLWithPath: "/tmp/job-scout"))
        let data = try PropertyListSerialization.data(fromPropertyList: expected, format: .xml, options: 0)
        var format = PropertyListSerialization.PropertyListFormat.binary
        let decoded = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: &format) as? NSDictionary
        )

        XCTAssertEqual(format, .xml)
        XCTAssertTrue(decoded.isEqual(to: expected))
    }

    func testFirstInstallWritesPrivatePlistAndBootstrapsUserDomain() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        try fixture.installer.install(workerURL: fixture.workerURL)

        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.plistURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(fixture.commands, [
            Command(executable: "/bin/launchctl", arguments: ["bootstrap", "gui/501", fixture.plistURL.path])
        ])
    }

    func testChangedInstallBootsOutThenAtomicallyReplacesAndBootstraps() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let oldPlist = LaunchAgentInstaller.makePlist(workerURL: URL(fileURLWithPath: "/old/job-scout"))
        let oldData = try PropertyListSerialization.data(fromPropertyList: oldPlist, format: .xml, options: 0)
        try FileManager.default.createDirectory(
            at: fixture.plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try oldData.write(to: fixture.plistURL)

        try fixture.installer.install(workerURL: fixture.workerURL)

        let installed = try Data(contentsOf: fixture.plistURL)
        let decoded = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: installed, format: nil) as? NSDictionary
        )
        XCTAssertTrue(decoded.isEqual(to: LaunchAgentInstaller.makePlist(workerURL: fixture.workerURL)))
        XCTAssertEqual(fixture.commands.map(\.arguments), [
            ["bootout", "gui/501", fixture.plistURL.path],
            ["bootstrap", "gui/501", fixture.plistURL.path]
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.plistURL.path + ".tmp"))
    }

    func testSemanticallyIdenticalPlistIsNoOp() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.installer.install(workerURL: fixture.workerURL)
        fixture.commands.removeAll()

        try fixture.installer.install(workerURL: fixture.workerURL)

        XCTAssertTrue(fixture.commands.isEmpty)
    }

    func testLaunchctlFailureSurfacesStatusAndStandardError() throws {
        let fixture = try Fixture(result: LaunchAgentCommandResult(status: 5, standardError: "not permitted\n"))
        defer { fixture.cleanUp() }

        XCTAssertThrowsError(try fixture.installer.install(workerURL: fixture.workerURL)) { error in
            XCTAssertEqual(
                error as? LaunchAgentInstaller.Error,
                .launchctlFailed(command: "bootstrap", status: 5, standardError: "not permitted\n")
            )
            XCTAssertTrue(error.localizedDescription.contains("not permitted"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.plistURL.path))
    }

    func testBootstrapFailureDoesNotMakeNextInstallANoOp() throws {
        let fixture = try Fixture(results: [
            LaunchAgentCommandResult(status: 5, standardError: "not permitted"),
            LaunchAgentCommandResult(status: 0, standardError: "")
        ])
        defer { fixture.cleanUp() }

        XCTAssertThrowsError(try fixture.installer.install(workerURL: fixture.workerURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.plistURL.path))
        try fixture.installer.install(workerURL: fixture.workerURL)

        XCTAssertEqual(fixture.commands.map(\.arguments), [
            ["bootstrap", "gui/501", fixture.plistURL.path],
            ["bootstrap", "gui/501", fixture.plistURL.path]
        ])
    }
}

private final class Fixture {
    let root: URL
    let workerURL: URL
    var commands: [Command] = []
    lazy var installer = LaunchAgentInstaller(
        libraryDirectory: root,
        uid: 501,
        commandRunner: { [unowned self] executable, arguments in
            self.commands.append(Command(executable: executable.path, arguments: arguments))
            return self.results.count > 1 ? self.results.removeFirst() : self.results[0]
        }
    )
    private var results: [LaunchAgentCommandResult]

    init(result: LaunchAgentCommandResult = LaunchAgentCommandResult(status: 0, standardError: "")) throws {
        results = [result]
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        workerURL = root.appendingPathComponent("Test App/Contents/Helpers/job-scout")
        try createWorker()
    }

    init(results: [LaunchAgentCommandResult]) throws {
        precondition(!results.isEmpty)
        self.results = results
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        workerURL = root.appendingPathComponent("Test App/Contents/Helpers/job-scout")
        try createWorker()
    }

    private func createWorker() throws {
        try FileManager.default.createDirectory(
            at: workerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: workerURL.path, contents: Data()))
        XCTAssertEqual(chmod(workerURL.path, 0o700), 0)
    }

    var plistURL: URL {
        root.appendingPathComponent("LaunchAgents/\(LaunchAgentInstaller.label).plist")
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

private struct Command: Equatable {
    let executable: String
    let arguments: [String]
}
