# Performance benchmarks

Measurements collected on 21–22 October 2026 on an **Apple M3 Mac with 8 GiB RAM, macOS 27.0, and Swift 6.3.3**. These results compare specific earlier OpenTile implementations with the optimizations now included in `main`.

## Measured improvements

Lower values are better. Reductions are calculated as `(before − after) / before`; each row has its own workload and baseline.

| Workload | Before | After | Reduction |
| --- | ---: | ---: | ---: |
| Command transport, `/usr/bin/true` | 13.134 ms | 1.910 ms | 85.5% |
| Adjacent-window swap, observed completion | 108.19 ms | 42.03 ms | 61.2% |
| Swap across five tree positions, observed completion | 288.12 ms | 40.82 ms | 85.8% |
| Move-preview batch, 8 frames at 60 Hz | 3.316 ms | 1.349 ms | 59.3% |
| Resize-preview batch, 8 frames at 60 Hz | 2.388 ms | 0.806 ms | 66.2% |
| Symbol matching, 10 targets / 192 points | 0.482 ms | 0.415 ms | 13.8% |
| Symbol matching, 100 targets / 192 points | 4.817 ms | 4.157 ms | 13.7% |
| Symbol matching, 100 targets / 4,096 points | 19.385 ms | 10.536 ms | 45.6% |
| Unchanged drawing, redraw invalidations over 60 ticks | 60 | 0 | 100% |
| Unchanged drawing, preview matches over 60 ticks | 7 | 0 | 100% |

These are operation timings and work counts, not an overall application speedup. Preview and matcher inputs are synthetic. No battery-life improvement is established.

## Method and scope

### Command transport

The original polling wait was compared with process-termination signaling while retaining temporary-file output handling. Both paths launched `/usr/bin/true`, isolating transport overhead from window-manager work. Three runs used 10 warmups and 80 alternating paired trials each.

| Run | Before median / p95 | After median / p95 |
| --- | ---: | ---: |
| 1 | 13.000 / 13.269 ms | 1.348 / 2.251 ms |
| 2 | 13.134 / 13.502 ms | 1.910 / 3.206 ms |
| 3 | 13.138 / 13.592 ms | 1.933 / 2.723 ms |

The headline uses the median of the three reported run medians. The original harness reports the lower middle sample as its median. This change is in [574fad9](https://github.com/moKshagna-p/opentile/commit/574fad9).

### Window swaps

The original OpenTile caller at [ec0fe8a](https://github.com/moKshagna-p/opentile/commit/ec0fe8a) was compared with the direct-swap API at [3093947](https://github.com/moKshagna-p/opentile/commit/3093947), merged in [#8](https://github.com/moKshagna-p/opentile/pull/8).

A release-optimized native harness used six fixture windows in one app on one display. Both modes used the same engine, configuration, and Apple Development signing identity. Starting window order was reset and asserted before each trial. Timing ended when external Core Graphics and Accessibility observations confirmed the expected geometry and source focus.

There were three runs of five measured trials per mode and distance: **60 measured swaps, eight warmups, zero headline failures**. All six window positions and final focus were checked. Timings include observer polling overhead and exclude gesture recognition and preview setup.

| Workload | Before run medians | After run medians |
| --- | ---: | ---: |
| Adjacent | 103.18, 110.92, 108.19 ms | 46.81, 42.03, 41.61 ms |
| Distance five | 287.39, 288.12, 297.49 ms | 40.82, 34.89, 43.28 ms |

The headline uses the median of the three run medians. Diagnostic traces showed normal engine sessions falling from **7 to 1** for adjacent swaps and **23 to 1** at distance five. The baseline is OpenTile's former focus-walking implementation; it is not stock AeroSpace.

### Gesture previews

The immediate-dispatch loop was compared with the production coalescer from [e4058ca](https://github.com/moKshagna-p/opentile/commit/e4058ca), merged in [#9](https://github.com/moKshagna-p/opentile/pull/9). Both paths used the corrected production renderer, isolating coalescing from the label-sizing fix.

Each mode used three paired five-second runs of 300 ticks at 60 Hz, with **eight synthetic contact frames per tick** and a three-window snapshot. Headline timings are medians of per-run median synchronous batch-service times. Final preview geometry and destination matched between paths.

Helper-process CPU also fell from **19.70% to 10.83% of one core** for move previews and **13.01% to 7.43%** for resize previews. This includes helper run-loop work, excludes WindowServer/GPU work, and does not measure total OpenTile CPU.

This is a burst stress workload. No single-frame speedup was established, and synchronous service time excludes deferred rendering. The harness did not run a live engine, commit windows, or measure physical input-to-display latency.

### Drawing

Matcher results compare the original normalization with the Swift implementation in [21bd248](https://github.com/moKshagna-p/opentile/commit/21bd248). The benchmark linked actual SwiftPM release objects, used three templates per target, and collected three runs of 40 trials per size after five warmups. Headline values are pooled medians across 120 trials per implementation and size. Recognition parity was checked across 527 drawings and all timed expected results.

Unchanged-ink counts compare the earlier drawing controller at that revision with [90116cf](https://github.com/moKshagna-p/opentile/commit/90116cf). The production controller ran with synthetic timestamps and a stationary 20-point symbol; AppKit display work was drained between ticks. These are invalidation and matching counts, not rendered-frame or energy measurements. Final release matching remains separate.

## Comparison with AeroSpace

OpenTile embeds AeroSpace and adds its gesture interface. AeroSpace's [official guide](https://nikitabobko.github.io/AeroSpace/guide) documents keyboard bindings, CLI commands, tree layouts, and virtual workspaces.

| Aspect | Stock AeroSpace | OpenTile |
| --- | --- | --- |
| Window management | AeroSpace tiling engine | Embedded AeroSpace engine with local changes |
| Interaction | Keyboard bindings and CLI | Trackpad gestures, drawn shortcuts, and engine controls |
| Recorded optimization baseline above | Not measured | Earlier OpenTile implementations |
| Matched focus latency, CPU, and energy comparison | Not collected | Not collected |

**These results do not establish that OpenTile is faster or more energy-efficient than stock AeroSpace.** A valid performance comparison needs matching releases, configuration, apps, windows, displays, input method, and power conditions, with one manager running at a time.

For a future comparison, [benchmark-focus.py](scripts/benchmark-focus.py) collects OS-observed focus separately from command return, and [measure-performance.py](scripts/measure-performance.py) samples process CPU and memory. Repeat paired runs, retain failures and observer overhead, and measure paused, idle, and active workloads separately. The process sampler alone does not measure subprocess, WindowServer, GPU, or battery cost.

The one-off swap, preview, transport, and matcher harnesses used here are not included in the repository; the tables preserve their recorded summaries and methods. Treat these results as measurements of the described workloads on one machine, rather than independently reproducible release-wide benchmarks.
