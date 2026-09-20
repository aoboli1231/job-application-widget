import Foundation
import Network

enum NetworkGateEvent {
    case pathSatisfied, pathUnsatisfied, timerFired
    case probesSucceeded, probesFailed
    case sleep, wake, reset, cancel
}

enum NetworkStabilityState: Equatable {
    case offline, stabilizing(deadline: TimeInterval), probing, ready
}

enum NetworkStabilityAction: Equatable {
    case none, arm(deadline: TimeInterval), cancelTimer, beginProbes
    case cancelAll, awaitPathEvent, ready
}

struct NetworkStabilityMachine {
    let stableInterval: TimeInterval
    private(set) var state: NetworkStabilityState = .offline

    init(stableInterval: TimeInterval = 60) { self.stableInterval = stableInterval }

    mutating func handle(_ event: NetworkGateEvent, now: TimeInterval) -> NetworkStabilityAction {
        switch event {
        case .pathSatisfied:
            guard state == .offline else { return .none }
            let deadline = now + stableInterval
            state = .stabilizing(deadline: deadline)
            return .arm(deadline: deadline)
        case .pathUnsatisfied:
            let previous = state
            state = .offline
            switch previous {
            case .stabilizing: return .cancelTimer
            case .probing, .ready: return .cancelAll
            case .offline: return .none
            }
        case .timerFired:
            guard case let .stabilizing(deadline) = state, now >= deadline else { return .none }
            state = .probing
            return .beginProbes
        case .probesSucceeded:
            guard state == .probing else { return .none }
            state = .ready
            return .ready
        case .probesFailed:
            guard state == .probing else { return .none }
            state = .offline
            return .cancelAll
        case .sleep, .reset, .cancel:
            state = .offline
            return .cancelAll
        case .wake:
            state = .offline
            return .awaitPathEvent
        }
    }
}

protocol HTTPSRequesting {
    func statusCode(for url: URL) async throws -> Int
}

struct ProbePolicy {
    let urls: [URL]
    let delayBetweenProbes: TimeInterval

    func accepts(_ status: Int) -> Bool { (200...399).contains(status) }

    static let production = ProbePolicy(
        urls: [
            URL(string: "https://www.apple.com/library/test/success.html")!,
            URL(string: "https://connectivitycheck.gstatic.com/generate_204")!
        ],
        delayBetweenProbes: 3
    )
}

final class URLSessionHTTPSRequester: HTTPSRequesting {
    enum Error: Swift.Error { case nonHTTPResponse }
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    func statusCode(for url: URL) async throws -> Int {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw Error.nonHTTPResponse }
        return response.statusCode
    }
}

protocol NetworkPathMonitoring: AnyObject {
    var updateHandler: ((Bool) -> Void)? { get set }
    func start(queue: DispatchQueue)
    func cancel()
}

final class SystemNetworkPathMonitor: NetworkPathMonitoring {
    var updateHandler: ((Bool) -> Void)?
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.updateHandler?(path.status == .satisfied)
        }
    }

    func start(queue: DispatchQueue) { monitor.start(queue: queue) }
    func cancel() { monitor.cancel() }
}

protocol NetworkGateCancellation: AnyObject { func cancel() }

protocol NetworkGating: AnyObject {
    func waitUntilUsable() async throws -> NetworkLease
    func reset()
    func cancel()
}

final class NetworkLease {
    enum Error: Swift.Error { case waiterAlreadyRegistered }

    private let lock = NSLock()
    private var invalidated = false
    private var waiter: (id: UUID, continuation: CheckedContinuation<Void, Swift.Error>)?

    var hasWaiter: Bool {
        lock.lock()
        defer { lock.unlock() }
        return waiter != nil
    }

