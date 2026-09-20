# Persistence Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the prototype's split `UserDefaults`/JSON state with one tested SQLite-backed source of truth shared by the macOS app and Widget, while preserving the existing nine jobs and Westpac application state.

**Architecture:** Keep the existing SwiftUI targets and add a small shared persistence layer built directly on the system SQLite library. The app owns writes and migration; the Widget performs read-only summary queries. A one-time migrator imports legacy `UserDefaults` and bundled JSON without allowing source data to overwrite locally tracked state.

**Tech Stack:** Swift 5, SwiftUI, WidgetKit, Foundation, XCTest, system SQLite3; macOS 13+; no third-party packages.

**Spec:** `docs/superpowers/specs/2026-09-20-job-application-copilot-design.md`

## Global Constraints

- Target macOS 13 or later.
- SQLite is the only authoritative database and uses WAL mode.
- App and Widget use the same App Group container.
- Imports never overwrite local status, notes, applied date, or user-managed files.
- Existing nine jobs and Westpac's Applied state must survive migration.
- Widget performs no network, AI, browser, or document-generation work.
- Keep credentials and personal documents out of the repository.
- Use native frameworks and system SQLite; add no package dependency.

## Review Focus

- A corrupt or partially initialized database must fail visibly without replacing it; Task 3 tests rollback and reopening.
- Duplicate source rows with the same platform ID or canonical URL must merge while preserving local tracking fields; Task 4 tests both paths.
- Legacy data with duplicate UUID values must not crash dictionary construction; Task 4 tests deterministic last-write handling.
- A Widget read concurrent with an app write must return either the old or new committed snapshot, never a partial row; Task 3 tests WAL reader/writer behavior.
- Missing App Group access must produce an actionable setup error rather than silently using standard defaults or another database; Task 2 tests container resolution failure.

---

## File Structure

- `Shared/Job.swift`: domain enums and the canonical `Job` record.
- `Shared/JobDatabase.swift`: SQLite connection, schema, transactions, and typed reads/writes.
- `Shared/LegacyJobMigrator.swift`: one-time import from the prototype `JobApplication` payload.
- `Shared/WidgetSummary.swift`: minimal read model queried by WidgetKit.
- `JobApplicationWidget/ApplicationStore.swift`: `@MainActor` adapter between SwiftUI and `JobDatabase`.
- `JobApplicationWidget/ApplicationListView.swift`: existing UI updated to use typed status and store actions.
- `JobApplicationWidgetWidget/JobApplicationWidgetExtension.swift`: read-only Widget summary provider.
- `JobApplicationWidgetTests/JobDatabaseTests.swift`: persistence, rollback, and concurrent read tests.
- `JobApplicationWidgetTests/LegacyJobMigratorTests.swift`: migration and local-state-preservation tests.
- `JobApplicationWidgetTests/TestDatabase.swift`: temporary SQLite database helper.
- `JobApplicationWidget.xcodeproj/project.pbxproj`: target membership, SQLite linkage, corrected entitlements path, and test target.

### Task 1: Make the Xcode project testable and correct the Widget entitlement path

**Files:**
- Modify: `JobApplicationWidget.xcodeproj/project.pbxproj`
- Create: `JobApplicationWidgetTests/ProjectSmokeTests.swift`
- Modify: `JobApplicationWidget/JobApplicationWidget.entitlements`
- Modify: `JobApplicationWidgetWidget/JobApplicationWidgetExtension.entitlements`

**Interfaces:**
- Consumes: existing app target `JobApplicationWidget` and extension target `JobApplicationWidgetExtension`.
- Produces: XCTest target `JobApplicationWidgetTests`; shared App Group identifier `group.com.aobo.JobApplicationCopilot`; correct extension entitlement path.

- [x] **Step 1: Add the XCTest target and a smoke test**

```swift
import XCTest
@testable import JobApplicationWidget

final class ProjectSmokeTests: XCTestCase {
    func testTestTargetLoadsApplicationModule() {
        XCTAssertTrue(true)
    }
}
```

- [x] **Step 2: Run the test and verify project wiring**

Run:

```bash
xcodebuild -project JobApplicationWidget.xcodeproj -scheme JobApplicationWidget -destination 'platform=macOS' -derivedDataPath .build CODE_SIGNING_ALLOWED=NO test
```

