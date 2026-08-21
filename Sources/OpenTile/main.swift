// OpenTile — gesture-driven window tiling for macOS.
// Extends AeroSpace with smooth trackpad gesture control.
//
// Phase 2 — Multitouch Bridge:
//   Registers a global contact-frame callback on the built-in trackpad and
//   prints raw finger telemetry so we can verify capture works everywhere.
//
// Run: swift run   (touch the trackpad, Ctrl-C to stop)

import Foundation
import OpenTileC

/// One finger, decoded from a raw MTTouch record.
struct Finger {
    let id: Int          // stable while the finger stays down
    let state: Int       // 1–7; 4 == firm contact
    let x: Double        // normalized 0…1
    let y: Double
    let pressure: Float  // 0…1
    let angle: Float     // contact ellipse rotation, degrees
    let radius: Float    // contact ellipse major radius
}

/// Wraps the default MTDevice and forwards contact frames to `onFrame`.
/// ponytail: process-lifetime singleton — no stop/release paths until a phase needs them.
final class MultitouchBridge {
    typealias FrameHandler = (_ fingers: [Finger], _ frame: Int) -> Void

    private var device: MTDeviceRef?

    // The C callback can't capture context, so the handler lives in static
    // storage. Callbacks arrive on the framework's own thread.
    nonisolated(unsafe) private static var handler: FrameHandler?

    // Console throttling state (touched from the callback thread).
    nonisolated(unsafe) fileprivate static var lastPrint = Date.distantPast
    nonisolated(unsafe) fileprivate static var lastSignature = ""

    init(onFrame: @escaping FrameHandler) {
        Self.handler = onFrame
    }

    func start() {
        guard device == nil else { return }
        device = MTDeviceCreateDefault()
        MTRegisterContactFrameCallback(device!, { _, touches, count, _, frame in
            guard let touches = touches else { return 0 }
            var fingers: [Finger] = []
            fingers.reserveCapacity(Int(count))
            for i in 0..<Int(count) {
                let t = touches[i]
                fingers.append(Finger(
                    id: Int(t.identifier),
                    state: Int(t.state),
                    x: Double(t.x),
                    y: Double(t.y),
                    pressure: t.pressure,
                    angle: t.angle,
                    radius: t.radius
                ))
            }
            MultitouchBridge.handler?(fingers, Int(frame))
            return 0
        })
        MTDeviceStart(device!, 0)
    }
}

// MARK: - Phase 2 verification console

let bridge = MultitouchBridge { fingers, frame in
    guard !fingers.isEmpty else { return }

    // Throttle: print at most every 80 ms so the console stays readable,
    // but always print immediately when the finger set changes.
    let signature = fingers.map { "\($0.id):\($0.state)" }.joined(separator: ",")
    let now = Date()
    guard signature != MultitouchBridge.lastSignature
            || now.timeIntervalSince(MultitouchBridge.lastPrint) > 0.08 else { return }
    MultitouchBridge.lastPrint = now
    MultitouchBridge.lastSignature = signature

    let parts = fingers.map { f in
        String(format: "#%d (%.3f, %.3f) p:%.2f r:%.0f a:%+.0f° s:%d",
               f.id, f.x, f.y, f.pressure, f.radius, f.angle, f.state)
    }
    print("[\(frame)] \(parts.joined(separator: "  "))")
}

signal(SIGINT) { _ in
    print("\n— capture ended —")
    exit(0)
}

print("OpenTile · phase 2 — listening to the built-in trackpad.")
print("Touch the trackpad anywhere; Ctrl-C to stop.\n")

bridge.start()

dispatchMain()
