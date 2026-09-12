# Contributing to OpenTile

## Local setup

Use an Apple Silicon Mac with macOS 14+ and Swift 6.2+ Command Line Tools or Xcode.
Run commands from the repository root:

```sh
scripts/test.sh
swift build -c release
OPENTILE_SIGNING_IDENTITY="-" scripts/package.sh
```

Tests use Swift Testing, not XCTest; full Xcode is not required. Narrow a test run
with `scripts/test.sh --filter gesturePollingStopsAndCanResumeWithoutDuplicateTimers` while working.
Packaging writes a development app and ZIP under `.build/package/`.
Quit the separate AeroSpace app before running OpenTile. Replacing an installed
app with an ad hoc build can require granting permissions again.

## Repository layout

| Location | Responsibility |
| --- | --- |
| `Sources/OpenTile/` | App lifecycle, native UI, permissions, updates, workspace integration |
| `Sources/OpenTileCore/` | Gesture recognition and workspace/app domain logic |
| `Sources/OpenTileC/` | Native trackpad bridge |
| `Tests/` | Swift Testing suites for core logic and app integration |
| `Vendor/AeroSpace/` | Embedded tiling engine; keep local changes focused and documented |
| `Resources/` | App assets |
| `scripts/` | Shared local and CI test, packaging, and release commands |
| `.github/` | CI, dependency updates, issue and pull request templates |

Keep changes focused on one outcome. Prefer testing deterministic behavior in
OpenTileCore; add app-level tests where lifecycle or integration behavior matters.
Avoid unrelated vendored engine changes. Update the README for user-visible behavior.

## Manual checks

CI cannot drive a physical trackpad or approve real privacy dialogs. For relevant
changes, record the app version, macOS version, signing identity type, and results:

- Enable, pause, and resume gestures; try move, resize, drawing, and cancellation.
- Switch workspaces using the menu and URL scheme while gestures are paused.
- Check first-launch permission setup, deferred/revoked permissions, and an update
  over an existing installation. Test Screen Recording denial and Reduce Motion.
- For performance changes, compare the same signed release build and machine in
  Activity Monitor: 60 seconds paused, 60 seconds enabled but idle, and repeated
  gestures/workspace switches. Record CPU and memory; repeat to detect growth.
  The gesture polling timer should stop while paused. Do not infer battery savings
  from timer tests alone.

## Maintenance automation

The `Build macOS app` workflow checks shell syntax, runs tests, packages the app,
and uploads a development ZIP on pull requests, main pushes, version tags, and
manual dispatch. Superseded runs are cancelled; each job has a 30-minute limit.

Dependabot proposes weekly GitHub Actions and root SwiftPM dependency updates.
Review and test these PRs before merging; there is no automatic merge. Vendored
AeroSpace updates remain manual because they require reviewing local integration.

To enforce CI before merging, a repository administrator must configure a branch
ruleset for `main` requiring pull requests and the `build` status check after it
has appeared in GitHub. Workflow files alone do not enforce branch protection.

## Releases

See [the release checklist](RELEASING.md). Never commit code-signing certificates,
private Sparkle keys, passwords, or exported Keychain contents.
