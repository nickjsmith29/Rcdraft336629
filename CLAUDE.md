# CLAUDE.md

Guidance for Claude Code working in this repo.

This repo started on Nov 23, 2026 from one fresh commit of an earlier private repo. Issue and PR numbers (`#n`) in code comments, SPEC.md, docs and test names written before then refer to that earlier repo, not to this one. Open issues were copied here with a "Was #n" line linking the two numbers.

## Source of truth

- Read `SPEC.md` before any work and build what it says. If code and spec disagree, follow the spec and flag the gap by opening a `spec` issue (see Backlog); don't change the spec inside a code PR.
- Feature IDs (F1 to F13) and science rules (3.1 to 3.9) in SPEC.md are the names to use in commits, PRs, tests and code comments.
- **Research before rules (the owner's rule).** Any new or changed spec decision about training load, recovery or safety is checked against current peer-reviewed research and authoritative running sources before it is built. Cite the sources by number in SPEC.md's References section (section 12), keep the notes in `docs/research/`, and where the evidence is weak or conflicting, say so in the spec. Never cite a source you haven't read.

## Hard rules

- All training decisions (paces, volume, zones, plan changes, guardrails, cues) are deterministic Swift in `CoachCore` with unit tests. The LLM only runs the goal interview, explains, and words the debrief. It never sets a pace or a volume.
- `CoachCore` imports Foundation only: no HealthKit, SwiftUI, WorkoutKit or other Apple-only frameworks. It must build and test with `swift test` on Linux.
- Health data stays on the device. Only small computed summaries may go to the Anthropic API. Data from the Strava API must never be sent to an LLM (SPEC.md 5.1).
- The race, date, distance and time goal are always set by the athlete in the app and editable anytime (F2). Never hard-code a race.
- **Nothing user-specific is hard-coded (the owner's rule).** The app works for any runner. Heart-rate zones, LTHR, max HR, paces, race times, history, health baselines and pain history are computed at runtime from the runner's own phone and watch data (HealthKit, and Strava only if they connect it) or entered by the runner. No default that stands for a particular person, and no age-based formulas once real data exists.
- Tests and fixtures use synthetic data. Never put a real person's runs, races, heart rates or health data into the repo, code comments, issues or test expectations.
- Not in scope: strength sessions, shoe tracking, manual "holiday" or "not feeling 100%" modes. Adaptation is automatic.
- Never commit secrets, certificates, provisioning profiles, .p8 keys or API keys. CI reads them from GitHub secrets only.
- Never skip or disable a test to get CI green.

## Build without a Mac (SPEC.md 6.1)

- The owner has a Windows PC and no Mac. Nothing may require opening Xcode.
- Generate the project with XcodeGen from `project.yml`; don't commit a hand-edited `.xcodeproj` (commit `project.yml` and regenerate in CI).
- Signing: fastlane match (readonly in CI) with an App Store Connect API key. Upload with fastlane `pilot` to TestFlight.
- CI: `swift test` for CoachCore on `ubuntu-latest`, kept lean so it also fits a private repo's free allowance (about 2,000 Linux Actions minutes a month) whenever the repo is private. It runs on pull requests that are ready for review and change more than Markdown or `docs/`; draft PRs are skipped, and a newer push to the same PR cancels the run it replaces. It doesn't run again on `main` after a merge, because a PR is merged only from a head that already contains `main`, so its run tested what lands (run it by hand with workflow_dispatch if needed). PR runs can only restore `main`'s build cache, so after a merge that changes `CoachCore/Package.swift`, run the workflow by hand on `main` once to refresh it. Open PRs as drafts, run the suite locally in Docker first, mark the PR ready only once it passes, and batch fixes into as few pushes as you can. The macOS job (build, sign, upload) runs only on `v*` tags or by hand, never on every merge, because merges can happen hourly and each macOS run costs money. Only the owner pushes a `v*` tag (or the agent, after asking the owner first), since each tag starts a paid macOS build. The hourly routine never tags. Cache SwiftPM and DerivedData.
- Bump the build number automatically from the run number.

## Start here: Phase 0 (build pipeline)

Goal: a build pushed from Windows lands on the owner's iPhone and Apple Watch through TestFlight.

1. `CoachCore` Swift package with a placeholder module and one passing test; Linux CI workflow running `swift test`.
2. `project.yml`: iPhone app target (SwiftUI, HealthKit capability with read access to workouts, heart rate, HRV, resting HR, VO2 max, running power, speed, stride, steps and sleep, and usage strings), embedded watchOS app target, both depending on CoachCore. iOS 17+ and watchOS 10+.
3. Placeholder screens: iPhone shows "Running Coach" and a HealthKit permission button; watch shows a single screen.
4. `fastlane/Fastfile` with a `beta` lane: match (appstore, readonly), build_app, upload_to_testflight using the API key from secrets.
5. `.github/workflows/ios.yml`: macOS runner, install XcodeGen, `xcodegen generate`, run `fastlane beta`.
6. Open one PR for Phase 0. In its description, list exactly which secrets the owner must add (see README "Owner setup") and what to check in TestFlight.

Status (Nov 20, 2026): Phase 0 is scaffolded. The owner hasn't joined the Apple Developer Program yet, so the signed TestFlight build waits. Until then, keep building everything that is testable on Linux CI: CoachCore logic for Phase 1, with the app UI kept thin.

Then Phase 1 (F1, F2, F3, F4, F9, F6, F13 v1, F10 WorkoutKit sync), one feature per PR, CoachCore logic first with tests, then UI. That list is the scope; the order of work comes from the issue backlog below.

## Testing

- Every CoachCore rule gets unit tests, including edge cases (missed days, missing cadence, duplicate Runna + watch activities, treadmill runs, heat).
- Build the replay harness early (SPEC.md 7): synthetic or simulated runs in `Fixtures/` replayed through the Adapter and CueEngine, with expected outputs. A runner's own exports go only in the git-ignored `Fixtures/local/` and are never needed for CI.

## Backlog (the owner's rule)

- **SPEC.md is the source of truth.** A new feature, or a change to an existing one, is first written into SPEC.md in its own PR, reviewed and merged like code, before any code for it. Label that PR's issue `spec`.
- **GitHub Issues are the to-do list.** Each piece of work is one issue labeled with its phase (`phase-0` to `phase-3`), its type (`feature`, `bug`, `spec`, or `chore` for docs, CI and tooling) and a priority (`priority: high`, `priority: medium`, `priority: low`). `blocked` marks work waiting on something outside the repo, such as the Apple Developer account.
- **What to work on next:** the open issue with the highest priority that isn't labeled `blocked` or `in-progress`, has no open linked PR, and whose "Depends on" issues are all closed; within a priority, the lowest issue number. Issues were created in dependency order, so the number breaks ties.
- **Claim it first.** The moment you start an issue, add the `in-progress` label and open a draft PR as soon as there's a first commit, so nobody else (including the hourly routine) picks it up. If you stop without finishing, remove `in-progress` and close the draft PR with a comment saying where the work stands. A claim with no commits or PR activity for 6 hours is stale: the next session may release it the same way (remove `in-progress` and close the stale draft PR with a comment) and take the issue.
- **Hourly routine.** At the owner's request, an hourly scheduled run builds the top unclaimed issue, runs the reviewer and merges after approval, following this file. Interactive sessions follow the same claim rule so the two never collide. The routine lives in the owner's Claude app, not in this repo; the owner pauses or stops it there.
- **Ideas from the owner** arrive as issues the owner opens or as one-liners written up into issues. Write an issue with what to build, the SPEC.md sections, dependencies and a "Done when" line.
- One issue per PR where possible. Don't widen a PR with new work; follow the focus rules below for what to file.

### Focus (the owner's decision, 23 Nov 2026)

The backlog grew faster than it shrank, so the owner chose these four rules. They outrank anything in this file that says otherwise.

1. **Keep the backlog to what blocks a usable plan.** An open issue is roadmap work (phases 0 to 3), app work, or something that makes normal plans wrong or unusable. Low-priority edge cases are parked: closed as not planned with the `deferred` label and listed in the running follow-ups issue (#74). Reopen one only if it starts to matter for normal 3 to 6 day weeks.
2. **No new issue per merge.** Small follow-ups from reviews (wording, extra tests, doc fixes, rare inputs) go as a checklist line in #74, not as new issues. File a new issue only for a real bug that affects a normal plan, or for work that blocks a usable app.
3. **Batch the owner's questions.** Collect the calls only the owner can make (spec choices, training-rule changes, anything that costs money) and ask them together at most once a day, not one at a time. Until answered, keep the current safe behaviour and work on something else. Label the issue `needs-owner`.
4. **Good enough, then move on.** Once the plan engine builds sound plans for normal 3 to 6 day weeks, move to Phase 2 (the Watch app and screens) rather than polishing rare cases. Reviewers approve when what's left is low-priority edge cases, logged in #74, instead of asking for another round.
- Don't add other scheduled or automated runs (cron workflows, nightly agents) unless the owner asks for one.

## Pull request workflow (the owner's rule)

Every change reaches `main` through a pull request that has passed review. The owner asked for this setup: a separate reviewer agent approves, then the coder agent merges.

1. **Code.** Work on a branch named for the feature (for example `f1-baseline`). Keep each PR to one feature or pipeline step. Run `swift test` in `CoachCore/` locally (in Docker if there's no Swift toolchain) before marking the PR ready, since CI runs only on ready PRs.
2. **Open the PR** against `main` (a draft at first, per the claim rule) with a Before/After description, `Closes #<n>` for its issue (docs-only or chore PRs may have no issue; then say so), the F-numbers and spec sections it implements, and what is not verified. Mark it ready for review when the work is done.
3. **Wait for CI** to be green on the PR's head commit. A PR that changes only Markdown or `docs/` gets no CI run, and that counts as green.
4. **Review.** Run the `pr-reviewer` subagent (`.claude/agents/pr-reviewer.md`) on the PR. It's a fresh agent that didn't write the code. Post its full verdict on the PR as a comment headed `Review by pr-reviewer agent`.
5. **Fix and re-review.** If the verdict is CHANGES REQUESTED, fix every blocking finding, push, wait for green CI, and run the reviewer again on the new head. Repeat until it returns APPROVED with no blocking findings. Non-blocking findings go as checklist lines in #74 (Focus rule 2), not as new issues; fix one in the PR only if it's quick and needs no extra round.
6. **Merge.** Once the latest review on the current head is APPROVED, CI is green and the head is not behind `main` (if it is, merge `main` into the branch, wait for CI, and review again only if the merge changed the PR's own code), the coder agent merges with a squash merge (deleting the branch where the session's access allows; leave it if not). GitHub won't let the same account approve its own PR, so the posted reviewer comment is the approval record. The `Closes #<n>` line closes the issue on merge.

**Model split (the owner's rule).** Planning, spec work and PR reviews run on Opus; the coding itself runs on Sonnet. The session that drives the work stays on Opus: it picks the issue, writes a self-contained brief (the issue, the SPEC sections, the files to touch, the tests to pass and the rules in this file) and hands the implementation to a subagent started with model `sonnet`. The `pr-reviewer` agent runs on Opus. The driving session checks the coder's result and runs the review before anything merges; the merge rules above are unchanged.

Limits on what the coder agent may do on its own:
- Merge only into `main` of `nickjsmith29/rcdraft336629`, only after an APPROVED review on the PR's current head and green CI.
- Never force-push, rewrite `main`'s history, or bypass a failing check.
- Never change repository settings, branch protection, secrets, variables, collaborators or visibility, and never touch any other repo.
- Anything that costs money, touches the Apple account or changes signing still waits for the owner.

## Working style

- Small PRs, one feature or pipeline step each, with a Before/After description.
- Ask the owner before anything that costs money, touches the Apple account, or changes signing.
