import Foundation

enum RunTrigger: String, Codable { case scheduled, manual }

enum RunStatus: String, Codable {
    case waitingForNetwork, running, suspended, succeeded, failed
}

struct RunRecord: Identifiable, Equatable {
    let id: UUID
    let trigger: RunTrigger
    let localDay: String
    var status: RunStatus
    var checkpointStage: String?
    var checkpointPayload: Data?
    let startedAt: Date
    var finishedAt: Date?
    var error: String?
    var updatedAt: Date
}

struct MelbourneSchedule {
    static let timeZone = TimeZone(identifier: "Australia/Melbourne")!

    func localDay(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Self.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    func isDue(at date: Date) -> Bool {
        calendar.component(.hour, from: date) >= 8
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = Self.timeZone
        return calendar
    }
}