Expected: the smoke test passes and the Widget entitlement file is found; the current malformed `JobApplicationWidget/JobApplicationWidgetWidget/...` path is absent from build settings.

- [x] **Step 3: Use one App Group value in both entitlement files**

```xml
<key>com.apple.security.application-groups</key>
<array>
    <string>group.com.aobo.JobApplicationCopilot</string>
</array>
```

Do not set `DEVELOPMENT_TEAM`; unsigned CI/local builds remain possible, and a real Apple team is selected during release provisioning.

- [x] **Step 4: Re-run tests and inspect build settings**

Run:

```bash
xcodebuild -project JobApplicationWidget.xcodeproj -scheme JobApplicationWidget -showBuildSettings | rg 'PRODUCT_BUNDLE_IDENTIFIER|CODE_SIGN_ENTITLEMENTS|MACOSX_DEPLOYMENT_TARGET'
```

Expected: macOS 13.0 for both targets, valid entitlement paths, app ID `com.aobo.JobApplicationCopilot`, extension ID `com.aobo.JobApplicationCopilot.extension`, and no remaining `com.example` identity.

This task proves the unsigned build and test path only. Before signed App Group integration, select the user's real Apple Development team and register both bundle IDs plus `group.com.aobo.JobApplicationCopilot`; keep the team selection in uncommitted local Xcode settings rather than hard-coding it in the repository.

- [x] **Step 5: Commit**

```bash
git add JobApplicationWidget.xcodeproj JobApplicationWidget JobApplicationWidgetWidget JobApplicationWidgetTests
git commit -m "build: add macOS test target and shared app group"
```

### Task 2: Define the domain model and explicit database location

**Files:**
- Create: `Shared/Job.swift`
- Create: `Shared/DatabaseLocation.swift`
- Create: `Shared/WidgetSummary.swift`
- Test: `JobApplicationWidgetTests/JobModelTests.swift`
- Test: `JobApplicationWidgetTests/DatabaseLocationTests.swift`

**Interfaces:**
- Consumes: App Group `group.com.aobo.JobApplicationCopilot`.
- Produces: `Job`, `JobStatus`, `RiskLevel`, `Eligibility`, `WidgetSummary`, and `DatabaseLocation.databaseURL(fileManager:) throws -> URL`.

- [x] **Step 1: Write failing model and location tests**

```swift
func testJobRoundTripsWithoutLosingTrackingFields() throws {
    var job = Job(company: "Westpac", role: "Data Analyst", location: "Melbourne")
    job.status = .applied
    job.notes = "Applied through Workday"
    job.appliedAt = Date(timeIntervalSince1970: 1_700_000_000)
    XCTAssertEqual(try JSONDecoder().decode(Job.self, from: JSONEncoder().encode(job)), job)
}

func testMissingAppGroupThrows() {
    XCTAssertThrowsError(try DatabaseLocation(appGroupID: "invalid.group").databaseURL())
}
```

- [x] **Step 2: Run tests and confirm missing types fail compilation**

Run:

```bash
xcodebuild -project JobApplicationWidget.xcodeproj -scheme JobApplicationWidget -destination 'platform=macOS' -derivedDataPath .build CODE_SIGNING_ALLOWED=NO test
```

Expected: FAIL because `Job` and `DatabaseLocation` do not exist.

- [x] **Step 3: Add the minimum typed model**

```swift
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

struct WidgetSummary: Equatable {
    let openCount: Int
    let topJobs: [Job]
    let refreshedAt: Date?
}
```

`DatabaseLocation` calls only `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`, appends `Library/Application Support/JobApplicationCopilot/jobs.sqlite3`, and throws if the container is unavailable. It must not fall back to `UserDefaults.standard` or a hard-coded home path.

- [x] **Step 4: Run model/location tests**

Expected: PASS, including the explicit missing-container failure.

- [x] **Step 5: Commit**

```bash
git add Shared/Job.swift Shared/DatabaseLocation.swift Shared/WidgetSummary.swift JobApplicationWidgetTests
git commit -m "feat: define job domain model and database location"
```

### Task 3: Add a transactional SQLite store

**Files:**
- Create: `Shared/JobDatabase.swift`
- Modify: `JobApplicationWidget.xcodeproj/project.pbxproj`
- Test: `JobApplicationWidgetTests/JobDatabaseTests.swift`
- Modify: `JobApplicationWidgetTests/TestDatabase.swift`

