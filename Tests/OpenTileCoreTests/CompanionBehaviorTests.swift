import Testing
@testable import OpenTileCore

struct CompanionBehaviorTests {
    @Test func attentionAndReactionAreBoundedAndReset() {
        var behavior = CompanionBehavior()
        behavior.greet()
        var lifted = false
        for i in 0..<120 {
            behavior.step(delta: 1.0 / 30, time: Double(i) / 30, attention: 100, drive: 100)
            lifted = lifted || behavior.lift > 0.05
            #expect(abs(behavior.head.position) <= 0.15)
            #expect(abs(behavior.waist.position) <= 0.15)
        }
        #expect(lifted)
        #expect(behavior.head.position < 0)
        #expect(behavior.lift == 0)
        behavior.reset()
        #expect(behavior.head.position == 0)
        #expect(behavior.waist.position == 0)
        #expect(behavior.breath == 0)
        behavior.step(delta: 1, time: .nan, attention: 0, drive: 0)
        #expect(behavior.lift == 0)
    }

    @Test func idleHasDistinctPoses() {
        var behavior = CompanionBehavior()
        var largestHead = 0.0
        var largestWaist = 0.0
        for i in 0..<570 {
            behavior.step(delta: 1.0 / 30, time: Double(i) / 30, attention: 0, drive: 0)
            largestHead = max(largestHead, behavior.head.position)
            largestWaist = max(largestWaist, behavior.waist.position)
        }
        #expect(largestHead > 0.07)
        #expect(largestWaist > 0.04)
    }
}
