import SwiftUI

@main
struct JobApplicationWidgetApp: App {
    @StateObject private var store: ApplicationStore
    @StateObject private var fetch: FetchController
    @StateObject private var scheduling: SchedulingController

    init() {
        let store: ApplicationStore
        var canInstallSchedule = false
        let workerURL = BundledWorkerLocation.url()
        do {
            let location = DatabaseLocation()
            let database = try JobDatabase(url: location.databaseURL())
            guard let defaults = UserDefaults(suiteName: location.appGroupID) else {
                throw DatabaseLocation.Error.appGroupUnavailable(location.appGroupID)
            }
            _ = try LegacyJobMigrator().migrateIfNeeded(
                defaults: defaults,
                database: database
            )
            store = try ApplicationStore(database: database)
            canInstallSchedule = true
        } catch {
            store = ApplicationStore(failingWith: error)
        }
        _store = StateObject(wrappedValue: store)
        _fetch = StateObject(wrappedValue: FetchController(
            workerURL: workerURL,
            onFinished: { store.reload() }
        ))
        let scheduling = SchedulingController(
            workerURL: workerURL,
            isEnabled: canInstallSchedule
        )
        _scheduling = StateObject(wrappedValue: scheduling)
        scheduling.install()
    }

    var body: some Scene {
        MenuBarExtra {
            ApplicationListView(
                store: store,
                fetch: fetch,
                schedulingErrorMessage: scheduling.errorMessage
            )
                .frame(minWidth: 720, idealWidth: 900, maxWidth: 1200,
                       minHeight: 520, idealHeight: 720, maxHeight: 900)
        } label: {
            Label("Job Applications", systemImage: "checklist")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class SchedulingController: ObservableObject {
    @Published private(set) var errorMessage: String?

    private let workerURL: URL
    private let isEnabled: Bool
    private var hasAttempted = false

    init(workerURL: URL, isEnabled: Bool) {
        self.workerURL = workerURL
        self.isEnabled = isEnabled
    }

    func install() {
        guard isEnabled, !hasAttempted else { return }
        hasAttempted = true
        let workerURL = workerURL
        Task {
            errorMessage = await Task.detached {
                do {
                    try LaunchAgentInstaller().install(workerURL: workerURL)
                    return nil
                } catch {
                    return String(describing: error)
                }
            }.value
        }
    }
}
