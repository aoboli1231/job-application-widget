import SwiftUI
import AppKit

struct ApplicationListView: View {
    @ObservedObject var store: ApplicationStore
    @State private var showOnlyOpen = false
    @State private var showingAddJob = false

    private var visibleJobs: [Job] {
        store.jobs.filter { !showOnlyOpen || !Self.inactiveStatuses.contains($0.status) }
    }

    private static let inactiveStatuses: Set<JobStatus> = [.applied, .rejected, .archived]

    var body: some View {
        NavigationSplitView {
            List {
                if let errorMessage = store.errorMessage {
                    Section("Database error") {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
                Section("This week") {
                    Toggle("Show outstanding only", isOn: $showOnlyOpen)
                }
                Section("Applications") {
                    ForEach(visibleJobs) { job in
                        Button {
                            toggle(job)
                        } label: {
                            HStack {
                                Image(systemName: job.status == .applied ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(job.status == .applied ? .green : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(job.company).font(.headline)
                                    Text(job.role).font(.caption).lineLimit(2)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Job Checklist")
            .toolbar {
                ToolbarItem {
                    Button { showingAddJob = true } label: {
                        Label("Add job", systemImage: "plus")
                    }
                    .help("Add a job to track")
                }
                ToolbarItem {
                    Button { store.reload() } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help("Reload jobs from the shared database")
                }
                ToolbarItem {
                    Button(role: .destructive) {
                        NSApplication.shared.terminate(nil)
                    } label: {
                        Label("Quit", systemImage: "power")
                    }
                }
            }
        } detail: {
            DashboardView(store: store)
        }
        .sheet(isPresented: $showingAddJob) {
            AddApplicationView { job in
                store.add(job)
                showingAddJob = false
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private func toggle(_ job: Job) {
        store.setStatus(job.status == .applied ? .new : .applied, for: job.id)
    }
}

struct AddApplicationView: View {
    let onSave: (Job) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var company = ""
    @State private var role = ""
    @State private var location = "Melbourne"
    @State private var matchScore = 80
    @State private var fullTime = true
    @State private var jobURL = ""
    @State private var reason = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add job").font(.title.bold())
            TextField("Company", text: $company)
            TextField("Role", text: $role)
            TextField("Location", text: $location)
            HStack {
                Text("Match: \(matchScore)%")
                Slider(
                    value: Binding(
                        get: { Double(matchScore) },
                        set: { matchScore = Int($0) }
                    ),
                    in: 0...100,
                    step: 1
                )
            }
            Toggle("Full-time", isOn: $fullTime)
            TextField("Job URL (optional)", text: $jobURL)
            TextField("Why it matches (optional)", text: $reason)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") { onSave(makeJob()) }
                    .buttonStyle(.borderedProminent)
                    .disabled(company.trimmingCharacters(in: .whitespaces).isEmpty || role.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func makeJob() -> Job {
        var job = Job(company: company, role: role, location: location)
        job.isFullTime = fullTime
        job.workType = fullTime ? "Full-time" : "Part-time"
        job.matchScore = matchScore
        job.matchReason = reason
        if !jobURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            job.canonicalURL = URL(string: jobURL)
        }
        return job
    }
}

struct DashboardView: View {
    @ObservedObject var store: ApplicationStore

    private var outstanding: Int {
        store.jobs.filter { ![JobStatus.applied, .rejected, .archived].contains($0.status) }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Application dashboard").font(.largeTitle.bold())
                        Text("Track the next best application without losing momentum.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(outstanding) open")
                        .font(.headline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.blue.opacity(0.12), in: Capsule())
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                    SummaryPill(title: "All", value: "\(store.jobs.count)", color: .blue)
                    SummaryPill(title: "Applied", value: "\(store.jobs.filter { $0.status == .applied }.count)", color: .green)
                    SummaryPill(title: "Open", value: "\(outstanding)", color: .orange)
                    SummaryPill(title: "Full-time", value: "\(store.jobs.filter { $0.isFullTime == true }.count)", color: .purple)
                    SummaryPill(title: "Avg match", value: "\(averageMatch)%", color: .indigo)
                }

                ForEach(store.jobs.sorted { $0.priority < $1.priority }) { job in
                    ApplicationCard(job: job) {
                        store.setStatus(job.status == .applied ? .new : .applied, for: job.id)
                    }
                }
            }
            .padding(28)
        }
    }

    private var averageMatch: Int {
        let scores = store.jobs.compactMap(\.matchScore)
        return scores.isEmpty ? 0 : scores.reduce(0, +) / scores.count
    }
}

struct SummaryPill: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ApplicationCard: View {
    let job: Job
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: toggle) {
                Image(systemName: job.status == .applied ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(job.status == .applied ? .green : .secondary)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("#\(job.priority)  \(job.company)").font(.headline)
                    if job.isFullTime == true { Text("FULL-TIME").tagStyle(.green) }
                }
                Text(job.role).font(.title3)
                Text("\(job.location)  •  \(job.matchScore ?? 0)% match  •  \(job.status.rawValue.capitalized)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(job.matchReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let url = job.canonicalURL {
                    ActionCapsule(title: "Apply", icon: "arrow.up.right.square", tint: .blue) {
                        openInChrome(url)
                    }
                }
            }
            Spacer()
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
    }

    private func openInChrome(_ url: URL) {
        let chrome = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        if FileManager.default.fileExists(atPath: chrome.path) {
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: chrome,
                configuration: NSWorkspace.OpenConfiguration()
            )
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

struct ActionCapsule: View {
    let title: String
    let icon: String
    let tint: Color
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isHovering ? .white : tint)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(isHovering ? tint : tint.opacity(0.10), in: Capsule())
                .overlay(Capsule().stroke(tint.opacity(isHovering ? 0 : 0.20)))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(title)
    }
}

private extension View {
    func tagStyle(_ color: Color) -> some View {
        font(.caption2.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }
}
