import Foundation
import Testing
import CoreGraphics
@testable import OpenTileCore

struct GestureTests {
    func contacts(_ radius: Double = 0.15, x: Double = 0.5) -> [Contact] {
        [Contact(id: 1, x: x-radius, y: 0.5), Contact(id: 2, x: x+radius, y: 0.5)]
    }
    func arm(_ recognizer: inout GestureRecognizer) {
        #expect(recognizer.update(contacts(), time: 0) == nil)
        #expect(recognizer.update(contacts(0.10), time: 0.1) == nil)
        #expect((recognizer.update(contacts(0.10), time: 0.3)) == (.began(CGPoint(x: 0.5, y: 0.5))))
    }
    @Test
    func sustainedGestureReplayDoesNotRetainReleasedState() {
        var recognizer = GestureRecognizer()
        for cycle in 0..<2_000 {
            let time = Double(cycle) * 2
            #expect(recognizer.update(contacts(), time: time) == nil)
            #expect(recognizer.update(contacts(0.1), time: time + 0.1) == nil)
            #expect(recognizer.update(contacts(0.1), time: time + 0.4) == .began(CGPoint(x: 0.5, y: 0.5)))
            #expect(recognizer.update(contacts(0.1, x: 0.6), time: time + 0.5) == .moved(CGPoint(x: 0.6, y: 0.5)))
            #expect(recognizer.update([], time: time + 0.6) == .released)
            #expect(recognizer.update([], time: time + 0.7) == nil)
        }
    }

    @Test
    func testPinchHoldDragRelease() {
        var r = GestureRecognizer(); arm(&r)
        #expect((r.update(contacts(0.1, x: 0.6), time: 0.4)) == (.moved(CGPoint(x: 0.6, y: 0.5))))
        #expect((r.update([], time: 0.5)) == (.released))
        #expect(r.update([], time: 0.6) == nil)
    }
    @Test
    func testUnpinchedSwipeDoesNotArm() {
        var r = GestureRecognizer()
        #expect(r.update(contacts(), time: 0) == nil)
        #expect(r.update(contacts(x: 0.6), time: 1) == nil)
        #expect(r.update([], time: 2) == nil)
    }
    @Test
    func testOneAndThreeFingerPinchesDoNotArm() {
        for count in [1, 3] {
            var r = GestureRecognizer()
            func frame(_ radius: Double) -> [Contact] {
                let pair = contacts(radius)
                return count == 1 ? [pair[0]] : pair + [Contact(id: 3, x: 0.5, y: 0.5)]
            }
            #expect(r.update(frame(0.15), time: 0) == nil)
            #expect(r.update(frame(0.10), time: 0.1) == nil)
            #expect(r.update(frame(0.10), time: 0.4) == nil)
            #expect(r.update([], time: 0.5) == nil)
        }
    }
    @Test
    func testBriefPinchDoesNotArm() {
        var r = GestureRecognizer()
        _ = r.update(contacts(), time: 0)
        _ = r.update(contacts(0.1), time: 0.1)
        #expect(r.update([], time: 0.2) == nil)
    }
    @Test
    func testMovementRestartsHold() {
        var r = GestureRecognizer()
        _ = r.update(contacts(), time: 0)
        _ = r.update(contacts(0.1), time: 0.1)
        #expect(r.update(contacts(0.1, x: 0.6), time: 0.3) == nil)
        #expect((r.update(contacts(0.1, x: 0.6), time: 0.5)) == (.began(CGPoint(x: 0.6, y: 0.5))))
    }
    @Test
    func testEscapeBlocksUntilLift() {
        var r = GestureRecognizer(); arm(&r)
        #expect((r.cancel()) == (.cancelled))
        #expect(r.update(contacts(0.1), time: 1) == nil)
        #expect(r.update([], time: 2) == nil)
        #expect(r.update(contacts(), time: 3) == nil)
        #expect(r.update(contacts(0.1), time: 3.1) == nil)
        #expect(r.update(contacts(0.1), time: 3.4) != nil)
    }
    @Test
    func testPartialLiftReleasesOnlyOnce() {
        var r = GestureRecognizer(); arm(&r)
        #expect((r.update(Array(contacts().prefix(1)), time: 0.4)) == (.released))
        #expect(r.update([], time: 0.5) == nil)
    }
    @Test
    func testExtraFingerCancels() {
        var r = GestureRecognizer(); arm(&r)
        #expect((r.update(contacts() + [Contact(id: 4, x: 0.7, y: 0.7)], time: 0.4)) == (.cancelled))
        #expect(r.update([], time: 0.5) == nil)
    }
    @Test
    func testReplacedFingerCancels() {
        var r = GestureRecognizer(); arm(&r)
        #expect((r.update([contacts()[0], Contact(id: 4, x: 0.5, y: 0.5)], time: 0.4)) == (.cancelled))
    }
    @Test
    func testInvalidFrameCancels() {
        var r = GestureRecognizer(); arm(&r)
        #expect((r.update([], time: .nan)) == (.cancelled))
        #expect(r.update([], time: 0.5) == nil)
    }
    @Test
    func testBackwardsTimestampCancels() {
        var r = GestureRecognizer(); arm(&r)
        #expect((r.update(contacts(), time: 0.2)) == (.cancelled))
    }
    @Test
    func testOptionPinchInwardAndOutwardResize() {
        for radius in [0.10, 0.20] {
            var r = GestureRecognizer()
            #expect(r.update(contacts(), time: 0, optionHeld: true) == nil)
            let event = r.update(contacts(radius), time: 0.1, optionHeld: true)
            guard case .resizeBegan(let change) = event else { Issue.record("Expected resize"); continue }
            #expect((change > 0) == (radius < 0.15))
            // Returning to the initial spread undoes the requested change.
            #expect((r.update(contacts(), time: 0.2, optionHeld: true)) == (.resized(0)))
            #expect((r.update([], time: 0.3)) == (.released))
            #expect(r.update([], time: 0.4) == nil)
        }
    }

