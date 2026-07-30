import SwiftUI

@main
struct JobApplicationWidgetApp: App {
    var body: some Scene {
        MenuBarExtra {
            ApplicationListView()
                .frame(minWidth: 720, idealWidth: 900, maxWidth: 1200,
                       minHeight: 520, idealHeight: 720, maxHeight: 900)
        } label: {
            Label("Job Applications", systemImage: "checklist")
        }
        .menuBarExtraStyle(.window)
    }
}
