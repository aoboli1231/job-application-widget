import Foundation

struct MigrationResult: Equatable {
    var inserted = 0
    var updated = 0
    var skippedDuplicates = 0
    var alreadyCompleted = false
}

enum LegacyMigrationError: Error {
    case invalidDefaultsData
    case invalidAgentJSON
}

final class LegacyJobMigrator {
    private let marker = "legacy-v1-complete"

    func migrate(
        legacy: [JobApplication],
        agent: [JobApplication],
        into database: JobDatabase
    ) throws -> MigrationResult {
        try migrate(
            legacyJobs: legacy.map(convert),
            agentJobs: agent.map(convert),
            into: database
        )
    }

    func migrate(
        legacy: [JobApplication],
        agentJobs: [Job],
        into database: JobDatabase
    ) throws -> MigrationResult {
        try migrate(legacyJobs: legacy.map(convert), agentJobs: agentJobs, into: database)
    }

    func migrateIfNeeded(
        defaults: UserDefaults,
        key: String = "jobApplicationWidget.applications.v1",
        agentJSONURL: URL? = nil,
        database: JobDatabase,
        seed: [JobApplication] = initialApplications
    ) throws -> MigrationResult {
        guard try database.metadata(forKey: marker) == nil else {
            return MigrationResult(alreadyCompleted: true)
        }

        let legacy = try decodeDefaults(defaults, key: key)
        let agentJobs = try decodeAgentFile(agentJSONURL)
        let shouldSeed: Bool
        if legacy.isEmpty {
            shouldSeed = try database.jobs().isEmpty
        } else {
            shouldSeed = false
        }
        return try migrate(
            legacyJobs: shouldSeed ? seed.map(convert) : legacy.map(convert),
            agentJobs: agentJobs,
            into: database
        )
    }

    private func migrate(
        legacyJobs: [Job],
        agentJobs: [Job],
        into database: JobDatabase
    ) throws -> MigrationResult {
        try database.withTransaction {
            guard try database.metadata(forKey: marker) == nil else {
                return MigrationResult(alreadyCompleted: true)
            }

            let normalizedLegacy = lastWriteWins(legacyJobs)
            let normalizedAgent = lastWriteWins(agentJobs)
            let jobs = normalizedLegacy + normalizedAgent
            var result = MigrationResult(
                skippedDuplicates: legacyJobs.count + agentJobs.count - jobs.count
            )

            for source in jobs {
                let rows = try database.jobs()
                let matches = matchingRows(for: source, in: rows)
                guard let survivor = oldest(matches) else {
                    try database.upsert(source, preservingTracking: false)
                    result.inserted += 1
                    continue
                }

                let merged = merge(source: source, localRows: matches, survivor: survivor)
                for alias in matches where alias.id != survivor.id {
                    try database.delete(id: alias.id)
                }
                try database.upsert(merged, preservingTracking: false)
                result.updated += 1
            }

            try database.setMetadata("1", forKey: marker)
            return result
        }
    }

    private func decodeDefaults(_ defaults: UserDefaults, key: String) throws -> [JobApplication] {
        guard let value = defaults.object(forKey: key) else { return [] }
        guard let data = value as? Data else { throw LegacyMigrationError.invalidDefaultsData }
        do {
            return try JSONDecoder().decode([JobApplication].self, from: data)
        } catch {
            throw LegacyMigrationError.invalidDefaultsData
        }
    }

    private func decodeAgentFile(_ url: URL?) throws -> [Job] {
        guard let url else { return [] }
        let data = try Data(contentsOf: url)
        if let jobs = try? JSONDecoder().decode([Job].self, from: data) {
            return jobs
        }
        if let legacy = try? JSONDecoder().decode([JobApplication].self, from: data) {
            return legacy.map(convert)
        }
        throw LegacyMigrationError.invalidAgentJSON
    }

    private func lastWriteWins(_ jobs: [Job]) -> [Job] {
        var seen = Set<UUID>()
        return jobs.reversed().filter { seen.insert($0.id).inserted }.reversed()
    }

    private func matchingRows(for source: Job, in rows: [Job]) -> [Job] {
        var result = [Job]()
        var ids = Set<UUID>()

        func append(where predicate: (Job) -> Bool) {
            for row in rows where predicate(row) && ids.insert(row.id).inserted {
                result.append(row)
            }
        }

        if let platformID = source.platformJobID, !platformID.isEmpty {
            append { $0.platformJobID == platformID }
        }
        if let url = source.canonicalURL {
            append { $0.canonicalURL == url }
        }
        append { $0.id == source.id }
        return result
    }

    private func oldest(_ jobs: [Job]) -> Job? {
        jobs.min {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private func merge(source: Job, localRows: [Job], survivor: Job) -> Job {
        let ordered = [survivor] + localRows
            .filter { $0.id != survivor.id }
            .sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
                return $0.id.uuidString < $1.id.uuidString
            }

        var merged = source
        merged.id = survivor.id
        merged.status = ordered.max { statusRank($0.status) < statusRank($1.status) }?.status ?? survivor.status
        merged.notes = ordered.lazy.map(\.notes).first(where: { !$0.isEmpty }) ?? source.notes
        merged.appliedAt = ordered.compactMap(\.appliedAt).min()
        return merged
    }

    private func statusRank(_ status: JobStatus) -> Int {
        switch status {
        case .offer: return 9
        case .interview: return 8
        case .applied: return 7
        case .rejected: return 6
        case .archived: return 5
        case .ready: return 4
        case .preparing: return 3
        case .review: return 2
        case .new: return 1
        }
    }

    private func convert(_ item: JobApplication) -> Job {
        var job = Job(id: item.id, company: item.company, role: item.role, location: item.location)
        job.priority = item.priority
        job.isFullTime = item.fullTime
        job.workType = item.fullTime ? "Full-time" : "Part-time"
        job.matchScore = max(0, min(100, item.match))
        job.matchReason = item.matchReason
        job.notes = item.notes
        job.status = item.applied ? .applied : mapStatus(item.status)
        job.canonicalURL = item.jdURL.flatMap(URL.init(string:))
        return job
    }

    private func mapStatus(_ value: String) -> JobStatus {
        switch value.lowercased() {
        case "review": return .review
        case "preparing": return .preparing
        case "ready": return .ready
        case "applied": return .applied
        case "interview": return .interview
        case "offer": return .offer
        case "rejected": return .rejected
        case "archived": return .archived
        default: return .new
        }
    }
}