    @Test
    func testResizeModeLocksAtFirstContactAndResetsAfterLift() {
        var r = GestureRecognizer()
        #expect(r.update([contacts()[0]], time: 0, optionHeld: true) == nil)
        #expect(r.update(contacts(), time: 0.1) == nil)
        guard case .resizeBegan = r.update(contacts(0.1), time: 0.2) else { Issue.record("Option release must not change mode"); return }
        #expect((r.update(Array(contacts().prefix(1)), time: 0.3)) == (.released))
        #expect(r.update(contacts(), time: 0.4) == nil)
        #expect(r.update([], time: 0.5) == nil)
        #expect(r.update(contacts(), time: 0.6) == nil)
        #expect(r.update(contacts(0.1), time: 0.7, optionHeld: true) == nil)
        #expect((r.update(contacts(0.1), time: 1, optionHeld: true)) == (.began(CGPoint(x: 0.5, y: 0.5))))
    }

    @Test
    func testResizeIgnoresTranslationAndSmallJitter() {
        var r = GestureRecognizer()
        #expect(r.update(contacts(), time: 0, optionHeld: true) == nil)
        #expect(r.update(contacts(0.149, x: 0.6), time: 0.3, optionHeld: true) == nil)
        #expect(r.update(contacts(0.151, x: 0.4), time: 0.6, optionHeld: true) == nil)
        #expect(r.update([], time: 1) == nil)
    }

    @Test
    func testResizeCancellationAndInvalidContacts() {
        for reason in 0..<5 {
            var r = GestureRecognizer()
            _ = r.update(contacts(), time: 0, optionHeld: true)
            guard case .resizeBegan = r.update(contacts(0.1), time: 0.1) else { Issue.record("Expected resize"); return }
            let event: GestureEvent?
            switch reason {
            case 0: event = r.cancel()
            case 1: event = r.update(contacts() + [Contact(id: 3, x: 0.5, y: 0.5)], time: 0.2)
            case 2: event = r.update([contacts()[0], Contact(id: 3, x: 0.5, y: 0.5)], time: 0.2)
            case 3: event = r.update([], time: .nan)
            default: event = r.update(contacts(), time: 0)
            }
            #expect((event) == (.cancelled))
            #expect(r.update(contacts(0.1), time: 0.3, optionHeld: true) == nil)
            #expect(r.update([], time: 0.4) == nil)
        }
    }

    @Test
    func testResizePlansBothAxesLimitsAndCommands() {
        let frame = CGRect(x: -1000, y: -200, width: 800, height: 600)
        let grow = ResizePlan(frame: frame, layout: "h_tiles", change: 0.25)
        #expect((grow.amount) == (200))
        #expect((grow.preview) == (CGRect(x: -1100, y: -200, width: 1000, height: 600)))
        #expect((grow.command(windowID: 42)) == (["resize", "--window-id", "42", "smart", "+200"]))
        let shrink = ResizePlan(frame: frame, layout: "v_tiles", change: -0.25)
        #expect((shrink.amount) == (-150))
        #expect((shrink.preview) == (CGRect(x: -1000, y: -125, width: 800, height: 450)))
        #expect((shrink.command(windowID: 42)?.last) == ("-150"))
        #expect((ResizePlan(frame: frame, layout: "h_tiles", change: 10).amount) == (320))
        #expect((ResizePlan(frame: frame, layout: "v_tiles", change: -10).amount) == (-240))
        let small = CGRect(x: 0, y: 0, width: 180, height: 100)
        #expect((ResizePlan(frame: small, layout: "h_tiles", change: -0.4).amount) == (-20))
        #expect((ResizePlan(frame: small, layout: "v_tiles", change: -0.4).amount) == (0))
        #expect(ResizePlan(frame: frame, layout: "h_tiles", change: 0).command(windowID: 42) == nil)
        #expect(ResizePlan(frame: frame, layout: "h_tiles", change: .nan).command(windowID: 42) == nil)
        #expect(ResizePlan(frame: frame, layout: "floating", change: 0.4).command(windowID: 42) == nil)
    }

