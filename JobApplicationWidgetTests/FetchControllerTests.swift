import XCTest
@testable import JobApplicationWidget

@MainActor
final class FetchControllerTests: XCTestCase {
    func testFetchLaunchesBundledWorkerInForceMode() {
        let runner = RecordingFetchRunner()
        let workerURL = URL(fileURLWithPath: "/Test App.app/Contents/Helpers/job-scout")
        let controller = FetchController(workerURL: workerURL, runner: runner.run)

        controller.fetch()

        XCTAssertEqual(runner.workerURL, workerURL)
        XCTAssertEqual(runner.arguments, ["--force"])
        XCTAssertTrue(controller.isRunning)
    }

    func testDuplicateFetchIsIgnoredUntilCurrentRunFinishes() async {
        let runner = RecordingFetchRunner()
        let controller = FetchController(workerURL: .testWorker, runner: runner.run)

        controller.fetch()
        controller.fetch()
        XCTAssertEqual(runner.launchCount, 1)

        runner.complete(.success)
        await settleMainActor()
        controller.fetch()
        XCTAssertEqual(runner.launchCount, 2)

        runner.complete(
            FetchProcessResult(status: 1, standardOutput: "", standardError: "stale failure\n"),
            at: 0
        )
        await settleMainActor()
        XCTAssertTrue(controller.isRunning)
        XCTAssertNil(controller.errorMessage)

        runner.complete(.success, at: 1)
        await settleMainActor()
        XCTAssertFalse(controller.isRunning)
    }

    func testLaunchFailureIsVisibleAndResetsRunningState() {
        let controller = FetchController(
            workerURL: .testWorker,
            runner: { _, _, _ in throw FetchLaunchTestError.couldNotLaunch }
        )

        controller.fetch()

        XCTAssertFalse(controller.isRunning)
        XCTAssertNotNil(controller.errorMessage)
    }

    func testSuccessfulCompletionReloadsOnceAndClearsError() async {
        let runner = RecordingFetchRunner()
        var reloadCount = 0
        let controller = FetchController(
            workerURL: .testWorker,
            runner: runner.run,
            onFinished: { reloadCount += 1 }
        )

        controller.fetch()
        runner.complete(.success)
        runner.complete(.success)
        await settleMainActor()

        XCTAssertFalse(controller.isRunning)
        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(reloadCount, 1)
    }

    func testAlreadyRunningTokenIsNotReportedAsSuccess() async {
        let runner = RecordingFetchRunner()
        let controller = FetchController(workerURL: .testWorker, runner: runner.run)

        controller.fetch()
        runner.complete(FetchProcessResult(
            status: 0,
            standardOutput: WorkerResultToken.alreadyRunning.line + "\n",
            standardError: ""
        ))
        await settleMainActor()

        XCTAssertEqual(controller.errorMessage, "A run is already active.")
        XCTAssertFalse(controller.isRunning)
    }

    func testUnknownZeroExitAndNonzeroExitAreVisible() async {
        let runner = RecordingFetchRunner()
        let controller = FetchController(workerURL: .testWorker, runner: runner.run)

        controller.fetch()
        runner.complete(FetchProcessResult(status: 0, standardOutput: "unexpected\n", standardError: ""))
        await settleMainActor()
        XCTAssertEqual(controller.errorMessage, "Fetch failed with status 0.")

        controller.fetch()
        runner.complete(
            FetchProcessResult(status: 7, standardOutput: "", standardError: "worker failed\n"),
            at: 1
        )
        await settleMainActor()
        XCTAssertEqual(controller.errorMessage, "worker failed")
    }

    func testBundledWorkerLocationUsesOnlyBundleURL() {
        let bundleURL = URL(fileURLWithPath: "/Applications/Test App.app")
        XCTAssertEqual(
            BundledWorkerLocation.url(bundleURL: bundleURL).path,
            "/Applications/Test App.app/Contents/Helpers/job-scout"
        )
    }

    private func settleMainActor() async {
        await Task.yield()
        await Task.yield()
    }
}

private final class RecordingFetchRunner {
    private(set) var workerURL: URL?
    private(set) var arguments: [String]?
    private(set) var launchCount = 0
    private var completions: [(FetchProcessResult) -> Void] = []

    func run(
        workerURL: URL,
        arguments: [String],
        completion: @escaping (FetchProcessResult) -> Void
    ) throws -> Process? {
        self.workerURL = workerURL
        self.arguments = arguments
        launchCount += 1
        completions.append(completion)
        return nil
    }

    func complete(_ result: FetchProcessResult, at index: Int = 0) {
        completions[index](result)
    }
}

private enum FetchLaunchTestError: Error { case couldNotLaunch }

private extension URL {
    static let testWorker = URL(fileURLWithPath: "/Test App.app/Contents/Helpers/job-scout")
}

private extension FetchProcessResult {
    static let success = FetchProcessResult(
        status: 0,
        standardOutput: WorkerResultToken.succeeded.line + "\n",
        standardError: ""
    )
}
