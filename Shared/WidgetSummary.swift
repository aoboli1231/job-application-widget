import Foundation

struct WidgetSummary: Equatable {
    let openCount: Int
    let topJobs: [Job]
    let refreshedAt: Date?
}
