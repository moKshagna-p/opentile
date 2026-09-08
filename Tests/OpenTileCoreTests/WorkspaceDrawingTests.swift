import XCTest
@testable import OpenTileCore

final class WorkspaceDrawingTests: XCTestCase {
    private func line(_ start: DrawingPoint, _ end: DrawingPoint) -> [DrawingPoint] {
        (0...20).map { i in
            let t = Double(i)/20
            return DrawingPoint(x: start.x + (end.x-start.x)*t, y: start.y + (end.y-start.y)*t)
        }
    }
    func testTranslatedScaledSymbolMatches() {
        let original = [line(.init(x: 0.1, y: 0.1), .init(x: 0.1, y: 0.8)), line(.init(x: 0.1, y: 0.1), .init(x: 0.6, y: 0.1))]
        let moved = original.map { $0.map { DrawingPoint(x: $0.x*0.5+0.3, y: $0.y*0.5+0.2) } }
        XCTAssertEqual(WorkspaceMatcher.match(moved, symbols: [.init(workspace: "dev", strokes: original)]), "dev")
    }
    func testAmbiguousWorkspaceRejectedButSameWorkspaceSamplesAllowed() {
        let strokes = [line(.init(x: 0.2, y: 0.1), .init(x: 0.2, y: 0.8))]
        let a = WorkspaceSymbol(workspace: "1", strokes: strokes)
        XCTAssertNil(WorkspaceMatcher.match(strokes, symbols: [a, .init(workspace: "I", strokes: strokes)]))
        XCTAssertEqual(WorkspaceMatcher.match(strokes, symbols: [a, a, a]), "1")
    }
    func testOrientationAndTinyInputRejected() {
        let vertical = [line(.init(x: 0.2, y: 0.1), .init(x: 0.2, y: 0.8))]
        let horizontal = [line(.init(x: 0.1, y: 0.2), .init(x: 0.8, y: 0.2))]
        XCTAssertNil(WorkspaceMatcher.match(horizontal, symbols: [.init(workspace: "1", strokes: vertical)]))
        XCTAssertFalse(WorkspaceMatcher.isValid([line(.init(x: 0.1, y: 0.1), .init(x: 0.11, y: 0.11))]))
    }
    func testSeparateStrokesAndInvalidFrames() {
        var capture = DrawingCapture()
        capture.update([Contact(id: 1, x: 0.2, y: 0.3)], time: 1)
        capture.update([], time: 2)
        capture.update([Contact(id: 2, x: 0.7, y: 0.8)], time: 3)
        XCTAssertEqual(capture.strokes.count, 2)
        capture.update([Contact(id: 2, x: 0.7, y: 0.8), Contact(id: 3, x: 0.4, y: 0.5)], time: 4)
        XCTAssertTrue(capture.cancelled)
        capture.update([], time: 5)
        XCTAssertTrue(capture.cancelled)
        var invalid = DrawingCapture()
        invalid.update([], time: .nan)
        XCTAssertTrue(invalid.cancelled)
    }
    func testReplacementAndBackwardsTimeCancel() {
        var capture = DrawingCapture()
        capture.update([Contact(id: 1, x: 0.2, y: 0.3)], time: 2)
        capture.update([Contact(id: 2, x: 0.2, y: 0.3)], time: 3)
        XCTAssertTrue(capture.cancelled)
        var backwards = DrawingCapture()
        backwards.update([], time: 2)
        backwards.update([], time: 1)
        XCTAssertTrue(backwards.cancelled)
    }
    func testPersistenceRoundTrip() throws {
        let symbol = WorkspaceSymbol(workspace: "A", strokes: [line(.init(x: 0.1, y: 0.1), .init(x: 0.8, y: 0.8))])
        let restored = try JSONDecoder().decode([WorkspaceSymbol].self, from: JSONEncoder().encode([symbol]))
        XCTAssertEqual(WorkspaceMatcher.match(symbol.strokes, symbols: restored), "A")
    }
}
