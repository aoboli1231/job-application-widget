import SwiftUI

@main
struct JobApplicationWidgetApp: App {
    @StateObject private var store: ApplicationStore

    init() {
        let store: ApplicationStore
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
        } catch {
            store = ApplicationStore(failingWith: error)
        }
        _store = StateObject(wrappedValue: store)
    }

    var body: some Scene {
        MenuBarExtra {
            ApplicationListView(store: store)
                .frame(minWidth: 720, idealWidth: 900, maxWidth: 1200,
                       minHeight: 520, idealHeight: 720, maxHeight: 900)
        } label: {
            Label("Job Applications", systemImage: "checklist")
        }
        .menuBarExtraStyle(.window)
    }
}
