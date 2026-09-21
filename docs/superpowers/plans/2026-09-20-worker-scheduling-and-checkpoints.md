# Worker Scheduling and Checkpoints Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a low-power macOS worker that runs once after 08:00 Melbourne time when the network is stably usable, pauses safely for sleep or network loss, resumes from SQLite checkpoints, rejects concurrent Fetch/automatic runs, and writes rolling JSON backups.

**Architecture:** Add one bundled Swift command-line executable, `JobScoutWorker`, driven by a small coordinator whose time, reachability, power events, HTTPS probes, and work performer are injected in tests. `launchd` starts it only at login and at the 08:00 calendar event; while a due run is offline, one `NWPathMonitor` plus one-shot timers wait for events without polling. SQLite remains authoritative and gains only a `runs` table and schema version 2; checkpoints and success state live there, while atomic JSON exports are recovery backups only.

**Tech Stack:** Swift 5, Foundation, AppKit workspace notifications, Network.framework, SQLite3, Darwin `flock`, XCTest, `launchd`; macOS 13+; no third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-09-20-job-application-copilot-design.md`

## Global Constraints

- Target macOS 13 or later; keep the existing App Group `group.com.aobo.JobApplicationCopilot`.
- `launchd` uses only `RunAtLoad` and `StartCalendarInterval` at 08:00; never add `StartInterval`, `ThrottleInterval` as a polling mechanism, or a 15-minute loop.
- Use the explicit `Australia/Melbourne` time zone for the daily boundary and 08:00 due calculation, independent of the Mac's current time zone.
- Waiting for connectivity uses `NWPathMonitor` events and cancellable one-shot timers only; no fixed polling loop.
- Require 60 continuous seconds of a satisfied path, followed by two successful lightweight HTTPS requests separated by 3 seconds; any path loss or sleep resets the gate.
- Sleep stops HTTPS/business network tasks and child processes after saving a checkpoint; wake always re-enters network validation before work resumes.
- Manual Fetch uses force mode: it bypasses only the “today already succeeded” check, never the sleep, network, probe, or file-lock gates.
- A non-blocking file lock prevents automatic and manual processes from running concurrently.
- SQLite remains the only source of truth. JSON files are atomic backups, never runtime input, and only the newest 30 successful backups remain.
- The network waiter must not read email or job business tables and must not launch Chrome, Codex, or future ingestion stages.
- Do not use power assertions, scheduled wake APIs, busy waits, or new package dependencies.
- This increment does not implement Outlook, source collection, browser automation, Codex, matching, or document generation.

## Review Focus

- A satisfied path that drops at second 59 must reset the full 60-second window and must not launch work; Task 3 tests this with a virtual clock.
- Sleep during a probe or work stage must checkpoint before cancellation, terminate registered processes/tasks, and require a fresh 60-second gate after wake; Tasks 4 and 5 test the ordering.
- Automatic and force runs started together must yield exactly one lock owner and no second `runs` row; Task 2 tests this with two lock handles and Task 5 tests coordinator behavior.
- A schema-1 database with jobs must upgrade atomically to schema 2 without altering jobs; an upgrade failure must leave version 1 and no partial `runs` table; Task 1 tests both paths.
- A backup write or prune failure must fail the run visibly without replacing an older backup or deleting more than the oldest files beyond 30; Task 6 tests atomicity and retention.

---

## File Structure

- `Shared/RunRecord.swift`: run trigger/status/checkpoint value types and Melbourne daily schedule policy.
- `Shared/JobDatabase.swift`: schema 1→2 migration and typed run/checkpoint queries; existing job APIs remain unchanged.
- `Shared/WorkerPaths.swift`: App Group-derived lock, backup, and launch-agent paths; no home/repository fallback.
- `Shared/WorkerLock.swift`: one non-blocking `flock` wrapper.
- `Shared/NetworkGate.swift`: pure stability state machine plus `NWPathMonitor`/HTTPS runtime adapter.
- `Shared/PowerEvents.swift`: sleep/wake event protocol and `NSWorkspace` implementation.
- `Shared/WorkerResources.swift`: registry that cancels URL tasks and terminates child processes.
- `Shared/WorkerCoordinator.swift`: due/force checks, lock, run lifecycle, checkpoint, cancellation, resume, and backup orchestration.
- `Shared/JSONBackupWriter.swift`: atomic jobs export and newest-30 retention.
- `Shared/LaunchAgentInstaller.swift`: deterministic plist generation and install/update operations.
- `JobScoutWorker/main.swift`: production composition root and `--scheduled`/`--force` parsing.
- `JobScoutWorker/JobScoutWorker.entitlements`: the same App Group entitlement as the app.
- `JobApplicationWidget/FetchController.swift`: launches the bundled worker with `--force` and exposes launch errors.
- `JobApplicationWidget/JobApplicationWidgetApp.swift`: installs/updates the launch agent and injects Fetch state.
- `JobApplicationWidget/ApplicationListView.swift`: Fetch button and scheduling/launch error display.
- `JobApplicationWidget.xcodeproj/project.pbxproj`: worker target, helper embedding, frameworks, entitlements, and memberships.
- `JobApplicationWidgetTests/*Tests.swift`: schema, schedule, lock, network, coordinator, backup, plist, and Fetch tests.
- `README.md`: scheduling behavior, installation, logs, and explicit non-goals.

### Task 1: Upgrade SQLite to schema 2 and add run/checkpoint records

**Files:**
- Create: `Shared/RunRecord.swift`
- Modify: `Shared/JobDatabase.swift`
- Modify: `JobApplicationWidget.xcodeproj/project.pbxproj`
- Test: `JobApplicationWidgetTests/RunDatabaseTests.swift`
- Modify: `JobApplicationWidgetTests/TestDatabase.swift`

**Interfaces:**
- Consumes: `JobDatabase.init(url:mode:)`, its existing transaction and binding helpers, and schema version 1.
- Produces: `RunTrigger`, `RunStatus`, `RunRecord`, `MelbourneSchedule`, `JobDatabase.createRun(trigger:localDay:at:)`, `saveCheckpoint(runID:stage:payload:at:)`, `finishRun(id:status:error:at:)`, `hasSuccessfulRun(localDay:)`, and `latestResumableRun(localDay:)`.

- [x] **Step 1: Write failing schedule and schema-upgrade tests**

```swift
func testMelbourneScheduleUsesEightAMAcrossDST() throws {
    let policy = MelbourneSchedule()
    let beforeDSTEnd = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-04-04T21:30:00Z"))
    XCTAssertEqual(policy.localDay(at: beforeDSTEnd), "2026-04-05")
    XCTAssertTrue(policy.isDue(at: beforeDSTEnd)) // 08:30 Melbourne
}

func testVersionOneDatabaseUpgradesWithoutChangingJobs() throws {
    let fixture = try TestDatabase.openVersionOne()
    let before = try fixture.database.jobs()
    try fixture.database.migrate()
    XCTAssertEqual(try fixture.database.schemaVersion(), 2)
    XCTAssertEqual(try fixture.database.jobs(), before)
}

func testFailedUpgradeLeavesVersionOneAndNoRunsTable() throws {
    let fixture = try TestDatabase.openVersionOneWithUpgradeConflict()
    XCTAssertThrowsError(try fixture.database.migrate())
    XCTAssertEqual(try fixture.rawSchemaVersion(), 1)
    XCTAssertFalse(try fixture.tableExists("runs"))
}
```

- [x] **Step 2: Run the focused tests and verify they fail**

Run:

```bash
xcodebuild -project JobApplicationWidget.xcodeproj -scheme JobApplicationWidget \
  -destination 'platform=macOS' -derivedDataPath .build CODE_SIGNING_ALLOWED=NO \
  -only-testing:JobApplicationWidgetTests/RunDatabaseTests test
```

Expected: FAIL because `RunRecord`, `MelbourneSchedule`, and schema version 2 do not exist.

- [x] **Step 3: Define the minimum run model and schedule policy**

```swift
enum RunTrigger: String, Codable { case scheduled, manual }
enum RunStatus: String, Codable {
    case waitingForNetwork, running, suspended, succeeded, failed
}

struct RunRecord: Identifiable, Equatable {
    let id: UUID
    let trigger: RunTrigger
    let localDay: String
    var status: RunStatus
    var checkpointStage: String?
    var checkpointPayload: Data?
    var startedAt: Date
    var finishedAt: Date?
    var error: String?
    var updatedAt: Date
}

struct MelbourneSchedule {
    static let timeZone = TimeZone(identifier: "Australia/Melbourne")!
    func localDay(at date: Date) -> String
    func isDue(at date: Date) -> Bool
}
```

Use a Gregorian `Calendar` pinned to `Australia/Melbourne`; format `localDay` as `yyyy-MM-dd` with a POSIX locale. `isDue` returns true at or after local 08:00.

- [x] **Step 4: Replace the one-version migration with an atomic 1→2 migration**

Schema 2 adds only:

```sql
CREATE TABLE runs (
  id TEXT PRIMARY KEY,
  trigger TEXT NOT NULL CHECK(trigger IN ('scheduled','manual')),
  local_day TEXT NOT NULL,
  status TEXT NOT NULL CHECK(status IN ('waitingForNetwork','running','suspended','succeeded','failed')),
  checkpoint_stage TEXT,
  checkpoint_json BLOB,
  started_at REAL NOT NULL,
  finished_at REAL,
  error TEXT,
  updated_at REAL NOT NULL
);
CREATE INDEX runs_local_day_status ON runs(local_day, status);
UPDATE schema_version SET version = 2 WHERE version = 1;
```

On a new database, create the existing jobs/metadata schema and `runs` in one transaction and insert version 2. On version 1, create `runs` and update the single version row in one transaction. Accept exactly `[2]` after migration; reject empty, duplicate, zero, or future versions. Do not drop or replace the database on failure.

- [x] **Step 5: Add typed run/checkpoint tests and APIs**

```swift
func testCheckpointRoundTripsAndLatestIncompleteRunResumes() throws {
    let db = try TestDatabase.open()
    let id = try db.createRun(trigger: .scheduled, localDay: "2026-09-20", at: .test0)
    let payload = try JSONEncoder().encode(["cursor": "mail-42"])
    try db.saveCheckpoint(runID: id, stage: "outlook", payload: payload, at: .test1)
    XCTAssertEqual(try db.latestResumableRun(localDay: "2026-09-20")?.checkpointPayload, payload)
}

func testOnlySucceededRunSatisfiesDailyGate() throws {
    let db = try TestDatabase.open()
    let id = try db.createRun(trigger: .scheduled, localDay: "2026-09-20", at: .test0)
    try db.finishRun(id: id, status: .failed, error: "offline", at: .test1)
    XCTAssertFalse(try db.hasSuccessfulRun(localDay: "2026-09-20"))
    let retry = try db.createRun(trigger: .scheduled, localDay: "2026-09-20", at: .test1)
    try db.finishRun(id: retry, status: .succeeded, error: nil, at: .test2)
    XCTAssertTrue(try db.hasSuccessfulRun(localDay: "2026-09-20"))
}
```

Validate checkpoint payload with `JSONSerialization.jsonObject(with:)` before binding. Decode rows without force unwraps and distinguish `SQLITE_DONE` from step errors, matching existing `JobDatabase` safety rules.

- [x] **Step 6: Run focused and full persistence tests**

Run the focused command from Step 2, then:

```bash
xcodebuild -project JobApplicationWidget.xcodeproj -scheme JobApplicationWidget \
  -destination 'platform=macOS' -derivedDataPath .build CODE_SIGNING_ALLOWED=NO test
```

Expected: schema-1 upgrade, rollback, checkpoint, success-gate, existing job, migration, and store tests all PASS.

- [x] **Step 7: Commit**

```bash
git add Shared/RunRecord.swift Shared/JobDatabase.swift \
  JobApplicationWidgetTests/RunDatabaseTests.swift JobApplicationWidgetTests/TestDatabase.swift \
  JobApplicationWidget.xcodeproj/project.pbxproj
git commit -m "feat: persist worker runs and checkpoints"
```

### Task 2: Add App Group worker paths and a non-blocking process lock

**Files:**
- Create: `Shared/WorkerPaths.swift`
- Create: `Shared/WorkerLock.swift`
- Modify: `JobApplicationWidget.xcodeproj/project.pbxproj`
- Test: `JobApplicationWidgetTests/WorkerLockTests.swift`

**Interfaces:**
- Consumes: an App Group container URL from `DatabaseLocation`.
- Produces: `WorkerPaths.init(containerURL:)`, `lockURL`, `backupDirectoryURL`, `launchAgentPlistURL`, and `WorkerLock.acquire(url:) throws -> WorkerLock?`.

- [x] **Step 1: Write failing path and exclusion tests**

```swift
func testPathsStayInsideInjectedContainer() {
    let root = URL(fileURLWithPath: "/tmp/test-group")
    let paths = WorkerPaths(containerURL: root)
    XCTAssertEqual(paths.lockURL, root.appendingPathComponent("Library/Application Support/JobApplicationCopilot/worker.lock"))
    XCTAssertEqual(paths.backupDirectoryURL, root.appendingPathComponent("Library/Application Support/JobApplicationCopilot/Backups"))
}

func testOnlyOneHandleCanOwnWorkerLock() throws {
    let url = TestDatabase.uniqueURL().appendingPathExtension("lock")
    let first = try XCTUnwrap(WorkerLock.acquire(url: url))
    XCTAssertNil(try WorkerLock.acquire(url: url))
    first.unlock()
    XCTAssertNotNil(try WorkerLock.acquire(url: url))
}
```

- [x] **Step 2: Run tests and verify missing types fail compilation**

Run the full test command from Task 1.

Expected: FAIL because `WorkerPaths` and `WorkerLock` do not exist.

- [x] **Step 3: Implement the minimum lock wrapper**

Use `open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)` and `flock(fd, LOCK_EX | LOCK_NB)`. Return `nil` only for `EWOULDBLOCK`; throw an error containing `errno` and the path for every other failure. Hold the descriptor for the wrapper lifetime, and make `unlock()` idempotently call `flock(fd, LOCK_UN)` and `close(fd)`.

Do not put the lock in `/tmp`, the repository, or a hard-coded home directory. Production constructs all paths from `DatabaseLocation().databaseURL().deletingLastPathComponent()` or the resolved App Group container.

- [x] **Step 4: Run lock tests, including concurrent acquisition**

Add a test that starts 20 concurrent acquisition attempts behind a barrier and asserts exactly one non-nil owner. Release all successful handles at the end of the test.

Expected: PASS under repeated execution (`-test-iterations 10`).

- [x] **Step 5: Commit**

```bash
git add Shared/WorkerPaths.swift Shared/WorkerLock.swift \
  JobApplicationWidgetTests/WorkerLockTests.swift JobApplicationWidget.xcodeproj/project.pbxproj
git commit -m "feat: add worker paths and run lock"
```

### Task 3: Implement event-driven network stability and HTTPS validation

**Files:**
- Create: `Shared/NetworkGate.swift`
- Modify: `JobApplicationWidget.xcodeproj/project.pbxproj`
- Test: `JobApplicationWidgetTests/NetworkGateTests.swift`

**Interfaces:**
- Consumes: `NWPathMonitor` satisfied/unsatisfied events, sleep/wake events from Task 4, a clock, and an HTTPS requester.
- Produces: `NetworkGateEvent`, `NetworkStabilityState`, `NetworkStabilityMachine.handle(_:now:)`, and production `NetworkGate.waitUntilUsable() async throws` / `reset()` / `cancel()`.

- [x] **Step 1: Write failing pure state-machine tests**

```swift
func testPathDropAtSecondFiftyNineRestartsFullWindow() {
    var machine = NetworkStabilityMachine(stableInterval: 60)
    XCTAssertEqual(machine.handle(.pathSatisfied, now: 0), .arm(deadline: 60))
    XCTAssertEqual(machine.handle(.pathUnsatisfied, now: 59), .cancelTimer)
    XCTAssertEqual(machine.handle(.pathSatisfied, now: 60), .arm(deadline: 120))
    XCTAssertEqual(machine.handle(.timerFired, now: 119), .none)
    XCTAssertEqual(machine.handle(.timerFired, now: 120), .beginProbes)
}

func testSleepAndWakeResetSatisfiedPath() {
    var machine = NetworkStabilityMachine(stableInterval: 60)
    _ = machine.handle(.pathSatisfied, now: 0)
    XCTAssertEqual(machine.handle(.sleep, now: 30), .cancelAll)
    XCTAssertEqual(machine.handle(.wake, now: 100), .awaitPathEvent)
}
```

- [x] **Step 2: Run focused tests and verify failure**

Run:

```bash
xcodebuild -project JobApplicationWidget.xcodeproj -scheme JobApplicationWidget \
  -destination 'platform=macOS' -derivedDataPath .build CODE_SIGNING_ALLOWED=NO \
  -only-testing:JobApplicationWidgetTests/NetworkGateTests test
```

Expected: FAIL because the gate types do not exist.

- [x] **Step 3: Implement the pure state machine and one-shot timer adapter**

The state machine has only `offline`, `stabilizing(deadline)`, `probing`, and `ready`. Repeated satisfied events while stabilizing do not extend the deadline. Unsatisfied, sleep, and explicit reset cancel the current one-shot `DispatchSourceTimer` and any probes. The runtime adapter starts one `NWPathMonitor` on a serial queue; it never schedules repeating timers.

- [x] **Step 4: Add two sequential HTTPS probes**

Define the narrow seam:

```swift
protocol HTTPSRequesting {
    func statusCode(for url: URL) async throws -> Int
}

struct ProbePolicy {
    let urls: [URL] // production supplies exactly two lightweight HTTPS URLs
    let delayBetweenProbes: TimeInterval // 3
    func accepts(_ status: Int) -> Bool { (200...399).contains(status) }
}
```

Production uses ephemeral `URLSessionConfiguration`, `waitsForConnectivity = false`, a 10-second request/resource timeout, no credentials, and a GET whose body is discarded. Use the same two fixed, documented endpoints in tests through a fake requester; never probe email, SQLite business content, Chrome, or Codex.

- [x] **Step 5: Test probe failures and cancellation**

```swift
func testTwoSuccessfulProbesProduceReadyOnce() async throws { /* assert exactly two calls and one ready */ }
func testFirstProbeFailureReturnsToOffline() async throws { /* assert second is not called */ }
func testPathLossDuringSecondProbeCancelsAndRequiresSixtySecondsAgain() async throws { /* fake continuation */ }
```

Also assert `NWPathMonitor.start` is called once, timers are one-shot, and `cancel()` resumes any awaiting continuation exactly once with cancellation.

- [x] **Step 6: Run focused tests ten times and commit**

Run the command from Step 2 with `-test-iterations 10`.

Expected: PASS without real network access or wall-clock sleeps.

```bash
git add Shared/NetworkGate.swift JobApplicationWidgetTests/NetworkGateTests.swift \
  JobApplicationWidget.xcodeproj/project.pbxproj
