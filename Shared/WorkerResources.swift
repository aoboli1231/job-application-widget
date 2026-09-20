import Foundation

protocol WorkerProcess: AnyObject {
    var isRunning: Bool { get }
    func terminate()
    func interrupt()
}

extension Process: WorkerProcess {}

protocol WorkerProcessWaiting {
    func waitForExit(
        of process: WorkerProcess,
        timeout: TimeInterval,
        completion: @escaping (_ exited: Bool) -> Void
    )
}

final class DispatchProcessWaiter: WorkerProcessWaiting {
    private let queue = DispatchQueue(label: "JobApplicationCopilot.ProcessWaiter")

    func waitForExit(
        of process: WorkerProcess,
        timeout: TimeInterval,
        completion: @escaping (Bool) -> Void
    ) {
        guard process.isRunning, let process = process as? Process else {
            completion(!process.isRunning)
            return
        }
        ProcessExitWait(process: process, timeout: timeout, queue: queue, completion: completion).start()
    }
}

private final class ProcessExitWait {
    private let process: Process
    private let timeout: TimeInterval
    private let queue: DispatchQueue
    private let completion: (Bool) -> Void
    private var processSource: DispatchSourceProcess?
    private var timer: DispatchSourceTimer?
    private var retainedSelf: ProcessExitWait?
    private var finished = false

    init(process: Process, timeout: TimeInterval, queue: DispatchQueue, completion: @escaping (Bool) -> Void) {
        self.process = process
        self.timeout = timeout
        self.queue = queue
        self.completion = completion
    }

    func start() {
        retainedSelf = self
        queue.async {
            guard self.process.isRunning else {
                self.finish(exited: true)
                return
            }
            let processSource = DispatchSource.makeProcessSource(
                identifier: self.process.processIdentifier,
                eventMask: .exit,
                queue: self.queue
            )
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            self.processSource = processSource
            self.timer = timer
            processSource.setEventHandler { [weak self] in self?.finish(exited: true) }
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.finish(exited: !self.process.isRunning)
            }
            processSource.resume()
            timer.schedule(deadline: .now() + self.timeout)
            timer.resume()
        }
    }

    private func finish(exited: Bool) {
        guard !finished else { return }
        finished = true
        processSource?.setEventHandler {}
        timer?.setEventHandler {}
        processSource?.cancel()
        timer?.cancel()
        processSource = nil
        timer = nil
        completion(exited)
        retainedSelf = nil
    }
}

final class WorkerResources {
    private let lock = NSLock()
    private let processWaiter: WorkerProcessWaiting
    private let terminationTimeout: TimeInterval
    private var processes: [WorkerProcess] = []
    private var cancellations: [() -> Void] = []
    private var cancelling = false

    init(
        processWaiter: WorkerProcessWaiting = DispatchProcessWaiter(),
        terminationTimeout: TimeInterval = 5
    ) {
        self.processWaiter = processWaiter
        self.terminationTimeout = terminationTimeout
    }

    func register(process: WorkerProcess) {
        lock.lock()
        let cancelImmediately = cancelling
        if !cancelImmediately { processes.append(process) }
        lock.unlock()
        if cancelImmediately { stop(process) }
    }

    func registerCancellation(_ cancellation: @escaping () -> Void) {
        lock.lock()
        let cancelImmediately = cancelling
        if !cancelImmediately { cancellations.append(cancellation) }
        lock.unlock()
        if cancelImmediately { cancellation() }
    }

    func cancelAll() {
        lock.lock()
        guard !cancelling else {
            lock.unlock()
            return
        }
        cancelling = true
        let ownedProcesses = processes
        let ownedCancellations = cancellations
        processes.removeAll()
        cancellations.removeAll()
        lock.unlock()

        ownedCancellations.forEach { $0() }
        ownedProcesses.forEach(stop)
    }

    private func stop(_ process: WorkerProcess) {
        guard process.isRunning else { return }
        process.terminate()
        processWaiter.waitForExit(of: process, timeout: terminationTimeout) { exited in
            if !exited, process.isRunning { process.interrupt() }
        }
    }

    deinit { cancelAll() }
}