**Interfaces:**
- Consumes: `Job`, database URL.
- Produces: `JobDatabase.init(url:mode:) throws`, `migrate() throws`, `jobs() throws -> [Job]`, `upsert(_:preservingTracking:) throws`, `withTransaction(_:) throws`, metadata reads/writes, `setStatus(id:status:at:) throws`, and `summary(limit:) throws -> WidgetSummary`.

- [x] **Step 1: Write failing CRUD, rollback, and WAL tests**

```swift
func testUpsertRoundTripsJob() throws {
    let db = try TestDatabase.open()
    let job = Job(company: "Westpac", role: "Analyst", location: "Melbourne")
    try db.upsert(job, preservingTracking: true)
    XCTAssertEqual(try db.jobs(), [job])
}

func testFailedTransactionLeavesPreviousRowUntouched() throws {
    let db = try TestDatabase.open()
    let job = Job(company: "Westpac", role: "Analyst", location: "Melbourne")
    try db.upsert(job, preservingTracking: true)
    XCTAssertThrowsError(try db.withTransaction { throw TestError.expected })
    XCTAssertEqual(try db.jobs().first?.company, "Westpac")
}

func testReaderSeesCommittedSnapshotDuringWriterTransaction() throws {
    let pair = try TestDatabase.openPair()
    try pair.writer.withTransaction {
        try pair.writer.upsert(Job(company: "A", role: "B", location: "C"), preservingTracking: true)
        XCTAssertTrue(try pair.reader.jobs().isEmpty)
    }
    XCTAssertEqual(try pair.reader.jobs().count, 1)
}

func testReadOnlyConnectionCannotCreateOrMigrate() throws {
    let missingURL = TestDatabase.uniqueURL()
    XCTAssertThrowsError(try JobDatabase(url: missingURL, mode: .readOnly))
    XCTAssertFalse(FileManager.default.fileExists(atPath: missingURL.path))
}

func testNestedWriteInsideExplicitTransactionCommitsOnce() throws {
    let db = try TestDatabase.open()
    try db.withTransaction {
        try db.upsert(Job(company: "A", role: "B", location: "C"), preservingTracking: true)
        try db.setMetadata("value", forKey: "key")
    }
    XCTAssertEqual(try db.metadata(forKey: "key"), "value")
}
```

- [x] **Step 2: Run focused tests and verify failure**

Run:

```bash
xcodebuild -project JobApplicationWidget.xcodeproj -scheme JobApplicationWidget -destination 'platform=macOS' -derivedDataPath .build CODE_SIGNING_ALLOWED=NO -only-testing:JobApplicationWidgetTests/JobDatabaseTests test
```

Expected: FAIL because `JobDatabase` is undefined.

- [x] **Step 3: Link system SQLite and implement one connection wrapper**

Use `libsqlite3.tbd`. `.readWrite` opens with `SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX`, enables WAL, and migrates. `.readOnly` opens with `SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX`; it never creates files, changes journal mode, or runs schema migration.

The read-write schema is:

```sql
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;
PRAGMA busy_timeout=5000;
CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS jobs (
  id TEXT PRIMARY KEY,
  company TEXT NOT NULL,
  role TEXT NOT NULL,
  location TEXT NOT NULL,
  priority INTEGER NOT NULL,
  work_type TEXT,
  is_full_time INTEGER,
  status TEXT NOT NULL,
  notes TEXT NOT NULL,
  applied_at REAL,
  published_at REAL,
  deadline REAL,
  match_score INTEGER CHECK(match_score BETWEEN 0 AND 100),
  match_reason TEXT NOT NULL,
  risk TEXT NOT NULL,
  eligibility TEXT NOT NULL,
  canonical_url TEXT,
  platform_job_id TEXT,
  updated_at REAL NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS jobs_platform_id ON jobs(platform_job_id) WHERE platform_job_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS jobs_canonical_url ON jobs(canonical_url) WHERE canonical_url IS NOT NULL;
```

Keep SQL binding and row decoding private in this file. Public writes call one transaction helper that starts `BEGIN IMMEDIATE` only when no explicit transaction is active; writes inside `withTransaction` reuse the active transaction. The outermost transaction alone commits or rolls back, and every error includes the SQLite message.

- [x] **Step 4: Run focused and full tests**

Expected: CRUD, rollback, WAL concurrency, read-only mode, nested writes, metadata, invalid score, and reopening tests pass.