git commit -m "feat: gate worker on stable network"
```

### Task 4: Observe sleep/wake and cancel owned resources

**Files:**
- Create: `Shared/PowerEvents.swift`
- Create: `Shared/WorkerResources.swift`
- Modify: `JobApplicationWidget.xcodeproj/project.pbxproj`
- Test: `JobApplicationWidgetTests/PowerAndResourceTests.swift`

**Interfaces:**
- Consumes: `NSWorkspace.willSleepNotification`, `NSWorkspace.didWakeNotification`, registered `Process` values, and registered URL-session cancellation closures.
- Produces: `PowerEventSource.events() -> AsyncStream<PowerEvent>`, `WorkerResources.register(process:)`, `registerCancellation(_:)`, and `cancelAll()`.

- [x] **Step 1: Write failing observer and cancellation tests**

```swift
func testWorkspaceNotificationsMapToPowerEvents() async throws {
    let center = NotificationCenter()
    let source = WorkspacePowerEvents(center: center)
    let recorder = EventRecorder(source.events())
    center.post(name: NSWorkspace.willSleepNotification, object: nil)
    center.post(name: NSWorkspace.didWakeNotification, object: nil)
    XCTAssertEqual(await recorder.first(2), [.willSleep, .didWake])
}

func testCancelAllTerminatesProcessAndCancelsNetworkTask() {
    let process = FakeProcess(running: true)
    var networkCancelled = false
    let resources = WorkerResources()
    resources.register(process: process)
    resources.registerCancellation { networkCancelled = true }
    resources.cancelAll()
    XCTAssertTrue(process.terminateCalled)
    XCTAssertTrue(networkCancelled)
}
```

- [x] **Step 2: Run tests and verify missing types fail compilation**

Run the full test command from Task 1.

- [x] **Step 3: Implement notification-backed events and resource ownership**

Use notification observer tokens removed when the `AsyncStream` terminates. `WorkerResources.cancelAll()` snapshots and clears its registered resources under one `NSLock`, invokes cancellation closures, calls `terminate()` on running processes, waits at most 5 seconds through termination handlers, then calls `interrupt()` only if still running. Do not kill unrelated processes or identify children by process name.

- [x] **Step 4: Add lifecycle edge tests**

Cover duplicate `cancelAll`, a process that exits before cancellation, stream termination removing observers, and registration after cancellation beginning. The last case must be cancelled immediately rather than escaping ownership.

- [x] **Step 5: Run focused tests and commit**

```bash
git add Shared/PowerEvents.swift Shared/WorkerResources.swift \
  JobApplicationWidgetTests/PowerAndResourceTests.swift JobApplicationWidget.xcodeproj/project.pbxproj
