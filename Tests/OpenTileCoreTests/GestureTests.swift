import XCTest
import CoreGraphics
@testable import OpenTileCore

final class GestureTests: XCTestCase {
    func contacts(_ radius: Double = 0.15, x: Double = 0.5) -> [Contact] {
        [Contact(id: 1, x: x-radius, y: 0.5), Contact(id: 2, x: x+radius, y: 0.5), Contact(id: 3, x: x, y: 0.5)]
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
        XCTAssertEqual(r.update(Array(contacts().prefix(2)), time: 0.4), .released)
        XCTAssertNil(r.update([], time: 0.5))
    }
    func testExtraFingerCancels() {
        var r = GestureRecognizer(); arm(&r)
        XCTAssertEqual(r.update(contacts() + [Contact(id: 4, x: 0.7, y: 0.7)], time: 0.4), .cancelled)
        XCTAssertNil(r.update([], time: 0.5))
    }
    func testReplacedFingerCancels() {
        var r = GestureRecognizer(); arm(&r)
        XCTAssertEqual(r.update([contacts()[0], contacts()[1], Contact(id: 4, x: 0.5, y: 0.5)], time: 0.4), .cancelled)
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
}
