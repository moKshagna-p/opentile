# OpenTile

A macOS menu bar window manager with trackpad gestures, built on [AeroSpace](https://github.com/nikitabobko/AeroSpace). Move and resize tiled windows, or draw symbols to switch workspaces and open apps.

OpenTile bundles an AeroSpace-based tiling engine with gesture controls and visual previews. Run OpenTile on its own; quit the separate AeroSpace app first.

## Features

- **Move tiles:** pinch and hold, then move two fingers to preview a swap or insertion.
- **Resize tiles:** hold Option and pinch inward to grow or outward to shrink. The orange preview stays within the display’s usable area.
- **Draw to switch:** teach OpenTile a number or symbol for each workspace using three examples, then draw it to switch.
- **Draw to open apps:** train symbols for app shortcuts imported from your active Karabiner Caps + O mappings.
- **Workspace overview:** the menu bar shows the active workspace; the Workspaces menu lists running apps and empty workspaces.
- **Existing configuration:** uses your AeroSpace configuration when no OpenTile configuration exists. Open and reload configuration from the menu.
- **Workspace animations:** drawing, menu, and OpenTile URL switches use a vertical slide transition, with support for Reduce Motion. Direct engine commands and automatic app routing do not animate.
- **Permission setup:** a first-launch setup explains and requests missing permissions. Revisit it from the menu whenever needed.
- **In-app updates:** Sparkle checks for signed updates, with manual checks and an automatic-check toggle in the menu. Available updates appear in the menu bar without stealing focus.

## Requirements

- macOS 14 or later, an Apple Silicon Mac, and a built-in trackpad.
- Quit the separate AeroSpace app before starting OpenTile. The engine and CLI are bundled.
- Accessibility permission for OpenTile. Screen Recording permission enables workspace animations.
- Swift 6.2 or later to build from source. Full Xcode is not required: building and testing work with compatible Command Line Tools. The test script has been verified with Command Line Tools Swift 6.3.3.

## Install and permissions

Download the app ZIP from [GitHub Releases](https://github.com/moKshagna-p/opentile/releases), extract it, and move **OpenTile.app** to **Applications**. Quit the separate AeroSpace app, then open OpenTile.

On first launch, **Permission Setup** offers to request missing permissions:

- **Accessibility** allows OpenTile to move and resize windows.
- **Screen Recording** enables workspace transition snapshots, which stay in memory. Workspace switching still works without it.

macOS handles each permission separately and may require reopening the app. Select **Continue** to request them, or **Later** to defer. Setup is remembered; reopen **Permission Setup…** from the menu if you deferred or revoked a grant. Enabling gestures and switching workspaces no longer initiate permission requests.

After granting Accessibility, select **Enable Gestures** from the menu bar. macOS owns permission grants; preserving them across updates depends on a consistent app identity and Developer ID signing team. Ad hoc development builds may prompt again after rebuilding.

## Build and run

From the repository root:

```sh
OPENTILE_SIGNING_IDENTITY="-" scripts/package.sh
cp -R .build/package/OpenTile.app /Applications/
open /Applications/OpenTile.app
```

This creates an ad hoc signed development build. For a stable signed build, set `OPENTILE_SIGNING_IDENTITY` to your code-signing identity instead of `-`. If omitted, the script selects the identity only when exactly one is available.

Packaging bundles the tiling engine, CLI, Sparkle, icon, and licenses; verifies the code signature; and writes the app, `OpenTile-macOS-arm64.zip`, and `SHA256.txt` to `.build/package/`. A bare `swift run` executable does not support in-app updates.

## Gestures

Start with a focused tiled window.

| Action | Gesture |
| --- | --- |
| Move or swap | Pinch inward with two fingers, hold briefly, then move them together. Release over another tile’s center to swap, or near its edge to insert. |
| Resize | Hold Option before touching the trackpad. Pinch inward to grow or spread outward to shrink, then lift to apply. |
| Switch workspace | Hold Control–Option, draw a saved symbol with one finger, then release the keys. |
| Open app | Hold Option, draw a saved app symbol with one finger, then release Option. Two fingers still resize. |
| Cancel | Press Escape before applying the gesture. |

For a new workspace symbol, follow the training prompt or choose **Draw to Switch Workspace → Teach a Workspace Symbol**. The same menu lets you change the drawing shortcut to Control–Shift.

For app symbols, choose **Draw to Open App → Teach an App Symbol** and save three examples. Available apps come from the active Caps + O layer in `~/.config/karabiner/karabiner.json`; arbitrary Karabiner actions are not imported.

## Configuration

OpenTile checks `~/.opentile.toml` and `${XDG_CONFIG_HOME:-~/.config}/opentile/opentile.toml` before falling back to your AeroSpace configuration. Use the menu to open or reload configuration. A separate AeroSpace installation is not required.

## Tests and CI

Run the Swift Testing suite without XCTest or a full Xcode installation:

```sh
scripts/test.sh
scripts/test.sh --filter PermissionSetupTests
```

The script supplies framework and runtime paths when using Command Line Tools. The current suite contains 51 tests covering gestures, app mapping, workspace drawing and switching, the embedded engine, updater behavior, and permission setup logic.

The [Build macOS app workflow](.github/workflows/build.yml) runs on relevant source, dependency, resource, test, script, and workflow pushes; every pull request; and manual dispatch. It:

1. Checks the Apple Silicon runner and reports the toolchain, using macOS 15 with Xcode 26.2.
2. Runs `scripts/test.sh`.
3. Builds and packages an ad hoc signed app with `scripts/package.sh`.
4. Uploads the app ZIP and SHA256 checksum as `OpenTile-macOS-arm64`, retained for 30 days.

CI does not exercise physical trackpad input, real macOS permission dialogs, or permission persistence across installed updates. These need manual testing. CI artifacts are development builds, not public release packages. README-only pushes do not trigger the workflow.

## Preparing public releases

Release preparation requires a **Developer ID Application** certificate and the existing Sparkle signing key in Keychain, matching `scripts/sparkle-public-key.txt`. Keep the same Developer ID team and Sparkle key across releases.

```sh
OPENTILE_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  scripts/prepare-release.sh VERSION BUILD_NUMBER
```

Replace `VERSION` with a semantic version and `BUILD_NUMBER` with a positive integer, increasing both for each release. The script rejects non-Developer-ID builds and prepares the versioned ZIP, `appcast.xml`, and `SHA256.txt` under `.build/releases/vVERSION/`. Publish all three on the matching GitHub release to make the update available. The script does not publish or notarize the app.

## Status

Experimental. Trackpad input uses Apple’s private `MultitouchSupport` framework and has been verified on Apple Silicon. Native trackpad gestures may also respond. Tile movement works within the current workspace, and AeroSpace determines the final window sizes and positions.