git commit -m "feat: stop worker resources for sleep"
```

### Task 5: Orchestrate scheduled, force, sleep, resume, and lock behavior

**Files:**
- Create: `Shared/WorkerCoordinator.swift`
- Modify: `JobApplicationWidget.xcodeproj/project.pbxproj`
- Test: `JobApplicationWidgetTests/WorkerCoordinatorTests.swift`

**Interfaces:**
- Consumes: `MelbourneSchedule`, `JobDatabase` run APIs, `WorkerLock`, `NetworkGate`, `PowerEventSource`, `WorkerResources`, and a `WorkerPerforming` implementation.
- Produces: `WorkerCoordinator.run(trigger:force:) async -> WorkerExit`, plus `WorkerPerforming.perform(from:checkpoint:resources:) async throws -> WorkerCheckpoint`.

`NetworkGate.waitUntilUsable()` returns a memory-backed `NetworkLease`; its `waitForInvalidation()` completes on path loss, reset, or cancellation even when invalidation happened before the listener registered. This reuses the gate's single monitor and closes the ready-to-listener race. Inject `SuccessfulRunBackupWriting` without a production no-op; Task 6 supplies its real implementation. Create a fresh one-shot `WorkerResources` for every performer attempt and keep one power-event subscription for the whole coordinator run.

- [x] **Step 1: Define the minimum performer seam and write failing due/force tests**

```swift
protocol WorkerPerforming {
    func perform(
        from checkpoint: WorkerCheckpoint?,
        save: @escaping (WorkerCheckpoint) async throws -> Void,
        resources: WorkerResources
    ) async throws
}

