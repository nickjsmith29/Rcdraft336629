# Running Coach

A personal running coach for iPhone and Apple Watch. It builds a training plan from your own history (Apple Health, optionally Strava), adapts it automatically to what each run shows (pace and physiology: heart rate against your zones, drift, cadence fade), coaches you live by voice through AirPods, and shows concrete proof of improvement on a progress dashboard.

The full product and science spec is in [SPEC.md](SPEC.md). It is the source of truth for what to build.

## How this repo is built

- No Mac is needed. Code is written by Claude Code and pushed here; GitHub Actions macOS runners build, sign and upload the app to TestFlight; the app installs from TestFlight on the iPhone and the paired Apple Watch (SPEC.md section 6.1).
- `CoachCore` is a pure Swift package with all the training logic. It builds and tests on Linux, so most work and tests run without macOS.
- The Xcode project is generated from `project.yml` with XcodeGen. Nobody edits a `.xcodeproj` by hand.

## Layout (target)

```
project.yml              XcodeGen spec for the iPhone app and watch app
CoachCore/               Swift package: metrics, predictor, planner, adapter, cue engine
App/                     SwiftUI iPhone app (HealthKit import, plan, debrief, dashboard)
WatchApp/                watchOS app (Phase 2: live workout and voice cues)
Fixtures/                Synthetic runs for the replay harness (Fixtures/local/ is git-ignored for your own exports)
fastlane/                Signing (match) and TestFlight upload lanes
.github/workflows/       Linux tests on PRs and main; macOS build + TestFlight on v* tags or by hand
```

## Owner setup (one time)

These are done by the repo owner, never by Claude Code. All of them work from a Windows browser.

1. Join the Apple Developer Program ($99 a year) and note your Team ID (Membership details).
2. Pick a bundle ID prefix in reverse-domain form (for example `com.yourname`). In the Apple Developer site under Identifiers, register two App IDs with the HealthKit capability: `<prefix>.runningcoach` and `<prefix>.runningcoach.watchkitapp`.
3. In App Store Connect, create the app record (My Apps > New App) with the `<prefix>.runningcoach` bundle ID.
4. In App Store Connect, create an API key (Users and Access > Integrations) with App Manager access, and download the .p8 file once.
5. Create an empty private repo for signing certificates (for example `running-coach-certs`) for fastlane match.
6. In this repo's Settings > Secrets and variables > Actions, add:
   - Variable `BUNDLE_ID_PREFIX`: your prefix from step 2.
   - Secrets `APPLE_TEAM_ID`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` (the .p8 file contents).
   - Secrets `MATCH_GIT_URL` (the certificates repo URL), `MATCH_PASSWORD` (a passphrase you choose and keep), `MATCH_GIT_BASIC_AUTHORIZATION` (base64 of `username:token` for a GitHub token that can read and write the certificates repo).
7. Run the "iOS build to TestFlight" workflow once by hand (Actions tab > Run workflow) with **first_setup** ticked, so match creates the signing certificate and profiles. Later builds run when a `v*` tag is pushed (for example `v0.2.0`) or when the workflow is run by hand; merges to `main` don't trigger paid macOS builds.
8. Install TestFlight on the iPhone and accept the build.

Until those secrets exist, the TestFlight workflow skips itself on a cheap Linux check, so it costs no macOS minutes. The Anthropic API key is not a CI secret; it's entered in the app's Settings and kept in the Keychain.

**App build check.** The "App build (unsigned)" workflow compiles the iPhone and Watch apps for the simulator on a free macOS runner. It runs on ready pull requests that touch `App/`, `WatchApp/`, `project.yml`, `CoachCore/Sources/`, `CoachCore/Package.swift` or the workflow itself, and by hand. Its macOS minutes are free only while the repo is public. It doesn't sign, run on a device or upload anything, and needs no secrets; the signed TestFlight build (`ios.yml`) still waits on the Apple setup above.
