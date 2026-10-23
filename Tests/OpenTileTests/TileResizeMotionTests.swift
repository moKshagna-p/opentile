import Foundation
import Common
import Testing
@testable import AppBundle

struct TileResizeMotionTests {
    @Test @MainActor func neighboringTilesFinishWithin160Milliseconds() {
        let animator = TileResizeAnimator()
        defer { animator.cancelAll() }
        let left = CGRect(x: 0, y: 0, width: 600, height: 600)
        let right = CGRect(x: 610, y: 0, width: 400, height: 600)
        animator.schedule(1, from: CGRect(x: 0, y: 0, width: 400, height: 600), to: left, at: 0)
        animator.schedule(2, from: CGRect(x: 410, y: 0, width: 600, height: 600), to: right, at: 0)
        var frames: [UInt32: CGRect] = [:]
        animator.tick(at: 0.08) { id, frame in frames[id] = frame; return true }
        #expect(frames[1] != left && frames[2] != right)
        #expect(abs(frames[2]!.minX - frames[1]!.maxX - 10) < 0.001)
        animator.tick(at: 0.16) { id, frame in frames[id] = frame; return true }
        #expect(frames[1] == left && frames[2] == right)
        animator.tick(at: 0.18) { _, _ in Issue.record("Resize missed its completion budget"); return true }
    }

    @Test @MainActor func animationNotificationBurstReconcilesOnceAfterFinalFrames() {
        var refreshes = 0
        let animator = TileResizeAnimator(refresh: { _ in refreshes += 1 })
        defer { animator.cancelAll() }
        let from = CGRect(x: 0, y: 0, width: 400, height: 600)
        let to = CGRect(x: 0, y: 0, width: 600, height: 600)
        for id in UInt32(1)...2 { animator.schedule(id, from: from, to: to, at: 0) }
        for _ in 0..<200 {
            #expect(animator.deferRefresh(.ax("AXMoved"), for: 1, mouseDown: false))
            #expect(animator.deferRefresh(.ax("AXResized"), for: 2, mouseDown: false))
        }
        var frames: [UInt32: CGRect] = [:]
        animator.tick(at: 0.1) { id, frame in frames[id] = frame; return true }
        #expect(refreshes == 0)
        #expect(frames.count == 2)
        animator.tick(at: TileResizeMotion.duration) { id, frame in
            #expect(refreshes == 0)
            frames[id] = frame
            return true
        }
        #expect(frames[1] == to && frames[2] == to)
        #expect(refreshes == 1)
        animator.tick(at: 1) { _, _ in Issue.record("Completed motion wrote another frame"); return true }
        #expect(refreshes == 1)
        #expect(!animator.deferRefresh(.ax("AXResized"), for: 1, mouseDown: false))
    }

    @Test @MainActor func unrelatedWindowsAndMouseInputKeepImmediateRefreshes() {
        let animator = TileResizeAnimator(refresh: { _ in Issue.record("No refresh was deferred") })
        defer { animator.cancelAll() }
        animator.schedule(1, from: .zero, to: .zero, at: 0)
        #expect(!animator.deferRefresh(.ax("AXMoved"), for: nil, mouseDown: false))
        #expect(!animator.deferRefresh(.ax("AXResized"), for: 2, mouseDown: false))
        #expect(!animator.deferRefresh(.ax("AXResized"), for: 1, mouseDown: true))
        animator.cancel(1)
    }

    @Test @MainActor func retargetingAndPartialCancellationKeepOneReconciliation() {
        var refreshes = 0
        let animator = TileResizeAnimator(refresh: { _ in refreshes += 1 })
        defer { animator.cancelAll() }
        animator.schedule(1, from: .zero, to: .zero, at: 0)
        animator.schedule(2, from: .zero, to: .zero, at: 0)
        #expect(animator.deferRefresh(.ax("AXResized"), for: 1, mouseDown: false))
        animator.schedule(1, from: .zero, to: .zero, at: 0.1)
        animator.cancel(2)
        #expect(refreshes == 0)
        animator.cancel(1)
        #expect(refreshes == 1)
        animator.cancel(1)
        #expect(refreshes == 1)
        animator.schedule(1, from: .zero, to: .zero, at: 1)
        animator.cancel(1)
        #expect(refreshes == 1)
    }

    @Test @MainActor func unavailableWindowStillReconcilesDeferredNotifications() {
        var refreshes = 0
        let animator = TileResizeAnimator(refresh: { _ in refreshes += 1 })
        defer { animator.cancelAll() }
        animator.schedule(1, from: .zero, to: .zero, at: 0)
        #expect(animator.deferRefresh(.ax("AXMoved"), for: 1, mouseDown: false))
        animator.tick(at: 0.1) { _, _ in false }
        #expect(refreshes == 1)
    }