func testScheduledRunBeforeEightExitsWithoutRunRow() async throws { /* fixed Melbourne clock */ }
func testScheduledRunAfterExistingSuccessExitsWithoutRunRow() async throws { /* success fixture */ }
func testForceAfterExistingSuccessStillRuns() async throws { /* manual trigger, one performer call */ }
func testForceDoesNotBypassOfflineGate() async throws { /* performer remains uncalled until gate ready */ }
```

`WorkerCheckpoint` contains only `stage: String` and validated JSON `payload: Data`; future ingestion plans own the stage vocabulary.

- [x] **Step 2: Run focused tests and verify failure**

Run:

```bash
xcodebuild -project JobApplicationWidget.xcodeproj -scheme JobApplicationWidget \
  -destination 'platform=macOS' -derivedDataPath .build CODE_SIGNING_ALLOWED=NO \
  -only-testing:JobApplicationWidgetTests/WorkerCoordinatorTests test
```

- [x] **Step 3: Implement coordinator ordering exactly once**

`run(trigger:force:)` performs this order:

1. Compute Melbourne local day and due state.
2. For scheduled/non-force only, exit if before 08:00 or the day already succeeded.
3. Acquire the App Group file lock; return `.alreadyRunning` without creating a row when unavailable.
4. Re-check daily success after the lock to close the race; force skips only this check.
5. Reuse the latest resumable run for the local day, or create one `waitingForNetwork` row.
6. Subscribe to power events and await `NetworkGate.waitUntilUsable()`.
7. Mark the run `running`, call the performer, and save each performer checkpoint transactionally.
8. On success, write the JSON backup from Task 6, then mark `succeeded`.
9. On ordinary failure, save the latest checkpoint and mark `failed` with an actionable error.
10. Always cancel observers/resources and release the lock.

The coordinator never sleeps until 08:00. Before 08:00 it exits; the calendar launch is responsible for the next start.

- [x] **Step 4: Implement sleep/network interruption ordering**

On `.willSleep` or path loss while probing/running:

1. persist the most recent checkpoint and set status `suspended`;
2. call `resources.cancelAll()` and `networkGate.reset()`;
3. wait for `.didWake` when asleep;
4. call `waitUntilUsable()` again, including a new 60-second interval and both probes;
5. resume the same run ID and checkpoint.

Do not create a second run row on resume. Do not mark a suspended run failed merely because the Mac sleeps.

- [x] **Step 5: Add interruption, race, and exactly-once tests**

```swift
func testSleepCheckpointsBeforeResourcesAreCancelled() async throws { /* ordered event recorder */ }
func testWakeRequiresFreshStableWindowAndResumesSameRunID() async throws { /* one row, two gate waits */ }
func testNetworkLossDuringWorkUsesSameResumePath() async throws { /* checkpoint preserved */ }
func testManualAndScheduledRaceCreatesOneRun() async throws { /* two coordinators, shared lock URL */ }
func testStableNetworkLaunchesPerformerOnlyOnce() async throws { /* repeated satisfied events */ }
```

- [x] **Step 6: Run coordinator tests repeatedly and commit**

Run Step 2 with `-test-iterations 10`, then the full suite.

Expected: PASS without real sleep, network, subprocess, or wall-clock delays.

```bash
git add Shared/WorkerCoordinator.swift JobApplicationWidgetTests/WorkerCoordinatorTests.swift \
  JobApplicationWidget.xcodeproj/project.pbxproj