    func waitForInvalidation() async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if invalidated {
                    lock.unlock()
                    continuation.resume()
                } else if waiter != nil {
                    lock.unlock()
                    continuation.resume(throwing: Error.waiterAlreadyRegistered)
                } else {
                    waiter = (waiterID, continuation)
                    lock.unlock()
                }
            }
        } onCancel: {
            self.cancelWaiter(id: waiterID)
        }
    }

    func invalidate() {
        lock.lock()
        guard !invalidated else {
            lock.unlock()
            return
        }
        invalidated = true
        let continuation = waiter?.continuation
        waiter = nil
        lock.unlock()
        continuation?.resume()
    }

    private func cancelWaiter(id: UUID) {
        lock.lock()
        guard waiter?.id == id else {
            lock.unlock()
            return
        }
        let continuation = waiter?.continuation
        waiter = nil
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }

    deinit { invalidate() }
}

protocol OneShotTimerScheduling {
    func schedule(after interval: TimeInterval, handler: @escaping () -> Void) -> NetworkGateCancellation
}

final class DispatchOneShotTimerScheduler: OneShotTimerScheduling {
    private let queue: DispatchQueue
    init(queue: DispatchQueue) { self.queue = queue }

    func schedule(after interval: TimeInterval, handler: @escaping () -> Void) -> NetworkGateCancellation {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let token = DispatchTimerToken(timer: timer)
        timer.setEventHandler(handler: handler)
        timer.schedule(deadline: .now() + interval)
        timer.resume()
        return token
    }
}

private final class DispatchTimerToken: NetworkGateCancellation {
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    init(timer: DispatchSourceTimer) { self.timer = timer }

    func cancel() {
        lock.lock()
        let ownedTimer = timer
        timer = nil
        lock.unlock()
        ownedTimer?.setEventHandler {}
        ownedTimer?.cancel()
    }

    deinit { cancel() }
}

final class NetworkGate: NetworkGating {
    enum Error: Swift.Error { case waiterAlreadyRegistered, invalidProbePolicy }
    typealias Delay = (TimeInterval) async throws -> Void

    private let queue: DispatchQueue
    private let monitor: NetworkPathMonitoring
    private let requester: HTTPSRequesting
    private let policy: ProbePolicy
    private let timerScheduler: OneShotTimerScheduling
    private let now: () -> TimeInterval
    private let delay: Delay
    private var machine: NetworkStabilityMachine
    private var timer: NetworkGateCancellation?
    private var probeTask: Task<Void, Never>?
    private var waiter: CheckedContinuation<NetworkLease, Swift.Error>?
    private var currentLease: NetworkLease?
    private var monitorStarted = false
    private var lastPathSatisfied = false
    private var generation = 0
    private var terminated = false

