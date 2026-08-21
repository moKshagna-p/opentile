# OpenTile

Gesture-driven window tiling for macOS. Pinch a window, fling it where you
want, release — it snaps back into the tiling tree. A gesture bridge that sits
on top of [AeroSpace](https://github.com/nikitabobko/AeroSpace) and makes
window movement feel physical.

```
Status: Phase 2 — Multitouch Bridge (raw touch capture verified)
Spec:   plan.html — full engineering spec & roadmap
```

## How it works

1. **Gesture input** — raw per-finger trackpad data via Apple's private
   `MultitouchSupport.framework` (~90–125 Hz, global, no Accessibility needed).
2. **Gesture engine** *(phase 3)* — pinch detection, centroid tracking,
   state machine: idle → grab → drag → release.
3. **Window bridge** *(phase 4)* — float/drag/re-tile via the Accessibility
   API + AeroSpace CLI.

The MTTouch struct layout was verified empirically on Apple Silicon by dumping
raw contact frames (96-byte stride — differs from pre-arm64 references).

## Build

```sh
./build.sh          # direct swiftc (see note inside; SPM blocked by local CLT bug)
.build/bin/OpenTile # touch the trackpad — watch the telemetry
```

Requires macOS 14+, built-in trackpad. No third-party dependencies.

## Roadmap

| Phase | Scope | Status |
|---|---|---|
| 1 | Scaffold & plan | ✅ |
| 2 | Multitouch bridge | 🔨 in progress |
| 3 | Gesture engine | planned |
| 4 | Window bridge (AX + AeroSpace) | planned |
| 5 | Integration & menu bar UI | planned |
| 6 | Polish & ship | planned |

Ponytail discipline: less code, more signal.