git commit -m "feat: coordinate resumable daily worker runs"
```

### Task 6: Write atomic JSON backups and retain the newest 30

**Files:**
- Create: `Shared/JSONBackupWriter.swift`
- Modify: `JobApplicationWidget.xcodeproj/project.pbxproj`
- Test: `JobApplicationWidgetTests/JSONBackupWriterTests.swift`

**Interfaces:**
- Consumes: `JobDatabase.jobs()`, an App Group backup directory, a run ID, and a clock.
- Produces: `JSONBackupWriter.writeSuccessfulBackup(database:runID:at:) throws -> URL` and `pruneKeepingNewest(_:)`.

- [x] **Step 1: Write failing content, atomicity, and retention tests**

```swift
func testBackupContainsCurrentJobsAndRunMetadata() throws {
    let fixture = try BackupFixture()
    let url = try fixture.writer.writeSuccessfulBackup(database: fixture.db, runID: fixture.runID, at: .test0)
    let decoded = try JSONDecoder().decode(JobBackup.self, from: Data(contentsOf: url))
    XCTAssertEqual(decoded.schemaVersion, 1)
    XCTAssertEqual(decoded.jobs, try fixture.db.jobs())
}

func testThirtyFirstBackupDeletesOnlyOldestCompletedFile() throws { /* fixed timestamps, assert 30 remain */ }
func testEncodingOrMoveFailureLeavesPreviousBackupUntouched() throws { /* injected FileManager operations */ }
```

- [x] **Step 2: Run focused tests and verify failure**

Run the full test command; expect missing backup types.

- [x] **Step 3: Implement one Codable envelope and atomic replacement**

```swift
struct JobBackup: Codable, Equatable {
    let schemaVersion: Int // backup format version, initially 1
    let runID: UUID
    let createdAt: Date
    let jobs: [Job]
}
```

Encode with sorted keys and ISO-8601 dates. Write to a sibling temporary file with owner-only permissions, call `FileHandle.synchronize()`, then atomically rename to `jobs-<UTC timestamp>-<runID>.json`. Enumerate only files matching that exact prefix/suffix, sort by creation timestamp encoded in the name, and delete the excess oldest files only after the new file is durable. A failure propagates to the coordinator and must not mark the run succeeded.

- [x] **Step 4: Run backup tests and inspect permissions**

Assert 30 files remain, the newest exists, unrelated files remain, no `.tmp` file remains after success, and the final mode is `0600`.

- [x] **Step 5: Commit**

```bash
git add Shared/JSONBackupWriter.swift JobApplicationWidgetTests/JSONBackupWriterTests.swift \
  JobApplicationWidget.xcodeproj/project.pbxproj