    @Test
    func testResizePreviewStaysInsideUsableDisplayWithoutChangingCommand() {
        let bounds = CGRect(x: -1440, y: -200, width: 1440, height: 850)
        for frame in [CGRect(x: -1440, y: -200, width: 800, height: 600),
                      CGRect(x: -800, y: 50, width: 800, height: 600), bounds] {
            for layout in ["h_tiles", "v_tiles"] {
                for change in [-0.4, 0.4] {
                    let plan = ResizePlan(frame: frame, layout: layout, change: change)
                    let command = plan.command(windowID: 42)
                    let rect = plan.preview(constrainedTo: bounds)
                    #expect(bounds.contains(rect))
                    #expect((rect.width) == (min(plan.preview.width, bounds.width)))
                    #expect((rect.height) == (min(plan.preview.height, bounds.height)))
                    #expect((plan.command(windowID: 42)) == (command))
                }
            }
        }
    }

    @Test
    func testEdgesAndPreviewAtNegativeScreenCoordinates() {
        let rect = CGRect(x: -1000, y: -200, width: 800, height: 600)
        #expect((Edge.nearest(to: CGPoint(x: -999, y: 0), in: rect)) == (.left))
        #expect((Edge.nearest(to: CGPoint(x: -201, y: 0), in: rect)) == (.right))
        #expect((Edge.nearest(to: CGPoint(x: -600, y: -199), in: rect)) == (.top))
        #expect((Edge.nearest(to: CGPoint(x: -600, y: 399), in: rect)) == (.bottom))
        #expect(Edge.nearest(to: .zero, in: rect) == nil)
        #expect((Edge.top.preview(in: rect)) == (CGRect(x: -1000, y: -200, width: 800, height: 300)))
    }
    @Test
    func testInsertionForEveryAxisAndEdge() {
        for layout in ["h_tiles", "v_tiles"] {
            for edge in Edge.allCases {
                let commands = InsertionPlan(source: 1, target: 2, targetLayout: layout, edge: edge).commands
                #expect((commands.prefix(3)) == ([["layout", "--window-id", "1", "floating"], ["focus", "--window-id", "2"], ["layout", "--window-id", "1", "tiling"]]))
                let joins = commands.filter { $0.first == "join-with" }
                #expect((joins.count) == ((layout == "h_tiles") == edge.horizontal ? 0 : 1))
                if let join = joins.first { #expect((join.last) == (layout == "h_tiles" ? "left" : "up")) }
                let moves = commands.filter { $0.first == "move" }
                #expect((moves.count) == (edge.before ? 1 : 0))
                if let move = moves.first { #expect((move.last) == (edge.horizontal ? "left" : "up")) }
                #expect((commands.last) == (["focus", "--window-id", "1"]))
            }
        }
    }
    @Test
    func testCenterSwapAndEdgeInsertionZones() {
        let rect = CGRect(x: -800, y: -200, width: 800, height: 400)
        #expect((DropAction.hitTest(CGPoint(x: -400, y: 0), in: rect)) == (.swap))
        for (point, edge) in [(CGPoint(x: -799, y: 0), Edge.left), (CGPoint(x: -1, y: 0), .right), (CGPoint(x: -400, y: -199), .top), (CGPoint(x: -400, y: 199), .bottom)] {
            #expect((DropAction.hitTest(point, in: rect)) == (.insert(edge)))
        }
        #expect((DropAction.hitTest(CGPoint(x: -601, y: 0), in: rect)) == (.insert(.left)))
        #expect((DropAction.hitTest(CGPoint(x: -599, y: 0), in: rect)) == (.swap))
        #expect(DropAction.hitTest(CGPoint(x: 1, y: 0), in: rect) == nil)
        #expect(DropAction.hitTest(.zero, in: .zero) == nil)
        #expect((DropAction.swap.preview(in: rect)) == (rect))
        #expect((DropAction.insert(.left).preview(in: rect)) == (Edge.left.preview(in: rect)))
    }

    @Test
    func testSwapEveryPairPreservesOtherSlotsAndCanUndo() {
        for count in 2...12 {
            for source in 0..<count {
                for target in 0..<count where source != target {
                    var slots = Array(0..<count)
                    let distance = (target - source + count) % count
                    let commands = SwapPlan(source: source, target: target, distance: distance).commands
                    func apply(_ command: [String], inverse: Bool = false) {
                        let index = slots.firstIndex(of: Int(command[2])!)!
                        let direction = (command.last == "dfs-next" ? 1 : -1) * (inverse ? -1 : 1)
                        slots.swapAt(index, (index + direction + count) % count)
                    }
                    for command in commands { apply(command) }
                    var expected = Array(0..<count)
                    expected.swapAt(source, target)
                    #expect((slots) == (expected))
                    for command in commands.reversed() { apply(command, inverse: true) }
                    #expect((slots) == (Array(0..<count)))
                    // Every partial success can be undone, including before endpoint restoration.
                    for prefix in 0...commands.count {
                        for command in commands.prefix(prefix) { apply(command) }
                        for command in commands.prefix(prefix).reversed() { apply(command, inverse: true) }
                        #expect((slots) == (Array(0..<count)))
                    }
                }
            }
        }
        #expect((SwapPlan(source: 1, target: 1, distance: 0).commands) == ([]))
    }
}
