import AppKit
import Testing
import AppBundle
@testable import OpenTile

struct SplitMenuBarTests {
    @Test @MainActor func workspaceIconsRemainUnclippedAndClickable() {
        let button = WorkspaceBarButton(title: "1", target: nil, action: nil)
        button.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        let emptyWidth = button.preferredWidth
        button.appIcons = (0..<8).map { _ in NSImage(size: NSSize(width: 64, height: 64)) }
        button.frame = NSRect(x: 0, y: 0, width: button.preferredWidth, height: 22)
        #expect(button.preferredWidth > emptyWidth + 160)
        #expect(button.hitTest(NSPoint(x: button.bounds.maxX - 5, y: 11)) === button)
    }

    @Test @MainActor func panelPreservesTopEdgeAboveVisibleFrame() {
        let target = CGRect(x: 0, y: 1084, width: 751, height: 28)
        let panel = BarPanel(contentRect: target, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        #expect(panel.constrainFrameRect(target, to: NSScreen.main) == target)
    }

    @Test func notchLeavesCameraUncovered() {
        let frames = SplitBarFrames(
            screen: CGRect(x: 0, y: 0, width: 1512, height: 982),
            leftSafeArea: CGRect(x: 0, y: 950, width: 660, height: 32),
            rightSafeArea: CGRect(x: 852, y: 950, width: 660, height: 32))
        #expect(frames.left.maxY == 982)
        #expect(frames.right.maxY == 982)
        #expect(frames.left.maxX == 660)
        #expect(frames.right.minX == 852)
        #expect(!frames.left.intersects(frames.right))
    }

    @Test func externalDisplayUsesItsOwnCoordinates() {
        let frames = SplitBarFrames(screen: CGRect(x: -1920, y: 250, width: 1920, height: 1080),
                                    leftSafeArea: nil, rightSafeArea: nil)
        #expect(frames.left.minX == -1920)
        #expect(frames.right.maxX == 0)
        #expect(frames.left.maxY == 1330)
        #expect(frames.right.minX - frames.left.maxX == 12)
    }

    @Test func reservedSpaceDoesNotDoubleCountNativeMenuBar() {
        #expect(openTileAdditionalTopInset(barHeight: 28, existingInset: 0) == 28)
        #expect(openTileAdditionalTopInset(barHeight: 28, existingInset: 24) == 4)
        #expect(openTileAdditionalTopInset(barHeight: 28, existingInset: 32) == 0)
        #expect(openTileAdditionalTopInset(barHeight: 0, existingInset: 0) == 0)
        #expect(openTileAdditionalTopInset(barHeight: 28, existingInset: -5) == 28)
    }
}
