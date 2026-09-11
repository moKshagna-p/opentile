# OpenTile

Trackpad gestures for [AeroSpace](https://github.com/nikitabobko/AeroSpace) on macOS. Move and resize tiled windows, or draw a symbol to switch workspaces.

OpenTile bundles an AeroSpace-based tiling engine with gesture controls and visual previews. Run OpenTile on its own; quit the separate AeroSpace app first.

## Features

- **Move tiles:** pinch and hold, then move two fingers to preview a swap or insertion.
- **Resize tiles:** hold Option and pinch inward to grow or outward to shrink. The orange preview stays within the display’s usable area.
- **Draw to switch:** teach OpenTile a number or symbol for each workspace using three examples, then draw it to switch.
- **Workspace overview:** the menu bar shows the active workspace; the Workspaces menu lists running apps and empty workspaces.
- **Existing configuration:** uses your AeroSpace configuration when no OpenTile configuration exists. Open and reload configuration from the menu.
- **Workspace animations:** drawing, menu, and OpenTile URL switches use a vertical slide transition, with support for Reduce Motion. Direct engine commands and automatic app routing do not animate.

## Requirements

- macOS 14 or later, an Apple Silicon Mac, and a built-in trackpad.
- Quit the separate AeroSpace app before starting OpenTile. The engine and CLI are bundled.
- Accessibility permission for OpenTile. Screen Recording permission enables workspace animations.
- Swift 6.2 or later to build from source. Full Xcode is needed for the XCTest suite; packaging works with a compatible Command Line Tools installation.

## Build and run

From the repository root:

```sh
bash scripts/package.sh
cp -R .build/package/OpenTile.app /Applications/
open /Applications/OpenTile.app
```

Allow the requested permissions, then select **Enable Gestures** from the OpenTile menu bar icon.

## Gestures

Start with a focused tiled window.

| Action | Gesture |
| --- | --- |
| Move or swap | Pinch inward with two fingers, hold briefly, then move them together. Release over another tile’s center to swap, or near its edge to insert. |
| Resize | Hold Option before touching the trackpad. Pinch inward to grow or spread outward to shrink, then lift to apply. |
| Switch workspace | Hold Control–Option, draw a saved symbol with one finger, then release the keys. |
| Cancel | Press Escape before applying the gesture. |

For a new workspace symbol, follow the training prompt or choose **Draw to Switch Workspace → Teach a Workspace Symbol**. The same menu lets you change the drawing shortcut to Control–Shift.

## Status

Experimental. Trackpad input uses Apple’s private `MultitouchSupport` framework and has been verified on Apple Silicon. Native trackpad gestures may also respond. Tile movement works within the current workspace, and AeroSpace determines the final window sizes and positions.
