import Foundation
import Testing
@testable import OpenTileCore

struct WorkspaceDrawingTests {
    private func line(_ start: DrawingPoint, _ end: DrawingPoint) -> [DrawingPoint] {
        (0...20).map { i in
            let t = Double(i)/20
            return DrawingPoint(x: start.x + (end.x-start.x)*t, y: start.y + (end.y-start.y)*t)
        }
    }
    @Test
    func testTranslatedScaledSymbolMatches() {
        let original = [line(.init(x: 0.1, y: 0.1), .init(x: 0.1, y: 0.8)), line(.init(x: 0.1, y: 0.1), .init(x: 0.6, y: 0.1))]
        let moved = original.map { $0.map { DrawingPoint(x: $0.x*0.5+0.3, y: $0.y*0.5+0.2) } }
        #expect((WorkspaceMatcher.match(moved, symbols: [.init(workspace: "dev", strokes: original)])) == ("dev"))
    }
    @Test
    func testAmbiguousWorkspaceRejectedButSameWorkspaceSamplesAllowed() {
        let strokes = [line(.init(x: 0.2, y: 0.1), .init(x: 0.2, y: 0.8))]
        let a = WorkspaceSymbol(workspace: "1", strokes: strokes)
        #expect(WorkspaceMatcher.match(strokes, symbols: [a, .init(workspace: "I", strokes: strokes)]) == nil)
        #expect((WorkspaceMatcher.match(strokes, symbols: [a, a, a])) == ("1"))
    }
    @Test
    func testOrientationAndTinyInputRejected() {
        let vertical = [line(.init(x: 0.2, y: 0.1), .init(x: 0.2, y: 0.8))]
        let horizontal = [line(.init(x: 0.1, y: 0.2), .init(x: 0.8, y: 0.2))]
        #expect(WorkspaceMatcher.match(horizontal, symbols: [.init(workspace: "1", strokes: vertical)]) == nil)
        #expect(!(WorkspaceMatcher.isValid([line(.init(x: 0.1, y: 0.1), .init(x: 0.11, y: 0.11))])))
    }
    @Test
    func testHandwritingProportionsAndStrokeDirection() {
        let original = [line(.init(x: 0.1, y: 0.1), .init(x: 0.1, y: 0.8)),
                        line(.init(x: 0.1, y: 0.1), .init(x: 0.6, y: 0.1))]
        // The same L drawn wider, in reverse stroke order and direction.
        let wider = original.reversed().map { stroke in
            stroke.reversed().map { DrawingPoint(x: $0.x * 1.5, y: $0.y * 0.75) }
        }
        let vertical = [line(.init(x: 0.2, y: 0.1), .init(x: 0.2, y: 0.8))]
        #expect((WorkspaceMatcher.match(wider, symbols: [
            .init(workspace: "L", strokes: original),
            .init(workspace: "1", strokes: vertical)
        ])) == ("L"))
    }
    @Test
    func testClearWinnerAmongSimilarSymbols() {
        let straight = [line(.init(x: 0.2, y: 0.1), .init(x: 0.2, y: 0.8))]
        let tilted = [line(.init(x: 0.2, y: 0.1), .init(x: 0.23, y: 0.8))]
        let halfway = [line(.init(x: 0.2, y: 0.1), .init(x: 0.215, y: 0.8))]
        let symbols = [WorkspaceSymbol(workspace: "straight", strokes: straight),
                       WorkspaceSymbol(workspace: "tilted", strokes: tilted)]
        #expect((WorkspaceMatcher.match(straight, symbols: symbols)) == ("straight"))
        #expect(WorkspaceMatcher.match(halfway, symbols: symbols) == nil)
    }
    @Test
    func testSmallWobbleDoesNotExpandIntoDifferentSymbol() {
        let vertical = [line(.init(x: 0.2, y: 0.1), .init(x: 0.2, y: 0.8))]
        let wobbly = vertical.map { $0.map {
            DrawingPoint(x: $0.x + 0.015 * sin($0.y * 20), y: $0.y)
        } }
        #expect((WorkspaceMatcher.match(wobbly, symbols: [
            .init(workspace: "1", strokes: vertical)
        ])) == ("1"))
    }
    @Test
    func testSeparateStrokesAndInvalidFrames() {
        var capture = DrawingCapture()
        capture.update([Contact(id: 1, x: 0.2, y: 0.3)], time: 1)
        capture.update([], time: 2)
        capture.update([Contact(id: 2, x: 0.7, y: 0.8)], time: 3)
        #expect((capture.strokes.count) == (2))
        capture.update([Contact(id: 2, x: 0.7, y: 0.8), Contact(id: 3, x: 0.4, y: 0.5)], time: 4)
        #expect(capture.cancelled)
        capture.update([], time: 5)
        #expect(capture.cancelled)
        var invalid = DrawingCapture()
        invalid.update([], time: .nan)
        #expect(invalid.cancelled)
    }
    @Test
    func testReplacementAndBackwardsTimeCancel() {
        var capture = DrawingCapture()
        capture.update([Contact(id: 1, x: 0.2, y: 0.3)], time: 2)
        capture.update([Contact(id: 2, x: 0.2, y: 0.3)], time: 3)
        #expect(capture.cancelled)
        var backwards = DrawingCapture()
        backwards.update([], time: 2)
        backwards.update([], time: 1)
        #expect(backwards.cancelled)
    }
    @Test
    func testPersistenceRoundTrip() throws {
        let symbol = WorkspaceSymbol(workspace: "A", strokes: [line(.init(x: 0.1, y: 0.1), .init(x: 0.8, y: 0.8))])
        let restored = try JSONDecoder().decode([WorkspaceSymbol].self, from: JSONEncoder().encode([symbol]))
        #expect((WorkspaceMatcher.match(symbol.strokes, symbols: restored)) == ("A"))
    }
}
