import Combine
import Foundation

struct FetchProcessResult: Equatable {
    let status: Int32
    let standardOutput: String
    let standardError: String
}

enum BundledWorkerLocation {
    static func url(bundleURL: URL = Bundle.main.bundleURL) -> URL {
        bundleURL.appendingPathComponent("Contents/Helpers/job-scout")
    }
}

@MainActor
final class FetchController: ObservableObject {
    typealias Runner = (
        _ executableURL: URL,
        _ arguments: [String],
        _ completion: @escaping (FetchProcessResult) -> Void
    ) throws -> Process?

    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?

    private let workerURL: URL
    private let runner: Runner
    private let onFinished: () -> Void
    private var activeRunID: UUID?
    private var process: Process?

    init(
        workerURL: URL,
        runner: Runner? = nil,
        onFinished: @escaping () -> Void = {}
    ) {
        self.workerURL = workerURL
        self.runner = runner ?? Self.runProcess
        self.onFinished = onFinished
    }

    func fetch() {
        guard !isRunning else { return }
        let runID = UUID()
        activeRunID = runID
        isRunning = true
        errorMessage = nil
        do {
            let process = try runner(workerURL, ["--force"]) { [weak self] result in
                Task { @MainActor in self?.finish(result, runID: runID) }
            }
            if activeRunID == runID { self.process = process }
        } catch {
            activeRunID = nil
            isRunning = false
            errorMessage = String(describing: error)
        }
    }

    private func finish(_ result: FetchProcessResult, runID: UUID) {
        guard activeRunID == runID else { return }
        activeRunID = nil
        process = nil
        isRunning = false
        let token = WorkerResultToken.parse(result.standardOutput)
        if result.status == 0, token == .alreadyRunning {
            errorMessage = "A run is already active."
        } else if result.status == 0,
                  token == .succeeded || token == .skippedNotDue || token == .skippedAlreadySucceeded {
            errorMessage = nil
        } else {
            let detail = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            errorMessage = detail.isEmpty
                ? "Fetch failed with status \(result.status)."
                : detail
        }
        onFinished()
    }

    private static func runProcess(
        executableURL: URL,
        arguments: [String],
        completion: @escaping (FetchProcessResult) -> Void
    ) throws -> Process {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { process in
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            completion(FetchProcessResult(
                status: process.terminationStatus,
                standardOutput: String(decoding: outputData, as: UTF8.self),
                standardError: String(decoding: data, as: UTF8.self)
            ))
        }
        try process.run()
        return process
    }
}
