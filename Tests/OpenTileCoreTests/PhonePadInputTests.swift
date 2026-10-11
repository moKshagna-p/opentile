import Testing
import CoreGraphics
@testable import OpenTileCore

struct PhonePadInputTests {
    func pair(_ radius: Double = 0.15, x: Double = 0.5) -> [Contact] {
        [Contact(id: 1, x: x-radius, y: 0.5), Contact(id: 2, x: x+radius, y: 0.5)]
    }
    @Test func phonePinchUsesTrackpadHoldAndRelease() {
        var pad = PhonePadInput()
        #expect(pad.update(pair(), time: 0).isEmpty)
        #expect(pad.update(pair(0.1), time: 0.1).isEmpty)
        #expect(pad.update(pair(0.1), time: 0.3) == [.gesture(.began(CGPoint(x: 0.5, y: 0.5)))])
        #expect(pad.update(pair(0.1, x: 0.6), time: 0.4) == [.gesture(.moved(CGPoint(x: 0.6, y: 0.5)))])
        #expect(pad.update([], time: 0.5) == [.gesture(.released)])
        #expect(pad.update([], time: 0.6).isEmpty)
    }
    @Test func scrollingCannotBecomeTilingOrTap() {
        var pad = PhonePadInput()
        _ = pad.update(pair(), time: 0)
        let events = pad.update(pair(x: 0.6), time: 0.1)
        guard case .scroll = events.first else { Issue.record("Expected scrolling"); return }
        #expect(pad.update(pair(0.1, x: 0.6), time: 0.2).allSatisfy { if case .scroll = $0 { return true }; return false })
        #expect(pad.update([], time: 0.3).isEmpty)
    }
    @Test func tapMovementAndCancellation() {
        var pad = PhonePadInput()
        let one = [Contact(id: 1, x: 0.5, y: 0.5)]
        _ = pad.update(one, time: 0)
        #expect(pad.update([], time: 0.1) == [.click])
        _ = pad.update(one, time: 1)
        #expect(pad.update([Contact(id: 1, x: 0.6, y: 0.5)], time: 1.1).count == 1)
        #expect(pad.update([], time: 1.2).isEmpty)
        _ = pad.update(one, time: 2)
        pad.cancel()
        #expect(pad.update(one, time: 2.1).isEmpty)
        #expect(pad.update([], time: 2.2).isEmpty)
        _ = pad.update(one, time: 3)
        #expect(pad.update([], time: 3.1) == [.click])
    }
    @Test func partialLiftDoesNotMoveOrClickAndResizeLocksAtFirstTouch() {
        var pad = PhonePadInput()
        _ = pad.update([pair()[0]], time: 0, resize: true)
        _ = pad.update(pair(), time: 0.01)
        guard case .gesture(.resizeBegan) = pad.update(pair(0.1), time: 0.1).first else { Issue.record("Expected resize"); return }
        #expect(pad.update([pair(0.1)[0]], time: 0.2) == [.gesture(.released)])
        #expect(pad.update([Contact(id: 1, x: 0.7, y: 0.5)], time: 0.21).isEmpty)
        #expect(pad.update([], time: 0.22).isEmpty)
    }
    @Test func invalidContactsCancelAndRequireLift() {
        var pad = PhonePadInput()
        _ = pad.update(pair(), time: 0)
        #expect(pad.update([Contact(id: 1, x: .nan, y: 0)], time: 0.1) == [.gesture(.cancelled)])
        #expect(pad.update(pair(0.1), time: 0.4).isEmpty)
        #expect(pad.update([], time: 0.5).isEmpty)
    }
}
