import Foundation

struct JobApplication: Identifiable, Codable, Hashable {
    let id: UUID
    var company: String
    var role: String
    var location: String
    var priority: Int
    var match: Int
    var fullTime: Bool
    var applied: Bool
    var status: String
    var notes: String
    var matchReason: String
    var jdURL: String?

    init(id: UUID = UUID(), company: String, role: String, location: String,
         priority: Int, match: Int, fullTime: Bool, applied: Bool = false,
         status: String = "Not applied", notes: String = "", matchReason: String = "", jdURL: String? = nil) {
        self.id = id
        self.company = company
        self.role = role
        self.location = location
        self.priority = priority
        self.match = match
        self.fullTime = fullTime
        self.applied = applied
        self.status = status
        self.notes = notes
        self.matchReason = matchReason
        self.jdURL = jdURL
    }
}

let initialApplications: [JobApplication] = [
    JobApplication(company: "Westpac", role: "2027 Data, Digital and AI Graduate Program", location: "Melbourne", priority: 1, match: 86, fullTime: true, matchReason: "Large-company graduate pathway; strong fit for SQL, Python, analytics and AI."),
    JobApplication(company: "Mercy Health", role: "Data and Support Analyst", location: "Richmond", priority: 2, match: 85, fullTime: true, matchReason: "Healthcare analytics aligns with your medical AI and reporting background."),
    JobApplication(company: "Honda Australia", role: "Service Data Analyst", location: "Moonee Ponds", priority: 3, match: 82, fullTime: true, matchReason: "Corporate operations analytics fit: SQL, Power BI, ETL and stakeholder reporting."),
    JobApplication(company: "The Salvation Army Australia", role: "Insights Analyst", location: "Blackburn", priority: 4, match: 88, fullTime: true, matchReason: "Strong match for segmentation, customer behaviour, Power BI and data quality.", jdURL: "https://salvationarmy.wd3.myworkdayjobs.com/broadbean_external/job/Blackburn-VIC-Australia/Insights-Analyst_R59942-1"),
    JobApplication(company: "Royal Flying Doctor Service Victoria", role: "Data Analyst", location: "Melbourne", priority: 5, match: 84, fullTime: true, matchReason: "Healthcare mission plus direct fit with operational reporting and data quality.", jdURL: "https://au.seek.com/job/93628991"),
    JobApplication(company: "The Florey Institute", role: "Junior Data Scientist — Australian Epilepsy Project", location: "Heidelberg", priority: 6, match: 90, fullTime: true, matchReason: "Highest technical fit: medical AI, deep learning and real-world health data."),
    JobApplication(company: "Aged Care Quality and Safety Commission", role: "Data Analyst", location: "Melbourne", priority: 7, match: 83, fullTime: true, matchReason: "Good fit for data analysis, reporting, governance and public-sector stakeholders."),
    JobApplication(company: "Just Digital People", role: "BI and Data Analyst", location: "Melbourne", priority: 8, match: 88, fullTime: true, matchReason: "Direct match for Power BI, SQL, Snowflake, dashboards and analytics consulting."),
    JobApplication(company: "Konnexus", role: "Data Quality Analyst", location: "Melbourne", priority: 9, match: 84, fullTime: false, matchReason: "Strong data validation, reconciliation and operational reporting match.")
]

@MainActor
final class ApplicationStore: ObservableObject {
    @Published var applications: [JobApplication] {
        didSet { save() }
    }

    private let key = "jobApplicationWidget.applications.v1"
    private let defaults = UserDefaults(suiteName: "group.com.aobo.JobApplicationCopilot") ?? .standard
    private let agentDatabaseURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/Codex/2026-07-30/bang/JobApplicationWidget/data/jobs.json")

    init() {
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode([JobApplication].self, from: data) {
            applications = saved
        } else {
            applications = initialApplications
        }
        syncFromAgentFile()
    }

    func toggle(_ application: JobApplication) {
        guard let index = applications.firstIndex(where: { $0.id == application.id }) else { return }
        applications[index].applied.toggle()
        applications[index].status = applications[index].applied ? "Applied" : "Not applied"
    }

    func add(_ application: JobApplication) {
        applications.append(application)
    }

    /// Imports records written by a Codex job-search agent, while preserving local tracking state.
    func syncFromAgentFile() {
        guard let data = try? Data(contentsOf: agentDatabaseURL),
              let incoming = try? JSONDecoder().decode([JobApplication].self, from: data) else { return }
        guard !incoming.isEmpty else { return }
        let localByID = Dictionary(uniqueKeysWithValues: applications.map { ($0.id, $0) })
        applications = incoming.map { item in
            guard let local = localByID[item.id] else { return item }
            var merged = item
            merged.applied = local.applied
            merged.status = local.status
            merged.notes = local.notes
            return merged
        }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(applications) else { return }
        defaults.set(data, forKey: key)
    }
}