git commit -m "feat: export rolling JSON backups"
```

### Task 7: Add the worker executable and launchd calendar/login registration

**Files:**
- Create: `JobScoutWorker/main.swift`
- Create: `JobScoutWorker/JobScoutWorker.entitlements`
- Create: `Shared/LaunchAgentInstaller.swift`
- Modify: `JobApplicationWidget.xcodeproj/project.pbxproj`
- Test: `JobApplicationWidgetTests/LaunchAgentInstallerTests.swift`
- Test: `JobApplicationWidgetTests/WorkerCommandTests.swift`

**Interfaces:**
- Consumes: production implementations from Tasks 1–6 and an absolute bundled worker executable URL.
- Produces: executable arguments `--scheduled` and `--force`, `LaunchAgentInstaller.install(workerURL:)`, and label `com.aobo.JobApplicationCopilot.worker`.

- [ ] **Step 1: Write failing command and plist tests**

```swift
func testLaunchAgentHasOnlyLoginAndEightAMTriggers() throws {
    let plist = try LaunchAgentInstaller.makePlist(workerURL: URL(fileURLWithPath: "/Applications/Test.app/Contents/Helpers/job-scout"))
    XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
    XCTAssertEqual((plist["StartCalendarInterval"] as? [String: Int])?["Hour"], 8)
    XCTAssertEqual((plist["StartCalendarInterval"] as? [String: Int])?["Minute"], 0)
    XCTAssertNil(plist["StartInterval"])
    XCTAssertNil(plist["KeepAlive"])
}

func testForceArgumentMapsOnlyToManualForceTrigger() throws {
    XCTAssertEqual(try WorkerCommand(arguments: ["job-scout", "--force"]), .run(trigger: .manual, force: true))
    XCTAssertEqual(try WorkerCommand(arguments: ["job-scout", "--scheduled"]), .run(trigger: .scheduled, force: false))
}
```

- [ ] **Step 2: Run tests and verify missing types fail compilation**

Run the full suite.

- [ ] **Step 3: Add the command-line target and production composition root**

Add a macOS command-line target named `JobScoutWorker`, bundle identifier `com.aobo.JobApplicationCopilot.worker`, deployment target 13.0, SQLite3 linkage, Network/AppKit frameworks, and the App Group entitlement. Include only the shared model/database/worker files needed by the executable; do not include SwiftUI views, the Widget provider, or legacy migration.

`main.swift` parses exactly one mode, resolves the App Group location, builds the lock/gate/power/coordinator/backup dependencies, runs the coordinator, logs one structured line per state transition with `Logger`, and exits nonzero only for actionable failure. The production performer for this increment saves a `foundation-backup` checkpoint and performs no email, Chrome, Codex, or ingestion work.

- [ ] **Step 4: Generate and install the LaunchAgent without polling keys**

`LaunchAgentInstaller` serializes a plist containing:

```xml
<key>Label</key><string>com.aobo.JobApplicationCopilot.worker</string>
<key>ProgramArguments</key>
<array><string>ABSOLUTE_BUNDLED_WORKER_PATH</string><string>--scheduled</string></array>
<key>RunAtLoad</key><true/>
<key>StartCalendarInterval</key>
<dict><key>Hour</key><integer>8</integer><key>Minute</key><integer>0</integer></dict>
```

Write atomically to `FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]/LaunchAgents/com.aobo.JobApplicationCopilot.worker.plist`. Use `/bin/launchctl bootstrap gui/<uid> <plist>` on first install and `kickstart` only for an explicit user Fetch—not as a periodic retry. If an installed plist differs, boot it out, atomically replace it, and bootstrap the new file. Surface command stderr and exit status; never silently claim scheduling is enabled.

- [ ] **Step 5: Add plist safety and install failure tests**

Test exact ProgramArguments, XML round-trip, file mode `0600`, absence of `StartInterval`/`KeepAlive`/wake keys, atomic replacement, and surfaced nonzero `launchctl` status through an injected command runner.

- [ ] **Step 6: Build and smoke-test the worker**

Run:

```bash
xcodebuild -project JobApplicationWidget.xcodeproj -scheme JobScoutWorker \
  -configuration Debug -sdk macosx -derivedDataPath .build CODE_SIGNING_ALLOWED=NO build
