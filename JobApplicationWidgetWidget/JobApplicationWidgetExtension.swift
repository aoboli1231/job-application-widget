import WidgetKit
import SwiftUI

struct ApplicationEntry: TimelineEntry {
    let date: Date
    let openCount: Int
    let topApplications: [Job]
}

struct ApplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> ApplicationEntry {
        ApplicationEntry(
            date: .now,
            openCount: 1,
            topApplications: [Job(company: "Example", role: "Data Analyst", location: "Melbourne")]
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (ApplicationEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ApplicationEntry>) -> Void) {
        completion(Timeline(entries: [makeEntry()], policy: .after(.now.addingTimeInterval(3600))))
    }

    private func makeEntry() -> ApplicationEntry {
        do {
            let database = try JobDatabase(
                url: DatabaseLocation().databaseURL(),
                mode: .readOnly
            )
            let summary = try database.summary(limit: 3)
            return ApplicationEntry(
                date: summary.refreshedAt ?? .now,
                openCount: summary.openCount,
                topApplications: summary.topJobs
            )
        } catch {
            return ApplicationEntry(date: .now, openCount: 0, topApplications: [])
        }
    }
}

struct JobApplicationWidget: Widget {
    let kind = "JobApplicationWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ApplicationProvider()) { entry in
            JobApplicationWidgetView(entry: entry)
        }
        .configurationDisplayName("Job Application Checklist")
        .description("See your highest-priority applications and keep momentum.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct JobApplicationWidgetView: View {
    let entry: ApplicationEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Applications").font(.headline)
                Spacer()
                Text("\(entry.openCount) open").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(entry.topApplications) { application in
                HStack(spacing: 6) {
                    Circle().fill(.blue).frame(width: 6, height: 6)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(application.company).font(.subheadline.bold()).lineLimit(1)
                        Text(application.role).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
            Text("Open Job Checklist").font(.caption2).foregroundStyle(.blue)
        }
        .padding()
    }
}

@main
struct JobApplicationWidgetBundle: WidgetBundle {
    var body: some Widget { JobApplicationWidget() }
}
