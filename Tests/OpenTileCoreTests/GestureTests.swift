import XCTest
import CoreGraphics
@testable import OpenTileCore

final class GestureTests: XCTestCase {
    func contacts(_ radius: Double = 0.15, x: Double = 0.5) -> [Contact] {
        [Contact(id: 1, x: x-radius, y: 0.5), Contact(id: 2, x: x+radius, y: 0.5)]
    }
    func arm(_ recognizer: inout GestureRecognizer) {
        XCTAssertNil(recognizer.update(contacts(), time: 0))
        XCTAssertNil(recognizer.update(contacts(0.10), time: 0.1))
        XCTAssertEqual(recognizer.update(contacts(0.10), time: 0.3), .began(CGPoint(x: 0.5, y: 0.5)))
    }
    func testPinchHoldDragRelease() {
        var r = GestureRecognizer(); arm(&r)
        XCTAssertEqual(r.update(contacts(0.1, x: 0.6), time: 0.4), .moved(CGPoint(x: 0.6, y: 0.5)))
        XCTAssertEqual(r.update([], time: 0.5), .released)
        XCTAssertNil(r.update([], time: 0.6))
    }
    func testUnpinchedSwipeDoesNotArm() {
        var r = GestureRecognizer()
        XCTAssertNil(r.update(contacts(), time: 0))
        XCTAssertNil(r.update(contacts(x: 0.6), time: 1))
        XCTAssertNil(r.update([], time: 2))
    }
    func testOneAndThreeFingerPinchesDoNotArm() {
        for count in [1, 3] {
            var r = GestureRecognizer()
            func frame(_ radius: Double) -> [Contact] {
                let pair = contacts(radius)
                return count == 1 ? [pair[0]] : pair + [Contact(id: 3, x: 0.5, y: 0.5)]
            }
            XCTAssertNil(r.update(frame(0.15), time: 0))
            XCTAssertNil(r.update(frame(0.10), time: 0.1))
            XCTAssertNil(r.update(frame(0.10), time: 0.4))
            XCTAssertNil(r.update([], time: 0.5))
        }
    }
    func testBriefPinchDoesNotArm() {
        var r = GestureRecognizer()
        _ = r.update(contacts(), time: 0)
        _ = r.update(contacts(0.1), time: 0.1)
        XCTAssertNil(r.update([], time: 0.2))
    }
    func testMovementRestartsHold() {
        var r = GestureRecognizer()
        _ = r.update(contacts(), time: 0)
        _ = r.update(contacts(0.1), time: 0.1)
        XCTAssertNil(r.update(contacts(0.1, x: 0.6), time: 0.3))
        XCTAssertEqual(r.update(contacts(0.1, x: 0.6), time: 0.5), .began(CGPoint(x: 0.6, y: 0.5)))
    }
    func testEscapeBlocksUntilLift() {
        var r = GestureRecognizer(); arm(&r)
        XCTAssertEqual(r.cancel(), .cancelled)
        XCTAssertNil(r.update(contacts(0.1), time: 1))
        XCTAssertNil(r.update([], time: 2))
        XCTAssertNil(r.update(contacts(), time: 3))
        XCTAssertNil(r.update(contacts(0.1), time: 3.1))
        XCTAssertNotNil(r.update(contacts(0.1), time: 3.4))
    }
    func testPartialLiftReleasesOnlyOnce() {
        var r = GestureRecognizer(); arm(&r)
        XCTAssertEqual(r.update(Array(contacts().prefix(1)), time: 0.4), .released)
        XCTAssertNil(r.update([], time: 0.5))
    }
    func testExtraFingerCancels() {
        var r = GestureRecognizer(); arm(&r)
        XCTAssertEqual(r.update(contacts() + [Contact(id: 4, x: 0.7, y: 0.7)], time: 0.4), .cancelled)
        XCTAssertNil(r.update([], time: 0.5))
    }
    func testReplacedFingerCancels() {
        var r = GestureRecognizer(); arm(&r)
        XCTAssertEqual(r.update([contacts()[0], Contact(id: 4, x: 0.5, y: 0.5)], time: 0.4), .cancelled)
    }
    func testInvalidFrameCancels() {
        var r = GestureRecognizer(); arm(&r)
        XCTAssertEqual(r.update([], time: .nan), .cancelled)
        XCTAssertNil(r.update([], time: 0.5))
    }
    func testBackwardsTimestampCancels() {
        var r = GestureRecognizer(); arm(&r)
        XCTAssertEqual(r.update(contacts(), time: 0.2), .cancelled)
    }
    func testEdgesAndPreviewAtNegativeScreenCoordinates() {
        let rect = CGRect(x: -1000, y: -200, width: 800, height: 600)
        XCTAssertEqual(Edge.nearest(to: CGPoint(x: -999, y: 0), in: rect), .left)
        XCTAssertEqual(Edge.nearest(to: CGPoint(x: -201, y: 0), in: rect), .right)
        XCTAssertEqual(Edge.nearest(to: CGPoint(x: -600, y: -199), in: rect), .top)
        XCTAssertEqual(Edge.nearest(to: CGPoint(x: -600, y: 399), in: rect), .bottom)
        XCTAssertNil(Edge.nearest(to: .zero, in: rect))
        XCTAssertEqual(Edge.top.preview(in: rect), CGRect(x: -1000, y: -200, width: 800, height: 300))
    }
    func testInsertionForEveryAxisAndEdge() {
        for layout in ["h_tiles", "v_tiles"] {
            for edge in Edge.allCases {
                let commands = InsertionPlan(source: 1, target: 2, targetLayout: layout, edge: edge).commands
                XCTAssertEqual(commands.prefix(3), [["layout", "--window-id", "1", "floating"], ["focus", "--window-id", "2"], ["layout", "--window-id", "1", "tiling"]])
                let joins = commands.filter { $0.first == "join-with" }
                XCTAssertEqual(joins.count, (layout == "h_tiles") == edge.horizontal ? 0 : 1)
                if let join = joins.first { XCTAssertEqual(join.last, layout == "h_tiles" ? "left" : "up") }
                let moves = commands.filter { $0.first == "move" }
                XCTAssertEqual(moves.count, edge.before ? 1 : 0)
                if let move = moves.first { XCTAssertEqual(move.last, edge.horizontal ? "left" : "up") }
                XCTAssertEqual(commands.last, ["focus", "--window-id", "1"])
            }
        }
    }
    func testCenterSwapAndEdgeInsertionZones() {
        let rect = CGRect(x: -800, y: -200, width: 800, height: 400)
        XCTAssertEqual(DropAction.hitTest(CGPoint(x: -400, y: 0), in: rect), .swap)
        for (point, edge) in [(CGPoint(x: -799, y: 0), Edge.left), (CGPoint(x: -1, y: 0), .right), (CGPoint(x: -400, y: -199), .top), (CGPoint(x: -400, y: 199), .bottom)] {
            XCTAssertEqual(DropAction.hitTest(point, in: rect), .insert(edge))
        }
        XCTAssertEqual(DropAction.hitTest(CGPoint(x: -601, y: 0), in: rect), .insert(.left))
        XCTAssertEqual(DropAction.hitTest(CGPoint(x: -599, y: 0), in: rect), .swap)
        XCTAssertNil(DropAction.hitTest(CGPoint(x: 1, y: 0), in: rect))
        XCTAssertNil(DropAction.hitTest(.zero, in: .zero))
        XCTAssertEqual(DropAction.swap.preview(in: rect), rect)
        XCTAssertEqual(DropAction.insert(.left).preview(in: rect), Edge.left.preview(in: rect))
    }

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
                    XCTAssertEqual(slots, expected)
                    for command in commands.reversed() { apply(command, inverse: true) }
                    XCTAssertEqual(slots, Array(0..<count))
                    // Every partial success can be undone, including before endpoint restoration.
                    for prefix in 0...commands.count {
                        for command in commands.prefix(prefix) { apply(command) }
                        for command in commands.prefix(prefix).reversed() { apply(command, inverse: true) }
                        XCTAssertEqual(slots, Array(0..<count))
                    }
                }
            }
        }
        XCTAssertEqual(SwapPlan(source: 1, target: 1, distance: 0).commands, [])
    }
}