```

Then invoke the built executable with an invalid argument and assert a concise usage error and nonzero exit. Do not run `--scheduled` against the real App Group in automated tests.

- [ ] **Step 7: Commit**

```bash
git add JobScoutWorker Shared/LaunchAgentInstaller.swift \
  JobApplicationWidgetTests/LaunchAgentInstallerTests.swift \
  JobApplicationWidgetTests/WorkerCommandTests.swift JobApplicationWidget.xcodeproj/project.pbxproj
git commit -m "feat: install daily worker launch agent"
```

### Task 8: Add App Fetch and scheduling error surfaces

**Files:**
- Create: `JobApplicationWidget/FetchController.swift`
- Modify: `JobApplicationWidget/JobApplicationWidgetApp.swift`
- Modify: `JobApplicationWidget/ApplicationListView.swift`
- Modify: `JobApplicationWidget.xcodeproj/project.pbxproj`
- Test: `JobApplicationWidgetTests/FetchControllerTests.swift`

**Interfaces:**
- Consumes: the bundled `JobScoutWorker` executable and `LaunchAgentInstaller`.
- Produces: `FetchController.fetch()`, `isRunning`, `errorMessage`, and a visible Fetch control that always launches `--force`.

- [ ] **Step 1: Write failing Fetch argument and error tests**

```swift
@MainActor
func testFetchLaunchesBundledWorkerInForceMode() throws {
    let runner = RecordingProcessRunner()
    let controller = FetchController(workerURL: .testWorker, runner: runner)
    controller.fetch()
    XCTAssertEqual(runner.arguments, ["--force"])
}

@MainActor
func testFetchLaunchFailureIsVisibleAndDoesNotChangeJobs() throws {
    let controller = FetchController(workerURL: .missing, runner: FailingProcessRunner())
    controller.fetch()
    XCTAssertNotNil(controller.errorMessage)
}
```

- [ ] **Step 2: Run tests and verify failure**

Run the full test command; expect `FetchController` not found.

- [ ] **Step 3: Embed and launch one helper executable**

Add a Copy Files phase that places `JobScoutWorker` at `Contents/Helpers/job-scout`. Resolve that URL from `Bundle.main.bundleURL`; do not use DerivedData, `/Applications`, the repository, or the user's home directory. `FetchController` launches it directly with `--force`, observes termination asynchronously, prevents duplicate button clicks only within the current App process, and relies on `WorkerLock` for cross-process exclusion.

- [ ] **Step 4: Install the LaunchAgent and surface failures**

During App startup, call `install(workerURL:)` after the App Group/database migration succeeds. Keep installation errors separate from database errors so the App remains usable; show “Automatic scheduling unavailable” with the actionable error. Do not mark scheduling active when `launchctl` fails.

- [ ] **Step 5: Replace Refresh with Fetch while retaining explicit reload**

The main toolbar Fetch button invokes `fetch()`. Keep a separate Reload action or reload on worker termination so displayed jobs reflect committed results. Disable Fetch while the local controller's child is running; an `.alreadyRunning` worker exit is displayed as “A run is already active,” not as success.

- [ ] **Step 6: Run store, Fetch, full tests, and unsigned builds**

```bash
xcodebuild -project JobApplicationWidget.xcodeproj -scheme JobApplicationWidget \
  -destination 'platform=macOS' -derivedDataPath .build CODE_SIGNING_ALLOWED=NO \
  -only-testing:JobApplicationWidgetTests/ApplicationStoreTests \
  -only-testing:JobApplicationWidgetTests/FetchControllerTests test
xcodebuild -project JobApplicationWidget.xcodeproj -scheme JobApplicationWidget \
  -destination 'platform=macOS' -derivedDataPath .build CODE_SIGNING_ALLOWED=NO test
xcodebuild -project JobApplicationWidget.xcodeproj -scheme JobApplicationWidget \
  -configuration Debug -sdk macosx -derivedDataPath .build CODE_SIGNING_ALLOWED=NO build
xcodebuild -project JobApplicationWidget.xcodeproj -scheme JobScoutWorker \
  -configuration Debug -sdk macosx -derivedDataPath .build CODE_SIGNING_ALLOWED=NO build
