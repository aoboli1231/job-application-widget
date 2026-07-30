# Job Application Widget

A native macOS SwiftUI menu-bar popover and WidgetKit extension for tracking job applications.

## Current status

This is an early work-in-progress prototype. The core checklist and dashboard are usable, but the project is not yet production-ready.

Implemented:

- menu-bar popover and Dock-launchable macOS app
- WidgetKit extension with shared application state
- application checklist with persistent applied/status/notes state
- match percentage, full-time filter, priorities and dashboard summaries
- direct JD links opened in Google Chrome when a valid URL is stored
- one-click Codex task, resume and cover-letter shortcuts
- local JSON hand-off point for Codex job-search agents
- add-job form, hover feedback, adaptive layout and quit action

Planned:

- recurring Codex automation for job searches
- robust import/export and conflict handling for `jobs.json`
- editable application status, notes and follow-up dates
- configurable paths and Codex task identifiers
- tests, accessibility review, signing and distribution packaging

## Build locally

Open `JobApplicationWidget.xcodeproj` in Xcode 16 or later and build the `JobApplicationWidget` scheme for macOS. The project targets macOS 13+.

For an unsigned local Intel build:

```sh
xcodebuild -project JobApplicationWidget.xcodeproj \
  -scheme JobApplicationWidget \
  -configuration Debug \
  -sdk macosx \
  -arch x86_64 \
  -derivedDataPath .build \
  CODE_SIGNING_ALLOWED=NO build
```

## Codex agent data contract

The agent hand-off file is `data/jobs.json`. It contains a JSON array matching `JobApplication` in `Shared/ApplicationModel.swift`.

An agent should:

1. Search current Melbourne/Australia junior, graduate, analyst, AI and ML roles.
2. Keep roles with a match score of at least 80%, prioritising full-time roles and larger employers.
3. Store the original SEEK, Workday, company or other source URL in `jdURL`; do not fabricate URLs or use a Google search URL.
4. Preserve an existing role's `id` when refreshing it.
5. Never overwrite locally tracked `applied`, `status` or `notes` values.
6. Explain the fit in `matchReason` and sort records by `priority`.

Suggested instruction for a new Codex agent:

> Read the repository README and update `data/jobs.json`. Search current Melbourne/Australia full-time junior/graduate data, analytics, AI and ML roles. Rank against the user's resume, keep match scores of 80%+, include the original valid job URL, preserve existing application state, and do not invent listings or links.

Use the app's **Sync agent updates** action after the agent writes the file.

## Privacy and security

This repository contains no resume, email export, credentials, access tokens or mailbox data. User-specific job data should stay in the local JSON file or a private repository. Do not commit generated Xcode user data, build products or personal absolute paths.

## License

No license has been selected yet. Treat this repository as all-rights-reserved until a license is added.
