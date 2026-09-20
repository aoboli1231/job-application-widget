# Job Application Widget

A native macOS menu-bar app and WidgetKit extension for tracking job applications.

## Current foundation

- SQLite is the authoritative runtime data store.
- The app owns migrations and writes; the Widget opens the same database read-only.
- The existing nine prototype jobs are imported once when no earlier data exists.
- Legacy `UserDefaults` tracking state is migrated without overwriting status, notes, or application dates.
- The shared container is the App Group `group.com.aobo.JobApplicationCopilot`.

JSON is not a live second database. It may be used later as an explicit one-time import or backup format, but the app and Widget do not poll `data/jobs.json` or a repository path.

Outlook ingestion, SEEK/Indeed/LinkedIn search, scam analysis, match scoring, tailored PDF generation, scheduling, and network-stability monitoring are later increments and are not implemented in this foundation.

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

Unsigned builds verify compilation and tests, but a real Apple development team and matching App Group entitlement are required to validate the shared production container between the app and Widget.

## Data location and migration

`DatabaseLocation` resolves the App Group container and stores the database at:

```text
Library/Application Support/JobApplicationCopilot/jobs.sqlite3
```

There is deliberately no fallback to `UserDefaults.standard`, a temporary database, the user's home directory, or a hard-coded repository path. If the App Group or database cannot be opened, the app displays the error and the Widget returns an empty safe entry.

## Privacy

Do not commit resumes, generated application documents, mailbox exports, credentials, access tokens, or personal application data. The SQLite database lives outside the repository in the private App Group container.

## License

No license has been selected. Treat this repository as all-rights-reserved until a license is added.
