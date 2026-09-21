import Foundation
import Testing
@testable import AppBundle

struct TileResizeMotionTests {
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
        #expect(abs(motion.frame(at: 10.12).width - 575) < 0.001)
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
