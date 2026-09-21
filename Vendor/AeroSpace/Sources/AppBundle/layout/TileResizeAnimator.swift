import AppKit

/// A short ease-out, sampled on one clock for all neighboring tiles.
struct TileResizeMotion {
    let from: CGRect
    let to: CGRect
    let start: TimeInterval
    static let duration: TimeInterval = 0.24

    func frame(at time: TimeInterval) -> CGRect {
        let t = min(1, max(0, (time - start) / Self.duration))
        let progress = 1 - pow(1 - t, 3)
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * progress }
        return CGRect(x: mix(from.minX, to.minX), y: mix(from.minY, to.minY),
                      width: mix(from.width, to.width), height: mix(from.height, to.height))
    }
}

@MainActor
final class TileResizeAnimator {
    static let shared = TileResizeAnimator()
    private var pending: [UInt32: (frame: CGRect, time: TimeInterval)] = [:]
    private var motions: [UInt32: TileResizeMotion] = [:]
    private var ticker: Task<Void, Never>?

    var isAnimating: Bool { ticker != nil }

    func schedule(_ id: UInt32, from: CGRect, to: CGRect, at time: TimeInterval) {
        motions[id] = TileResizeMotion(from: from, to: to, start: time)
        startTicker()
    }

    func prepare(_ windows: [Window]) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for window in windows {
            guard let rect = window.lastAppliedLayoutPhysicalRect else { continue }
            let frame = motions[window.windowId]?.frame(at: now)
                ?? CGRect(origin: rect.topLeftCorner, size: rect.size)
            pending[window.windowId] = (frame, now)
        }
    }

    /// Identical refreshes preserve an animation; unrelated moves interrupt it.
    func apply(_ window: MacWindow, _ point: CGPoint?, _ size: CGSize?) -> Bool {
        let id = window.windowId
        guard let point, let size,
              TrayMenuModel.shared.isEnabled,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            cancel(id)
            return false
        }
        let target = CGRect(origin: point, size: size)
        let now = ProcessInfo.processInfo.systemUptime
        if let prepared = pending.removeValue(forKey: id), now - prepared.time < 0.5,
           prepared.frame != target {
            schedule(id, from: prepared.frame, to: target, at: prepared.time)
            return true
        }
        if motions[id]?.to == target { return true }
        cancel(id)
        return false
    }

    func cancel(_ id: UInt32) {
        pending.removeValue(forKey: id)
        motions.removeValue(forKey: id)
        if motions.isEmpty { ticker?.cancel(); ticker = nil }
    }

    func cancelAll() {
        ticker?.cancel()
        ticker = nil
        pending.removeAll()
        motions.removeAll()
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { @MainActor in
            while !Task.isCancelled {
                tick()
                if motions.isEmpty { ticker = nil; return }
                do { try await Task.sleep(nanoseconds: 16_666_667) }
                catch { return }
            }
        }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        for (id, motion) in motions {
            guard let window = MacWindow.allWindowsMap[id],
                  !window.isHiddenInCorner,
                  currentlyManipulatedWithMouseWindowId != id else {
                motions.removeValue(forKey: id)
                continue
            }
            let finished = now - motion.start >= TileResizeMotion.duration
                || !TrayMenuModel.shared.isEnabled
                || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            let frame = finished ? motion.to : motion.frame(at: now)
            window.macApp.setAxFrame(id, frame.origin, frame.size)
            if finished { motions.removeValue(forKey: id) }
        }
    }
}
