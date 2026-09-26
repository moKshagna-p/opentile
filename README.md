# OpenTile

**A little less window juggling. A little more flow.**

OpenTile is a native macOS menu bar app for tiling windows and moving between workspaces with trackpad gestures. Built on [AeroSpace](https://github.com/nikitabobko/AeroSpace), it brings gesture previews, drawn shortcuts, and a few optional desktop comforts into one app.

The tiling engine is included. Quit the standalone AeroSpace app before running OpenTile.

[Download](https://github.com/moKshagna-p/opentile/releases) · [Contributing](CONTRIBUTING.md) · [Report an issue](https://github.com/moKshagna-p/opentile/issues)

## What it does

- **Move and resize tiles** with two-finger gestures and a preview before you commit.
- **Draw a symbol** to switch workspaces or open an app.
- **See your workspaces** in the menu, or enable a split menu bar with app icons and system controls.
- **Switch with a short vertical slide**, with support for multiple displays and Reduce Motion.
- **Pick a wallpaper** from a searchable collection of your own images and videos.
- **Make it yours** with an optional Apple Music player and CodexBar usage meters.

OpenTile is experimental. Trackpad input uses Apple's private `MultitouchSupport` framework, and native macOS gestures may also respond. Feedback and small, focused contributions are welcome.

## Getting started

You'll need an **Apple Silicon Mac running macOS 14 or later**. Gesture controls require a built-in trackpad.

1. Download the app ZIP from [Releases](https://github.com/moKshagna-p/opentile/releases).
2. Extract it and move **OpenTile.app** to **Applications**.
3. Quit standalone AeroSpace, then open OpenTile.
4. Follow **Permission Setup**, then choose **Enable Gestures** from the menu bar.

**Accessibility** lets OpenTile move and resize windows. Optional **Screen Recording** permission enables workspace animation snapshots; images stay in memory, and switching still works without that permission. You can reopen **Permission Setup…** from the menu at any time. macOS may require reopening the app after a permission change.

The current v0.6.3 release is Apple Development signed and **not notarized**. Permission grants may need to be renewed after updates. See [RELEASING.md](RELEASING.md) for signing details.

## Everyday controls

Start with a focused tiled window.

| Action | Gesture |
| --- | --- |
| Move or swap | Pinch inward with two fingers, hold briefly, then move them together. Release over a tile's center to swap, or near its edge to insert. |
| Resize | Hold Option before touching the trackpad. Pinch inward to grow or spread outward to shrink, then lift to apply. |
| Switch workspace | Hold Control–Option, draw a saved symbol with one finger, then release the keys. |
| Open an app | Hold Option, draw a saved app symbol with one finger, then release Option. Two fingers still resize. |
| Cancel | Press Escape before applying the gesture. |

Choose **Draw to Switch Workspace → Teach a Workspace Symbol** to save three examples of a symbol. That menu also offers Control–Shift as an alternative shortcut.

For app symbols, choose **Draw to Open App → Teach an App Symbol**. Available apps are imported from the active Caps + O layer in `~/.config/karabiner/karabiner.json`; arbitrary Karabiner actions are not imported.

Workspace menus and controls work while gestures are paused. Drawing, menu, and `opentile://workspace?name=1` switches use OpenTile's transition; direct engine commands and automatic app routing do not. Reduce Motion skips the animation.

## Your desktop, your choice

### Split menu bar

Choose **Enable Split Menu Bar** for workspace buttons and app icons on the left, with network rates, sound, battery, clock, and OpenTile controls on the right. A soft glow along the bottom of each bar blends in a color from that display's wallpaper. The bar reserves space above tiled windows and hides for engine fullscreen workspaces.

Click network, sound, battery, or the clock to see a compact status dropdown with a link to the related macOS settings. Values refresh while each dropdown is open. The OpenTile control opens its usual menu.
The status controls use subtle hover and pressed capsules, and each dropdown shows a neutral activity, level, or date visual alongside its current values. The selected workspace capsule glides to the next workspace and scrolls it into view; Reduce Motion makes that change immediate.

Set the native macOS menu bar to automatically hide in System Settings first. OpenTile leaves that preference to you, and the native menu remains accessible at the top edge.

Optional integrations:

- **CodexBar:** install and configure [CodexBar](https://github.com/steipete/CodexBar), using a version with the `dashboard` command. The bar shows remaining usage; click for provider limits and reset times. Details follow CodexBar's used/remaining preference. Usage refreshes every three minutes while enabled.
- **Apple Music:** enable **Show Apple Music Player**, then open Music and play a song. macOS asks permission for OpenTile to control Music. Click the artwork for track details and playback controls. If local artwork is unavailable, OpenTile sends the song title, artist, and album to Apple's iTunes catalog to find a matching cover.

### Wallpapers

Press **Control–Option–W** or choose **Choose Wallpaper…**. Type to filter, use the arrow keys to select, and press Return to apply to every connected display's current desktop. Escape clears the search, then closes the picker. **Command–O** opens your wallpaper folder.

Add images or videos to `~/Pictures/Wallpapers`, including subfolders, and reopen the picker to refresh. Videos become still images stored in `~/Library/Application Support/OpenTile/Wallpaper Stills`; this isn't a live-video wallpaper player. The picker doesn't download wallpaper assets.

The carousel and reveal are inspired by [Omarchy](https://github.com/omacom/omarchy/tree/quattro/shell/plugins). Wallpaper changes use native macOS APIs and don't need Screen Recording permission.

## Configuration

OpenTile checks these locations before falling back to your AeroSpace configuration:

- `~/.opentile.toml`
- `${XDG_CONFIG_HOME:-~/.config}/opentile/opentile.toml`

Open or reload configuration from the menu. A separate AeroSpace installation isn't needed.

Sparkle provides in-app updates. You can check manually or enable automatic checks from the menu.

## Build and contribute

Use **Swift 6.2 or later** with compatible Command Line Tools; full Xcode isn't required. From the repository root:

```sh
scripts/test.sh
OPENTILE_SIGNING_IDENTITY="-" scripts/package.sh
```

The packaged app, ZIP, and checksum are written to `.build/package/`. Quit any running OpenTile instance before copying the app into Applications:

```sh
ditto .build/package/OpenTile.app /Applications/OpenTile.app
open /Applications/OpenTile.app
```

`-` creates an ad hoc signed development build, which may require granting permissions again. Set `OPENTILE_SIGNING_IDENTITY` to your own signing identity for a signed build; if omitted, the script selects an identity only when exactly one is available. A bare `swift run` executable doesn't support in-app updates.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the code layout, focused tests, and manual checks. [RELEASING.md](RELEASING.md) covers packaging and release signing. CI checks tests and builds; physical trackpad behavior, permissions, and visual smoothness still need testing on a Mac.

Found something odd? [Open an issue](https://github.com/moKshagna-p/opentile/issues) with your macOS version, OpenTile version, and steps to reproduce it. For gesture issues, include what you expected and what happened instead.

## Thanks

OpenTile builds on [AeroSpace](https://github.com/nikitabobko/AeroSpace) and [Sparkle](https://sparkle-project.org/), with interface inspiration from [Omarchy](https://github.com/omacom/omarchy). Bundled dependency licenses ship with the app.