    @Test @MainActor func mouseTakeoverStopsFramesAndReconciles() {
        let previous = currentlyManipulatedWithMouseWindowId
        defer { currentlyManipulatedWithMouseWindowId = previous }
        var refreshes = 0
        let animator = TileResizeAnimator(refresh: { _ in refreshes += 1 })
        defer { animator.cancelAll() }
        animator.schedule(1, from: .zero, to: .zero, at: 0)
        #expect(animator.deferRefresh(.ax("AXResized"), for: 1, mouseDown: false))
        currentlyManipulatedWithMouseWindowId = 1
        animator.tick(at: 0.1) { _, _ in Issue.record("Animation interfered with mouse"); return true }
        #expect(refreshes == 1)
    }

    @Test @MainActor func shutdownDiscardsDeferredWorkAndRestartHasNoStaleRefresh() {
        var refreshes = 0
        let animator = TileResizeAnimator(refresh: { _ in refreshes += 1 })
        defer { animator.cancelAll() }
        animator.schedule(1, from: .zero, to: .zero, at: 0)
        #expect(animator.deferRefresh(.ax("AXResized"), for: 1, mouseDown: false))
        animator.cancelAll()
        animator.schedule(2, from: .zero, to: .zero, at: 0)
        animator.tick(at: 1) { _, _ in true }
        #expect(refreshes == 0)
    }

    @Test @MainActor func rapidRetargetingCanCancelEveryWindowAndRestart() {
        let animator = TileResizeAnimator()
        let from = CGRect(x: 0, y: 0, width: 400, height: 600)
        for index in 0..<10_000 {
            let target = CGRect(x: 0, y: 0, width: index.isMultiple(of: 2) ? 600 : 400, height: 600)
            animator.schedule(UInt32(index % 8), from: from, to: target, at: Double(index))
        }
        #expect(animator.isAnimating)
        for id in UInt32(0)..<8 { animator.cancel(id) }
        #expect(!animator.isAnimating)
        animator.schedule(0, from: from, to: from, at: 0)
        #expect(animator.isAnimating)
        animator.cancelAll()
        #expect(!animator.isAnimating)
    }

    @Test @MainActor func cancellationStopsClockAfterLastWindowAndAllowsRestart() {
        let animator = TileResizeAnimator()
        let from = CGRect(x: 0, y: 0, width: 400, height: 600)
        let to = CGRect(x: 0, y: 0, width: 600, height: 600)
        #expect(!animator.isAnimating)
        animator.schedule(1, from: from, to: to, at: 0)
        animator.schedule(2, from: from, to: to, at: 0)
        animator.cancel(1)
        #expect(animator.isAnimating)
        animator.cancel(2)
        #expect(!animator.isAnimating)
        animator.schedule(3, from: from, to: to, at: 0)
        #expect(animator.isAnimating)
        animator.cancelAll()
        #expect(!animator.isAnimating)
    }

    @Test func resizeEasesAndClampsToExactEndpoints() {
        let from = CGRect(x: 10, y: 20, width: 400, height: 600)
        let to = CGRect(x: 10, y: 20, width: 600, height: 600)
        let motion = TileResizeMotion(from: from, to: to, start: 10)
        #expect(motion.frame(at: 9) == from)
        #expect(abs(motion.frame(at: 10 + TileResizeMotion.duration / 2).width - 575) < 0.001)
        #expect(motion.frame(at: 11) == to)
    }

    @Test func neighboringEdgesStayTogetherWhileGrowingAndShrinking() {
        for delta in [-200.0, 200.0] {
            let left = TileResizeMotion(from: CGRect(x: 0, y: 0, width: 500, height: 600),
                                        to: CGRect(x: 0, y: 0, width: 500 + delta, height: 600), start: 0)
            let right = TileResizeMotion(from: CGRect(x: 510, y: 0, width: 500, height: 600),
                                         to: CGRect(x: 510 + delta, y: 0, width: 500 - delta, height: 600), start: 0)
            for time in stride(from: 0.0, through: 0.3, by: 0.01) {
                #expect(abs(right.frame(at: time).minX - left.frame(at: time).maxX - 10) < 0.001)
            }
        }
    }

    @Test func interruptedResizeStartsAtCurrentFrame() {
        let first = TileResizeMotion(from: CGRect(x: 0, y: 0, width: 400, height: 600),
                                     to: CGRect(x: 0, y: 0, width: 600, height: 600), start: 0)
        let current = first.frame(at: 0.1)
        let next = TileResizeMotion(from: current, to: first.from, start: 0.1)
        #expect(next.frame(at: 0.1) == current)
        #expect(next.frame(at: 1) == first.from)
    }
}