- [x] **Step 5: Commit**

```bash
git add Shared/JobDatabase.swift JobApplicationWidget.xcodeproj JobApplicationWidgetTests
git commit -m "feat: add transactional SQLite job store"
```

### Task 4: Migrate prototype data without losing local tracking state

**Files:**
- Modify: `Shared/ApplicationModel.swift`
- Create: `Shared/LegacyJobMigrator.swift`
- Test: `JobApplicationWidgetTests/LegacyJobMigratorTests.swift`
- Modify: `data/jobs.json`

**Interfaces:**
- Consumes: legacy `[JobApplication]`, optional agent JSON, `JobDatabase`.
- Produces: `LegacyJobMigrator.migrateIfNeeded(defaults:agentJSONURL:database:) throws -> MigrationResult` and migration marker `legacy-v1-complete` stored in SQLite metadata.

- [x] **Step 1: Write failing preservation and duplicate tests**

```swift
func testMigrationPreservesAppliedWestpacAndAllNineJobs() throws {
    let db = try TestDatabase.open()
    let legacy = Fixtures.nineJobsWithAppliedWestpac
    let result = try LegacyJobMigrator().migrate(legacy: legacy, agent: [], into: db)
    XCTAssertEqual(result.inserted, 9)
    XCTAssertEqual(try db.jobs().count, 9)
    XCTAssertEqual(try db.jobs().first { $0.company == "Westpac" }?.status, .applied)
}

func testAgentRefreshCannotOverwriteLocalTracking() throws {
    let db = try TestDatabase.open()
    try db.upsert(Fixtures.appliedWestpac, preservingTracking: true)
    try LegacyJobMigrator().migrate(legacy: [], agent: [Fixtures.newWestpacSource], into: db)
    let saved = try XCTUnwrap(try db.jobs().first)
    XCTAssertEqual(saved.status, .applied)
    XCTAssertEqual(saved.notes, Fixtures.appliedWestpac.notes)
}

func testDuplicateLegacyUUIDDoesNotCrash() throws {
    let db = try TestDatabase.open()
    let result = try LegacyJobMigrator().migrate(legacy: Fixtures.duplicateIDs, agent: [], into: db)
    XCTAssertEqual(result.skippedDuplicates, 1)
}

func testPlatformIDAndCanonicalURLCollisionUsesOneSurvivor() throws {
    let db = try TestDatabase.open()
    try Fixtures.insertCrossKeyCollision(into: db)
    try LegacyJobMigrator().migrate(legacy: [], agent: [Fixtures.jobMatchingBothRows], into: db)
    XCTAssertEqual(try db.jobs().count, 1)
    XCTAssertEqual(try db.jobs().first?.status, .applied)
}

func testFailedMigrationRollsBackRowsAndMarker() throws {
    let db = try TestDatabase.open()
    XCTAssertThrowsError(try LegacyJobMigrator().migrate(legacy: Fixtures.failsMidImport, agent: [], into: db))
    XCTAssertTrue(try db.jobs().isEmpty)
    XCTAssertNil(try db.metadata(forKey: "legacy-v1-complete"))
}
```

- [x] **Step 2: Run focused tests and verify failure**

Expected: FAIL because `LegacyJobMigrator` is undefined.

- [x] **Step 3: Implement one-time migration**

Map `applied == true` to `.applied`, otherwise map known legacy strings and default unknown strings to `.new`. Preserve priority, full-time/work type, match score, match reason, status, notes, and URL; clamp legacy match values to `0...100`.

Resolve duplicates inside one transaction in order: platform ID, canonical URL, then UUID. If platform ID and URL match different rows, choose the oldest local row as survivor, copy the strongest local tracking state (`offer`/`interview`/`applied` before pre-application states), keep non-empty notes and applied date, repoint imported source data to the survivor, then delete the alias row. Insert seed records only when neither legacy defaults nor database rows exist. Write `legacy-v1-complete` to the Task 3 metadata table in the same transaction; any row or marker failure rolls back the entire import.

- [x] **Step 4: Run migration tests twice**

The second migration must report `alreadyCompleted == true` and leave row count, IDs, status, notes, and dates unchanged.

- [x] **Step 5: Commit**

```bash
git add Shared/ApplicationModel.swift Shared/LegacyJobMigrator.swift JobApplicationWidgetTests data/jobs.json
git commit -m "feat: migrate legacy application tracking to SQLite"
```

