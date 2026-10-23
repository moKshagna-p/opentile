# OpenTile

A native tiling window manager for macOS, built around trackpad gestures.

Built on [AeroSpace](https://github.com/nikitabobko/AeroSpace), OpenTile combines window tiling, gesture previews, and workspace shortcuts in a menu bar app. The tiling engine is included.

[Download](https://github.com/moKshagna-p/opentile/releases) · [Contributing](CONTRIBUTING.md) · [Report an issue](https://github.com/moKshagna-p/opentile/issues)

## Installation

Requires **Apple Silicon, macOS 14 or later**, and a built-in trackpad for gesture controls.

1. Download and extract the app ZIP from [Releases](https://github.com/moKshagna-p/opentile/releases).
2. Move **OpenTile.app** to **Applications** and quit standalone AeroSpace.
3. Open OpenTile, complete **Permission Setup**, and select **Enable Gestures**.

**Accessibility** is required to control windows. **Screen Recording** is optional and enables workspace animations using snapshots kept in memory. Workspace switching works without it.

Apple Development builds are not notarized. Updates or signing changes may require renewed permissions; see [release signing](RELEASING.md).

## Controls

Start with a focused tiled window. Movement previews show where a window will be placed before release.

| Action | Gesture |
| --- | --- |
| Move or swap | Pinch inward with two fingers, hold briefly, then move together. Release over a tile's center to swap or near its edge to insert. |
| Resize | Hold Option before touching the trackpad. Pinch inward to grow or spread outward to shrink; lift to apply. |
| Switch workspace | Hold Control–Option, draw a saved symbol with one finger, then release the keys. |
| Open an app | Hold Option, draw a saved app symbol with one finger, then release Option. |
| Cancel | Press Escape before applying a gesture. |

Teach symbols from **Draw to Switch Workspace** or **Draw to Open App** in the menu. Each symbol requires three examples. Workspace controls remain available while gestures are paused.

Resizing uses a short ease-out animation with neighboring tiles moving together. Reduce Motion skips the animation.

Trackpad support is experimental and uses Apple's private `MultitouchSupport` framework. Native macOS gestures may also respond.

## Desktop options

- **Split menu bar:** workspace buttons, app icons, and system controls. Set the native menu bar to auto-hide in macOS settings before enabling it.
- **Wallpapers:** press **Control–Option–W** to browse `~/Pictures/Wallpapers`. Visible thumbnails take priority while browsing. Images apply to all connected displays; videos are converted to stills.
- **Integrations:** optional [CodexBar](https://github.com/steipete/CodexBar) usage meters and Apple Music playback controls. Music requires Automation permission; artwork lookup may send track metadata to Apple's catalog.

**Phone Pad** is an experimental mobile companion in [PhonePad/](PhonePad/), available through development builds. It requires a separate mobile app and an HTTPS/WebSocket tunnel. Keep pairing QR codes private. Android has been tested on a physical device; iPhone flows and a dedicated security audit remain outstanding.

## Configuration

OpenTile reads `~/.opentile.toml` or `${XDG_CONFIG_HOME:-~/.config}/opentile/opentile.toml`, then falls back to an existing AeroSpace configuration. Open or reload configuration from the menu.

In-app updates are provided by Sparkle, with manual and automatic checks available from the menu.

## Development

Requires **Swift 6.2 or later** and compatible Command Line Tools. Full Xcode is not required for the Mac app.

```sh
scripts/test.sh
OPENTILE_SIGNING_IDENTITY="-" scripts/package.sh
```

Run from the repository root. Packaging writes an ad hoc signed app, ZIP, and checksum to `.build/package/`.

See [CONTRIBUTING.md](CONTRIBUTING.md) for development and testing, and [RELEASING.md](RELEASING.md) for signing and distribution.

## Acknowledgments

Built with [AeroSpace](https://github.com/nikitabobko/AeroSpace) and [Sparkle](https://sparkle-project.org/), with interface inspiration from [Omarchy](https://github.com/omacom/omarchy). Bundled dependency licenses ship with the app.
