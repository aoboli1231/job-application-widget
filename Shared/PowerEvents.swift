import AppKit

enum PowerEvent: Equatable {
    case willSleep
    case didWake
}

protocol PowerEventSource {
    func events() -> AsyncStream<PowerEvent>
}

final class WorkspacePowerEvents: PowerEventSource {
    private let center: NotificationCenter

    init(center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.center = center
    }

    func events() -> AsyncStream<PowerEvent> {
        let center = center
        return AsyncStream { continuation in
            let sleep = center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: nil
            ) { _ in
                continuation.yield(.willSleep)
            }
            let wake = center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: nil
            ) { _ in
                continuation.yield(.didWake)
            }
            continuation.onTermination = { _ in
                center.removeObserver(sleep)
                center.removeObserver(wake)
            }
        }
    }
}
