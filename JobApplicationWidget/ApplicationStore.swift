import Foundation
import Combine

@MainActor
final class ApplicationStore: ObservableObject {
    @Published private(set) var jobs: [Job] = []
    @Published private(set) var errorMessage: String?

    private let database: JobDatabase?

    init(database: JobDatabase) throws {
        self.database = database
        jobs = try database.jobs()
    }

    init(failingWith error: Error) {
        database = nil
        errorMessage = String(describing: error)
    }

    func reload() {
        guard let database else { return }
        do {
            jobs = try database.jobs()
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func setStatus(_ status: JobStatus, for id: UUID) {
        guard let database else { return }
        do {
            try database.setStatus(id: id, status: status)
            jobs = try database.jobs()
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func add(_ job: Job) {
        guard let database else { return }
        do {
            try database.upsert(job, preservingTracking: false)
            jobs = try database.jobs()
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }
}
