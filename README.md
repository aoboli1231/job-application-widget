# Job Application Widget

A native macOS menu-bar app and WidgetKit extension for tracking job applications.

## Current foundation

- SQLite is the authoritative runtime data store.
- The app owns migrations and writes; the Widget opens the same database read-only.
- The existing nine prototype jobs are imported once when no earlier data exists.
- Legacy `UserDefaults` tracking state is migrated without overwriting status, notes, or application dates.
- The shared container is the App Group `group.com.aobo.JobApplicationCopilot`.
- A bundled `job-scout` helper runs at login and after 08:00 Melbourne time, or on demand from Fetch.
- Offline waiting is event-driven: it waits for 60 seconds of continuous connectivity, then makes two HTTPS probes.
- Sleep and network loss suspend owned work; wake or reconnection requires a fresh stability check before the same run resumes.
- SQLite `runs` records are authoritative. Each successful run writes an atomic JSON backup and keeps the newest 30.

JSON is not a live second database. The app and Widget do not poll `data/jobs.json` or a repository path.

The current worker validates scheduling, recovery, locking, checkpoints, and backups. Outlook ingestion, SEEK/Indeed/LinkedIn search, Chrome automation, Codex, scam analysis, eligibility, match scoring, and tailored document generation are not implemented yet.

## Scheduling and Fetch

The app installs `~/Library/LaunchAgents/com.aobo.JobApplicationCopilot.worker.plist` after the shared database opens successfully. Automatic triggers are login and the local clock times that can correspond to 08:00 in Melbourne across daylight saving time. On a Mac set to Shanghai time these are 05:00 and 06:00; an early trigger exits immediately without network access. There is no fixed polling interval, keep-alive loop, or power assertion. If the Mac sleeps through a calendar trigger, launchd delivers it after wake and the worker performs its normal due check. Relaunch the app after changing the Mac's time zone so it can update the local trigger times.

Fetch launches the same bundled worker with force mode. Force bypasses the once-per-day success check, but still waits for stable networking, respects sleep, and uses the same cross-process lock. If another run owns the lock, the app reports that a run is already active.

The worker records structured messages in the macOS unified log under subsystem `com.aobo.JobApplicationCopilot`. View recent entries with:

```sh
log show --last 1h --predicate 'subsystem == "com.aobo.JobApplicationCopilot"'
```

To disable automatic launches without deleting application data:

```sh
launchctl bootout gui/$(id -u) "$HOME/Library/LaunchAgents/com.aobo.JobApplicationCopilot.worker.plist"
rm "$HOME/Library/LaunchAgents/com.aobo.JobApplicationCopilot.worker.plist"
```

Relaunching the app installs the LaunchAgent again. Database, scheduling, and Fetch failures appear separately in the menu-bar window; a failure never replaces the database or clears the existing job list.

## Build and test

Open `JobApplicationWidget.xcodeproj` in Xcode 16 or later. The project targets macOS 13+.

Unsigned local build:

```sh
xcodebuild -project JobApplicationWidget.xcodeproj \
  -scheme JobApplicationWidget \
  -configuration Debug \
  -sdk macosx \
  -derivedDataPath .build \
  CODE_SIGNING_ALLOWED=NO build
```

Tests:

```sh
xcodebuild -project JobApplicationWidget.xcodeproj \
  -scheme JobApplicationWidget \
  -destination 'platform=macOS' \
  -derivedDataPath .build \
  CODE_SIGNING_ALLOWED=NO test
```

Unsigned builds verify compilation and tests, but they cannot install a working Widget with the shared App Group. For local personal use, add a free Apple Account in Xcode, select the same Personal Team for the app, Widget extension, and worker targets, keep automatic signing enabled, and register the existing App Group. A paid Apple Developer Program membership and App Store upload are not required for local development use. See Apple's [code-signing setup](https://developer.apple.com/documentation/xcode/adding-capabilities-to-your-app) and [App Group configuration](https://developer.apple.com/documentation/xcode/configuring-app-groups) documentation.

## Data location and migration

`DatabaseLocation` resolves the App Group container and stores the database at:

```text
Library/Application Support/JobApplicationCopilot/jobs.sqlite3
```

Successful backups are stored beside it at:

```text
Library/Application Support/JobApplicationCopilot/Backups/
```

There is deliberately no fallback to `UserDefaults.standard`, a temporary database, the user's home directory, or a hard-coded repository path. If the App Group or database cannot be opened, the app displays the error and the Widget returns an empty safe entry.

## Privacy

Do not commit resumes, generated application documents, mailbox exports, credentials, access tokens, or personal application data. The SQLite database lives outside the repository in the private App Group container.

## License

No license has been selected. Treat this repository as all-rights-reserved until a license is added.
