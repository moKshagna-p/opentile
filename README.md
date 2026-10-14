# OpenTile

A native macOS menu bar app for tiling windows and switching workspaces with trackpad gestures. The [AeroSpace](https://github.com/nikitabobko/AeroSpace) tiling engine is included.

[Download](https://github.com/moKshagna-p/opentile/releases) · [Contribute](CONTRIBUTING.md) · [Report an issue](https://github.com/moKshagna-p/opentile/issues)

## Install

Requires **Apple Silicon, macOS 14 or later**, and a built-in trackpad for gesture controls.

1. Download the app ZIP from [Releases](https://github.com/moKshagna-p/opentile/releases).
2. Extract it and move **OpenTile.app** to **Applications**.
3. Quit standalone AeroSpace, then open OpenTile.
4. Follow **Permission Setup**, then choose **Enable Gestures** from the menu bar.

**Accessibility** is required to move and resize windows. Optional **Screen Recording** enables workspace animation snapshots, which stay in memory. Switching works without it. Reopen **Permission Setup…** from the menu if needed; macOS may require restarting the app after permission changes.

The v0.6.5 release is Apple Development signed and **not notarized**. Updates may require granting permissions again. See [signing details](RELEASING.md).

OpenTile is experimental and uses Apple's private `MultitouchSupport` framework. Native macOS gestures may also respond.

## Controls

Start with a focused tiled window.

| Action | Gesture or shortcut |
| --- | --- |
| Move or swap a tile | Pinch inward with two fingers, hold briefly, then move them together. Release over a tile's center to swap or near its edge to insert. |
| Resize a tile | Hold **Option** before touching the trackpad. Pinch inward to grow or spread outward to shrink, then lift to apply. |
| Switch workspace | Hold **Control–Option**, draw a saved symbol with one finger, then release the keys. |
| Open an app | Hold **Option**, draw a saved app symbol with one finger, then release Option. Two fingers still resize. |
| Choose wallpaper | **Control–Option–W** or **Choose Wallpaper…** in the menu. |
| Cancel a gesture | **Escape** before applying it. |

- Teach workspace symbols in **Draw to Switch Workspace → Teach a Workspace Symbol**, using three examples. That menu also offers **Control–Shift** as an alternative.
- Teach app symbols in **Draw to Open App → Teach an App Symbol**. Apps come from the active Caps + O layer in `~/.config/karabiner/karabiner.json`; arbitrary Karabiner actions are not imported.
- **Pause Gestures** and **Enable Gestures** persist across launches. Restoring gestures requires Accessibility permission and a supported trackpad. Workspace menus and commands remain usable while paused.
- Workspace switches from drawing, menus, and OpenTile URLs use the slide transition. Direct engine commands and automatic app routing skip it; **Reduce Motion** disables animation.

## Commands

### Build, test, and run

Requires **Swift 6.2 or later** with compatible Command Line Tools; full Xcode is not required. Run these commands from the repository root:

```sh
# Run automated tests
scripts/test.sh

# Run one test (replace the name with the test you need)
scripts/test.sh --filter gesturePollingStopsAndCanResumeWithoutDuplicateTimers

# Compile a release build
swift build -c release

# Package a local ad hoc signed app, ZIP, and checksum
OPENTILE_SIGNING_IDENTITY="-" scripts/package.sh

# Open the packaged app (quit any running OpenTile first)
open .build/package/OpenTile.app
```

Packaging writes to `.build/package/`. Ad hoc builds may require granting permissions again. For a signed build, set `OPENTILE_SIGNING_IDENTITY` to your own signing identity; if omitted, the script selects one only when exactly one is available. A bare `swift run` executable does not support in-app updates.

To install your local build, quit OpenTile first, then run these commands. **This replaces the installed app.**

```sh
ditto .build/package/OpenTile.app /Applications/OpenTile.app
open /Applications/OpenTile.app
```

### Switch workspaces from Terminal or a shortcut

With OpenTile installed, use these commands in Terminal or a keyboard shortcut:

```sh
# Switch to workspace 1 (replace 1 with a number or letter)
open -g -b com.mokshagna.opentile "opentile://workspace?name=1"

# Return to the previous workspace
open -g -b com.mokshagna.opentile "opentile://workspace?action=back-and-forth"
```

## Configuration and extras

OpenTile checks `~/.opentile.toml`, then `${XDG_CONFIG_HOME:-~/.config}/opentile/opentile.toml`, before falling back to your AeroSpace configuration. Open or reload it from the menu; a separate AeroSpace installation is not needed. In-app updates and automatic update checks are also available from the menu.

- **Split menu bar:** choose **Enable Split Menu Bar** for workspace buttons, app icons, and network, sound, battery, and clock controls. Set the native menu bar to automatically hide in System Settings first; it remains accessible at the top edge. OpenTile reserves space above tiles and hides its bar for engine fullscreen workspaces. The network dropdown samples traffic only while open and shows up to three active apps or processes.
- **Wallpapers:** add images or videos to `~/Pictures/Wallpapers`, including subfolders. Reopen the picker to refresh; type to search, use arrows to select, and press **Return** to apply across connected displays. **Escape** clears search, then closes; **Command–O** opens the folder. Videos become stills in `~/Library/Application Support/OpenTile/Wallpaper Stills`. Assets are not downloaded, and Screen Recording is not required.
- **Apple Music:** enable **Show Apple Music Player**, play a song in Music, and grant permission to control it. Click artwork for playback controls. If local artwork is missing, OpenTile sends the title, artist, and album to Apple's iTunes catalog to find a cover.
- **CodexBar:** install and configure [CodexBar](https://github.com/steipete/CodexBar) with support for its `dashboard` command. The bar shows remaining usage; click for limits and reset times. Details follow CodexBar's used/remaining preference. Usage refreshes every three minutes while enabled.

## Phone Pad (development preview)

Control the Mac cursor, clicks, scrolling, and tiling from an Android or iPhone app in [PhonePad/](PhonePad/). Build the Mac app from this checkout first; Phone Pad is not in the published release. Accessibility permission is required, but built-in trackpad gestures do not need to be enabled.

1. Start the phone development app:

   ```sh
   cd PhonePad
   npm ci
   npm start
   ```

   Open it in a matching Expo Go app on your phone. Expo's QR loads the app; it does not pair the Mac.

2. In another terminal, start an HTTPS tunnel that forwards WebSockets to OpenTile:

   ```sh
   ngrok http http://127.0.0.1:8765
   ```

   Choose **Pair Phone Pad…** on the Mac and paste the tunnel's HTTPS URL.

3. Choose **Scan pairing QR** in the phone app and scan OpenTile's QR.

Slide one finger to move the cursor, tap to click, or slide two fingers to scroll. To move a tile, pinch inward, hold briefly, move both fingers, then lift to place it. Select **Resize** before touching the pad to resize. **Cancel** on the phone or **Escape** on the Mac cancels a preview.

<details>
<summary>Phone Pad commands and connection limits</summary>

From the repository root, quit OpenTile and launch the packaged build with a tunnel URL to open pairing immediately:

```sh
OPENTILE_PHONE_PAD_ENDPOINT=https://your-tunnel.ngrok-free.app .build/package/OpenTile.app/Contents/MacOS/OpenTile
```

Run these commands from `PhonePad/` as needed:

```sh
# Tunnel the Expo development server across networks
npx expo start --tunnel

# Build and run on Android (requires Android SDK)
npm run android

# Build and run on iPhone (requires full Xcode and appropriate signing)
npm run ios
```

The Mac tunnel works across networks and requires internet access and a tunnel provider. Automatic LAN discovery and direct offline connections are not implemented. A packaged phone app does not need Expo's development server; no APK or App Store build is distributed yet.

Keep the pairing QR private: it contains a random control key. Input and responses use authenticated AES-GCM encryption in addition to TLS. The phone saves pairing in secure storage; the Mac keeps its key only for the current pairing session. **Stop Phone Pad**, a new pairing, pausing gestures, Mac sleep, or quitting revokes it.

Brief input delays cancel the preview; lift all fingers to resume. The connection tolerates up to ten seconds without an authenticated heartbeat. Backgrounding the phone, losing Accessibility permission, or losing the connection cancels the preview and requires reconnecting. Scrolling remains scrolling until all fingers lift, and an interrupted pinch cannot commit a delayed release.

Android pairing has been exercised on a physical phone. iPhone camera and permission flows, broader device and gesture coverage, and tunnel latency still need manual testing. This preview has not had a dedicated security audit.

</details>

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development and manual checks, and [RELEASING.md](RELEASING.md) for release packaging and signing. CI checks tests and builds; trackpad behavior, privacy dialogs, and visual smoothness need testing on a Mac.

[Report issues](https://github.com/moKshagna-p/opentile/issues) with your macOS version, OpenTile version, and steps to reproduce.

Built on [AeroSpace](https://github.com/nikitabobko/AeroSpace) and [Sparkle](https://sparkle-project.org/), with interface inspiration from [Omarchy](https://github.com/omacom/omarchy). Bundled dependency licenses ship with the app.
