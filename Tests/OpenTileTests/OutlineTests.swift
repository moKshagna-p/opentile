import AppKit
import OpenTileCore
import Testing
@testable import OpenTile

struct OutlineTests {
    @Test @MainActor func finalPreviewGeometryDoesNotDependOnSupersededLabels() {
        _ = NSApplication.shared
        let baseline = Outline(color: .systemTeal)
        let coalesced = Outline(color: .systemTeal)
        defer { baseline.hide(); coalesced.hide() }
        let target = CGRect(x: 100, y: 100, width: 350, height: 260)
        let events = [GestureEvent.moved(.zero), .moved(CGPoint(x: 1, y: 0))]
        func show(_ event: GestureEvent, on outline: Outline) {
            guard case .moved(let point) = event else { return }
            if point.x == 0 {
                outline.show(target, text: "Swap windows · Release to exchange places", color: .systemPurple)
            } else {
                outline.show(Edge.right.preview(in: target), text: "Insert right · OpenTile sets final size", color: .systemTeal)
            }
        }
        for _ in 0..<3 {
            events.forEach { show($0, on: baseline) }
            processGesturePreviewBatch(events) { show($0, on: coalesced) }
        }
        #expect(baseline.label.stringValue == coalesced.label.stringValue)
        #expect(baseline.panel.frame == coalesced.panel.frame)
    }
}
