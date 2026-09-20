# Git History Cleanup and Publish Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to execute this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reorganize the 25 unpublished local commits into clear task-level commits, verify that the final source tree is unchanged and tested, then publish `main` to `git@github.com:aoboli1231/job-application-widget.git`.

**Architecture:** Preserve `origin/main` as the immutable base and create a local safety branch at the current HEAD. Rewrite only unpublished commits, grouping adjacent implementation/fix/test milestones by deliverable; retain cross-cutting regression fixes as their own QA commit. Compare the rewritten tree to the safety branch before running tests and pushing normally.

**Tech Stack:** Git, Xcode/xcodebuild, Swift/XCTest, GitHub SSH remote.

**Spec:** `docs/superpowers/specs/2026-09-20-job-application-copilot-design.md` and `docs/superpowers/plans/2026-09-20-worker-scheduling-and-checkpoints.md`

## Global Constraints

- Do not change source behavior while rewriting history.
- Do not rewrite or force-push `origin/main`.
- Preserve every tracked file from current commit `a70a0b6` exactly, except this publish-plan document.
- Do not include DerivedData, build products, credentials, candidate documents, or local App Group data.
- Every task commit must include a concise subject and a body listing the delivered behavior and verification scope.
- Push only after the rewritten tree, tests, and remote target are verified.

## Review Focus

- Tree drift during history rewriting: compare the safety branch and rewritten HEAD with `git diff --exit-code`.
- Accidentally omitted generated/project membership changes: run the full macOS scheme tests from a fresh DerivedData path.
- Sensitive or local-only files: inspect the complete outgoing file list before push.
- Wrong remote or branch: verify `origin`, current branch, and ahead/behind counts immediately before push.
- Destructive recovery: keep the safety branch until the GitHub push is verified.

---

### Task 1: Freeze the current state and outgoing inventory

**Files:**
- Create: local safety branch `backup/pre-publish-a70a0b6`
- Inspect: all commits and files in `origin/main..main`

- [ ] Verify the working tree contains only this approved plan document.
- [ ] Commit this plan as `docs: plan task-level history and GitHub publish`.
- [ ] Create the safety branch at the resulting pre-rewrite HEAD.
- [ ] Record the pre-rewrite tree hash and outgoing file list.
- [ ] Scan outgoing paths for build output, secrets, private candidate material, and local databases.

### Task 2: Rewrite unpublished history into task-level commits

**Files:**
- Rewrite: commits in `origin/main..main` only

Create these commits in order, with a body containing `Task`, `What changed`, and `Verification` paragraphs:

1. `docs: specify the job application copilot`
   - Product requirements, accepted workflow decisions, and persistence plan.
2. `build: establish the macOS app-group test foundation`
   - Test target, bundle metadata, entitlements, and shared App Group defaults.
3. `feat: define the job domain and database location`
   - Job model, canonical shared database location, and model tests.
4. `feat: add hardened transactional SQLite persistence`
   - Schema, migrations, CRUD, validation, rollback/error boundaries, and persistence tests.
5. `feat: migrate legacy tracking data without loss`
   - Legacy import, lossless field mapping, idempotence, and migration tests.
6. `feat: integrate SQLite with the app and widget`
   - App store reads/writes, widget summaries, refresh behavior, and integration tests.
7. `docs: plan resumable worker scheduling`
   - Worker architecture, low-power scheduling, network, sleep/wake, checkpoint, and launchd tasks.
8. `feat: persist resumable worker runs and checkpoints`
   - Schema v2, strict run decoding, atomic migration, daily success gate, and checkpoint tests.
9. `feat: add App Group worker paths and process locking`
   - Container-derived paths, non-blocking `flock`, fd lifecycle, and concurrency tests.
10. `feat: gate worker execution on stable network`
    - Pure stability state machine, one-shot timer, sequential HTTPS probes, cancellation/generation safety, and tests.
11. `feat: stop owned worker resources for sleep and cancellation`
    - Power event stream, explicit process/network ownership, graceful termination timeout, and lifecycle tests.
12. `feat: expose a network readiness lease`
    - Remembered runtime path-loss invalidation, reset generations, waiter cancellation semantics, and regression-test stabilization.

- [ ] Reword/squash only local unpublished commits into the list above.
- [ ] Keep cross-task test corrections with the task whose invariant they protect; document any unavoidable cross-cutting correction in commit 12.
- [ ] Confirm every rewritten commit builds logically on its predecessor and contains no unrelated files.

### Task 3: Prove the rewrite did not change the product

**Files:**
- Compare: `backup/pre-publish-a70a0b6` plus the approved plan document against rewritten `main`

- [ ] Run `git diff --exit-code <safety-branch>..main` with only the approved plan-file placement accounted for.
- [ ] Run `git diff --check origin/main..main`.
- [ ] Run focused NetworkGate tests for 10 iterations from a fresh DerivedData path.
- [ ] Run the complete `JobApplicationWidget` test suite from another fresh DerivedData path.
- [ ] Confirm `git status --short` is empty.

### Task 4: Publish and verify GitHub

**Files:**
- Push: local `main` to `origin/main`

- [ ] Verify `origin` is exactly `git@github.com:aoboli1231/job-application-widget.git`.
- [ ] Verify `main` is ahead of `origin/main` and not behind.
- [ ] Show the final 12-task commit list and outgoing file summary for approval.
- [ ] Push with `git push origin main` (no force).
- [ ] Fetch and verify local `main`, `origin/main`, and GitHub point to the same commit.
- [ ] Keep the local safety branch until the user confirms the uploaded history looks correct.