```

Expected: all tests and both unsigned products PASS; the Widget target contains none of the network, launchd, power, coordinator, or Fetch files.

- [ ] **Step 7: Commit**

```bash
git add JobApplicationWidget/FetchController.swift JobApplicationWidget/JobApplicationWidgetApp.swift \
  JobApplicationWidget/ApplicationListView.swift JobApplicationWidgetTests/FetchControllerTests.swift \
  JobApplicationWidget.xcodeproj/project.pbxproj
git commit -m "feat: add force Fetch worker launch"
```

### Task 9: Verify low-power behavior, recovery, and documentation

**Files:**
- Modify: `README.md`
- Create: `JobApplicationWidgetTests/WorkerAcceptanceTests.swift`
- Modify: `JobApplicationWidget.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: the complete scheduling/checkpoint foundation.
- Produces: repeatable acceptance tests and operator documentation; no new runtime abstraction.

- [ ] **Step 1: Add a deterministic end-to-end acceptance test**

```swift
func testOfflineSleepWakeStableNetworkRunAndBackup() async throws {
    let fixture = try WorkerAcceptanceFixture(now: .melbourneAfterEight)
    let task = Task { await fixture.coordinator.run(trigger: .scheduled, force: false) }
    fixture.network.send(.unsatisfied)
    fixture.power.send(.willSleep)
    fixture.power.send(.didWake)
    fixture.network.send(.satisfied)
    fixture.clock.advance(by: 60)
    fixture.probes.succeedTwice()
    XCTAssertEqual(await task.value, .succeeded)
    XCTAssertEqual(try fixture.database.runs().count, 1)
    XCTAssertEqual(try fixture.database.runs().first?.status, .succeeded)
    XCTAssertEqual(try fixture.backups().count, 1)
}
```

Use fakes only; the test must finish without real waits, network, sleep, App Group, or launchd changes.

- [ ] **Step 2: Add static launchd and CPU-wakeup guards**

Parse the generated plist and assert the only launch keys are `RunAtLoad` and `StartCalendarInterval`. Add a fake scheduler counter test proving an hour of offline virtual time schedules no repeating timer and makes no HTTPS request until a new path event arrives.

- [ ] **Step 3: Run all automated acceptance commands**

Run all four commands from Task 8 Step 6.

Expected: PASS. Also run `rg -n 'StartInterval|15.?min|sleep\(|usleep\(|Power Assertion|IOPMAssertion' JobScoutWorker Shared JobApplicationWidget` and confirm there is no polling or wake assertion implementation; test names/documentation may mention forbidden keys only as assertions.

- [ ] **Step 4: Perform signed manual acceptance on a configured development team**

With the registered App Group and signed app/helper:

1. launch the app and confirm the LaunchAgent plist contains only login and 08:00 triggers;
2. disconnect networking after 08:00 and confirm the worker remains idle with negligible CPU in Activity Monitor;
3. reconnect for under 60 seconds and disconnect; confirm no run begins;
4. reconnect for 60 seconds and confirm exactly two probes then one run;
5. start Fetch while a scheduled run holds the lock; confirm the second invocation reports already running;
6. sleep during the performer, wake, and confirm the same run ID resumes only after fresh stability/probes;
7. run 31 successful force invocations using the test performer and confirm exactly 30 valid JSON backups remain.

Record observed timestamps, run IDs, CPU sample, and backup count in the review/commit notes. Do not add machine-specific paths or logs to the repository.

- [ ] **Step 5: Update README without claiming future ingestion**

Document:

- Melbourne 08:00 calendar plus login/deferred-wake behavior;
- event-driven offline waiting, 60 seconds, and two probes;
- Fetch force semantics and lock behavior;
- sleep/network checkpoint and resume behavior;
- SQLite `runs` truth and 30 JSON backups;
- LaunchAgent label/plist location, log location, uninstall command, and error recovery;
- that Outlook, scraping, Chrome, Codex, risk/matching, and document generation are still not implemented.

- [ ] **Step 6: Commit**

```bash
git add README.md JobApplicationWidgetTests/WorkerAcceptanceTests.swift \
  JobApplicationWidget.xcodeproj/project.pbxproj
git commit -m "test: verify worker scheduling and recovery"
```

## Completion Criteria

- Schema 1 upgrades atomically to schema 2 and existing jobs/local tracking remain byte-for-byte equivalent through typed reads.
- Login and 08:00 are the only automatic launch triggers; sleep-through-08:00 is handled by launchd's deferred calendar delivery/startup due check, not polling or a wake assertion.
- A scheduled day runs once after stable connectivity; force may run again but still obeys power, network, probes, and lock gates.
- Sleep or network loss checkpoints before owned work is cancelled and resumes the same run only after fresh validation.
- Waiting offline creates no repeating timer, HTTPS traffic, browser, Codex, or business-table reads.
- Concurrent automatic/manual starts create one active run and one performer invocation.
- A successful run produces one atomic JSON backup and retention never exceeds 30.
- App surfaces database, scheduling, and Fetch launch errors; Widget remains read-only and free of worker code.
- Full tests, app build, worker build, and signed manual acceptance pass.

## Explicitly Deferred

- Outlook Graph authorization and mail ingestion.
- SEEK/Indeed/LinkedIn/company source adapters or browser automation.
- Codex CLI invocation, model selection, quota/auth handling, and schema validation.
- Job normalization, risk, eligibility, matching, documents, and notifications.
- Background wake assertions, fixed retry intervals, cloud sync, and multi-user scheduling.