### Task 5: Move the app and Widget onto the shared database

**Files:**
- Create: `JobApplicationWidget/ApplicationStore.swift`
- Modify: `JobApplicationWidget/ApplicationListView.swift`
- Modify: `JobApplicationWidget/JobApplicationWidgetApp.swift`
- Modify: `JobApplicationWidgetWidget/JobApplicationWidgetExtension.swift`
- Modify: `README.md`
- Test: `JobApplicationWidgetTests/ApplicationStoreTests.swift`

**Interfaces:**
- Consumes: `JobDatabase`, `Job`, `WidgetSummary`.
- Produces: `ApplicationStore.reload()`, `ApplicationStore.setStatus(_:for:)`, and read-only Widget timeline entries.

- [ ] **Step 1: Write failing store behavior tests**

```swift
@MainActor
func testSettingAppliedPersistsAndReloads() throws {
    let db = try TestDatabase.open()
    let job = Job(company: "Westpac", role: "Analyst", location: "Melbourne")
    try db.upsert(job, preservingTracking: true)
    let store = try ApplicationStore(database: db)
    try store.setStatus(.applied, for: job.id)
    XCTAssertEqual(try ApplicationStore(database: db).jobs.first?.status, .applied)
}

@MainActor
func testDatabaseFailureIsExposedToUI() {
    let store = ApplicationStore(failingWith: TestError.expected)
    XCTAssertNotNil(store.errorMessage)
    XCTAssertTrue(store.jobs.isEmpty)
}
```

- [ ] **Step 2: Run store tests and verify failure**

Expected: FAIL because the new injected-database initializer and typed status API do not exist.

- [ ] **Step 3: Replace implicit prototype storage with the injected store**

`ApplicationStore` loads once from `JobDatabase`, publishes `[Job]`, writes explicit user actions, and surfaces errors. Remove the hard-coded repository path and `UserDefaults.standard` fallback. `JobApplicationWidgetApp` constructs the database once and injects the store into the view.

- [ ] **Step 4: Make the Widget query only its summary**

The provider opens the shared database read-only, calls `summary(limit: 3)`, and returns an empty/error-safe entry if the container is unavailable. It does not fall back to hard-coded sample jobs outside preview mode. Use `.after(.now.addingTimeInterval(3600))`; the future Worker phase will explicitly reload Widget timelines after database writes.

- [ ] **Step 5: Build, test, and manually launch**

Run:

```bash
xcodebuild -project JobApplicationWidget.xcodeproj -scheme JobApplicationWidget -destination 'platform=macOS' -derivedDataPath .build CODE_SIGNING_ALLOWED=NO test
xcodebuild -project JobApplicationWidget.xcodeproj -scheme JobApplicationWidget -configuration Debug -sdk macosx -derivedDataPath .build CODE_SIGNING_ALLOWED=NO build
```

Expected: all tests pass; unsigned app and extension build; the app shows migrated jobs and changing Westpac's status persists across relaunch.

- [ ] **Step 6: Update the README data contract**

Document SQLite as authoritative, JSON as import/backup only, the App Group requirement, unsigned build command, and the fact that Outlook/search/AI are not part of this foundation increment.

- [ ] **Step 7: Commit**

```bash
git add JobApplicationWidget Shared JobApplicationWidgetWidget JobApplicationWidgetTests README.md
git commit -m "feat: use shared SQLite state in app and widget"
```

## Follow-on Plans

After this plan is green, write and review these plans in order:

1. `worker-scheduling-and-checkpoints`: launchd trigger, event-driven network stability, sleep handling, run lock, checkpoints, and JSON backups.
2. `outlook-and-job-ingestion`: Graph `Mail.Read`, Deleted Items cursor, source adapters, normalization, deduplication, and open-state checks.
3. `risk-eligibility-and-matching`: scam evidence, PR/citizenship rules, weighted matching, Codex schemas, and quota/auth errors.
4. `application-documents`: verified facts, one-time confirmation, DOCX/PDF output, versioning, two-page/one-page checks, and five-pack daily cap.
5. `product-ui-and-release`: three-column window, menu bar, Widget families/deep links, Chrome Apply, onboarding, notifications, accessibility, signing, and energy/security acceptance.

Each follow-on plan must leave the app usable if later phases are not yet installed.