    convenience init() {
        let queue = DispatchQueue(label: "JobApplicationCopilot.NetworkGate")
        self.init(
            queue: queue,
            monitor: SystemNetworkPathMonitor(),
            requester: URLSessionHTTPSRequester(),
            policy: .production,
            timerScheduler: DispatchOneShotTimerScheduler(queue: queue),
            now: { ProcessInfo.processInfo.systemUptime },
            delay: { seconds in
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        )
    }

    init(
        queue: DispatchQueue = DispatchQueue(label: "JobApplicationCopilot.NetworkGate.Tests"),
        monitor: NetworkPathMonitoring,
        requester: HTTPSRequesting,
        policy: ProbePolicy,
        timerScheduler: OneShotTimerScheduling,
        stableInterval: TimeInterval = 60,
        now: @escaping () -> TimeInterval,
        delay: @escaping Delay
    ) {
        self.queue = queue
        self.monitor = monitor
        self.requester = requester
        self.policy = policy
        self.timerScheduler = timerScheduler
        machine = NetworkStabilityMachine(stableInterval: stableInterval)
        self.now = now
        self.delay = delay
        monitor.updateHandler = { [weak self] satisfied in
            self?.queue.async { self?.apply(satisfied ? .pathSatisfied : .pathUnsatisfied) }
        }
    }

    deinit {
        timer?.cancel()
        probeTask?.cancel()
        monitor.cancel()
        monitor.updateHandler = nil
        waiter?.resume(throwing: CancellationError())
        currentLease?.invalidate()
    }

    func waitUntilUsable() async throws -> NetworkLease {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NetworkLease, Swift.Error>) in
                queue.async {
                    guard !self.terminated else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    guard self.waiter == nil else {
                        continuation.resume(throwing: Error.waiterAlreadyRegistered)
                        return
                    }
                    if self.machine.state == .ready {
                        let lease = self.currentLease ?? NetworkLease()
                        self.currentLease = lease
                        continuation.resume(returning: lease)
                        return
                    }
                    self.waiter = continuation
                    if !self.monitorStarted {
                        self.monitorStarted = true
                        self.monitor.start(queue: self.queue)
                    } else if self.lastPathSatisfied {
                        self.apply(.pathSatisfied)
                    }
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func reset() { queue.async { self.apply(.reset) } }

    func cancel() {
        queue.async {
            guard !self.terminated else { return }
            self.terminated = true
            _ = self.machine.handle(.cancel, now: self.now())
            self.generation += 1
            self.cancelOwnedWork()
            self.monitor.cancel()
            self.monitor.updateHandler = nil
            let waiter = self.waiter
            self.waiter = nil
            self.currentLease?.invalidate()
            self.currentLease = nil
            waiter?.resume(throwing: CancellationError())
        }
    }

    private func apply(_ event: NetworkGateEvent) {
        guard !terminated else { return }
        switch event {
        case .pathSatisfied: lastPathSatisfied = true
        case .pathUnsatisfied: lastPathSatisfied = false
        default: break
        }

        switch machine.handle(event, now: now()) {
        case let .arm(deadline):
            cancelTimer()
            let expectedGeneration = generation
            timer = timerScheduler.schedule(after: max(0, deadline - now())) { [weak self] in
                guard let self else { return }
                self.queue.async {
                    guard self.generation == expectedGeneration else { return }
                    self.timer = nil
                    self.apply(.timerFired)
                }
            }
        case .cancelTimer:
            generation += 1
            cancelTimer()
        case .beginProbes:
            beginProbes()
        case .cancelAll:
            generation += 1
            cancelOwnedWork()
            currentLease?.invalidate()
            currentLease = nil
        case .ready:
            cancelTimer()
            let waiter = waiter
            self.waiter = nil
            let lease = NetworkLease()
            currentLease = lease
            waiter?.resume(returning: lease)
        case .none, .awaitPathEvent:
            break
        }
    }

    private func beginProbes() {
        guard policy.urls.count == 2 else {
            apply(.probesFailed)
            let waiter = waiter
            self.waiter = nil
            waiter?.resume(throwing: Error.invalidProbePolicy)
            return
        }

        let expectedGeneration = generation
        let urls = policy.urls
        let policy = policy
        let requester = requester
        let delay = delay
        probeTask = Task { [weak self] in
            do {
                let first = try await requester.statusCode(for: urls[0])
                guard policy.accepts(first) else { throw ProbeFailure.rejectedStatus }
                try await delay(policy.delayBetweenProbes)
                try Task.checkCancellation()
                let second = try await requester.statusCode(for: urls[1])
                guard policy.accepts(second) else { throw ProbeFailure.rejectedStatus }
                self?.finishProbes(.probesSucceeded, generation: expectedGeneration)
            } catch is CancellationError {
                return
            } catch {
                self?.finishProbes(.probesFailed, generation: expectedGeneration)
            }
        }
    }

    private func finishProbes(_ event: NetworkGateEvent, generation expectedGeneration: Int) {
        queue.async {
            guard self.generation == expectedGeneration, self.machine.state == .probing else { return }
            self.probeTask = nil
            self.apply(event)
        }
    }

    private func cancelTimer() { timer?.cancel(); timer = nil }
    private func cancelOwnedWork() { cancelTimer(); probeTask?.cancel(); probeTask = nil }
    private enum ProbeFailure: Swift.Error { case rejectedStatus }
}
