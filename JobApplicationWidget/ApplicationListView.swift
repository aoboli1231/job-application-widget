import SwiftUI
import AppKit

struct ApplicationListView: View {
    @StateObject private var store = ApplicationStore()
    @State private var showOnlyOpen = false
    @State private var showingAddJob = false

    private var visibleApplications: [JobApplication] {
        store.applications.filter { !showOnlyOpen || !$0.applied }
    }

    var body: some View {
        NavigationSplitView {
            List {
                Section("This week") {
                    Toggle("Show outstanding only", isOn: $showOnlyOpen)
                }
                Section("Applications") {
                    ForEach(visibleApplications) { application in
                        Button {
                            store.toggle(application)
                        } label: {
                            HStack {
                                Image(systemName: application.applied ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(application.applied ? .green : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(application.company).font(.headline)
                                    Text(application.role).font(.caption).lineLimit(2)
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
                    .help("Add a new job to track")
                }
                ToolbarItem {
                    Button { store.syncFromAgentFile() } label: {
                        Label("Sync agent updates", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .help("Import the latest jobs.json written by Codex")
                }
                ToolbarItem {
                    Button(role: .destructive) {
                        NSApplication.shared.terminate(nil)
                    } label: {
                        Label("Quit", systemImage: "power")
                    }
                    .help("Quit Job Application Widget")
                }
            }
        } detail: {
            DashboardView(store: store)
        }
        .sheet(isPresented: $showingAddJob) {
            AddApplicationView { application in
                store.add(application)
                showingAddJob = false
            }
        }
        .onAppear { store.syncFromAgentFile() }
        .navigationSplitViewStyle(.balanced)
    }
}

struct AddApplicationView: View {
    let onSave: (JobApplication) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var company = ""
    @State private var role = ""
    @State private var location = "Melbourne"
    @State private var match = 80
    @State private var fullTime = true
    @State private var jdURL = ""
    @State private var reason = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add job").font(.title.bold())
            TextField("Company", text: $company)
            TextField("Role", text: $role)
            TextField("Location", text: $location)
            HStack {
                Text("Match: \(match)%")
                Slider(value: Binding(get: { Double(match) }, set: { match = Int($0) }), in: 0...100, step: 1)
            }
            Toggle("Full-time", isOn: $fullTime)
            TextField("JD URL (optional)", text: $jdURL)
            TextField("Why it matches (optional)", text: $reason)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    let application = JobApplication(company: company, role: role, location: location,
                                                      priority: 99, match: match, fullTime: fullTime,
                                                      matchReason: reason, jdURL: jdURL.isEmpty ? nil : jdURL)
                    onSave(application)
                }
                .buttonStyle(.borderedProminent)
                .disabled(company.trimmingCharacters(in: .whitespaces).isEmpty || role.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

struct DashboardView: View {
    @ObservedObject var store: ApplicationStore

    private var outstanding: Int { store.applications.filter { !$0.applied }.count }

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
                    SummaryPill(title: "All", value: "\(store.applications.count)", color: .blue)
                    SummaryPill(title: "Applied", value: "\(store.applications.filter { $0.applied }.count)", color: .green)
                    SummaryPill(title: "Open", value: "\(outstanding)", color: .orange)
                    SummaryPill(title: "Full-time", value: "\(store.applications.filter { $0.fullTime }.count)", color: .purple)
                    SummaryPill(title: "Avg match", value: "\(averageMatch)%", color: .indigo)
                }

                ForEach(store.applications.sorted { $0.priority < $1.priority }) { application in
                    ApplicationCard(application: application) {
                        store.toggle(application)
                    }
                }
            }
            .padding(28)
        }
    }

    private var averageMatch: Int {
        guard !store.applications.isEmpty else { return 0 }
        return store.applications.map(\.match).reduce(0, +) / store.applications.count
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
    let application: JobApplication
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: toggle) {
                Image(systemName: application.applied ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(application.applied ? .green : .secondary)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("#\(application.priority)  \(application.company)").font(.headline)
                    if application.fullTime { Text("FULL-TIME").tagStyle(.green) }
                }
                Text(application.role).font(.title3)
                Text("\(application.location)  •  \(application.match)% match  •  \(application.status)")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(application.matchReason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 10) {
                    ActionCapsule(title: "Apply task", icon: "wand.and.stars", tint: .blue) { openCodexTask() }
                    ActionCapsule(title: "Find JD", icon: "doc.text.magnifyingglass", tint: .orange) { openJobDescription() }
                    ActionCapsule(title: "Resume", icon: "doc.text", tint: .purple) { openFolder("resume_gpt") }
                    ActionCapsule(title: "Cover letter", icon: "envelope", tint: .green) { openFolder("cover letter gpt") }
                }
            }
            Spacer()
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
    }

    private func openCodexTask() {
        // Opens the existing Codex task when the Codex URL scheme is available.
        // The task ID is kept configurable here so it can be replaced by the user's live task URL.
        let url = URL(string: "codex://thread/019fae20-5489-7e33-97c3-277a0ae8a1f4")!
        NSWorkspace.shared.open(url)
    }

    private func openJobDescription() {
        guard let value = application.jdURL,
              let directURL = URL(string: value),
              directURL.scheme != nil else {
            let alert = NSAlert()
            alert.messageText = "No direct JD link saved"
            alert.informativeText = "Ask the Codex job-search agent to add the original SEEK, Workday or company URL to jobs.json."
            alert.runModal()
            return
        }
        openInChrome(directURL)
    }

    private func openFolder(_ path: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop").appendingPathComponent(path)
        NSWorkspace.shared.open(url)
    }

    private func openInChrome(_ url: URL) {
        let chrome = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        if FileManager.default.fileExists(atPath: chrome.path) {
            NSWorkspace.shared.open([url], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
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
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(isHovering ? .white : tint)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(isHovering ? tint : tint.opacity(0.10), in: Capsule())
                .overlay(Capsule().stroke(tint.opacity(isHovering ? 0 : 0.20), lineWidth: 1))
                .scaleEffect(isHovering ? 1.03 : 1.0)
                .animation(.easeOut(duration: 0.15), value: isHovering)
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
        .onHover { isHovering = $0 }
        .help(title)
    }
}

private extension View {
    func tagStyle(_ color: Color) -> some View {
        self.font(.caption2.bold()).foregroundStyle(color).padding(.horizontal, 6).padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }
}
