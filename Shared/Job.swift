import Foundation

enum JobStatus: String, Codable, CaseIterable { case new, review, preparing, ready, applied, interview, offer, rejected, archived }
enum RiskLevel: String, Codable { case low, needsReview, high }
enum Eligibility: String, Codable { case eligible, unclear, ineligible }

struct Job: Identifiable, Codable, Equatable {
    var id = UUID()
    var company: String
    var role: String
    var location: String
    var priority: Int = 99
    var workType: String?
    var isFullTime: Bool?
    var status: JobStatus = .new
    var notes = ""
    var appliedAt: Date?
    var publishedAt: Date?
    var deadline: Date?
    var matchScore: Int?
    var matchReason = ""
    var risk: RiskLevel = .needsReview
    var eligibility: Eligibility = .unclear
    var canonicalURL: URL?
    var platformJobID: String?
    var updatedAt = Date()
}
