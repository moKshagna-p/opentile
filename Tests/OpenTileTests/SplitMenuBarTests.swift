import AppKit
import Testing
@testable import AppBundle
@testable import OpenTile

struct SplitMenuBarTests {
    @Test func wallpaperAccentFollowsDominantColorAndStaysRestrained() {
        let blue = Array(repeating: [UInt8(18), 75, 225, 255] as [UInt8], count: 80).flatMap { $0 }
        let red = Array(repeating: [UInt8(225), 45, 30, 255] as [UInt8], count: 20).flatMap { $0 }
        let accent = SplitBarWallpaperAccent.fromRGBA(blue + red)
        #expect(accent != nil)
        #expect(accent!.blue > accent!.red)
        #expect(accent!.blue > accent!.green)
        #expect(accent!.blue < 1)
    }

    @Test func wallpaperAccentHandlesGrayscaleAndTransparentImages() {
        let gray = Array(repeating: [UInt8(70), 70, 70, 255] as [UInt8], count: 100).flatMap { $0 }
        let accent = SplitBarWallpaperAccent.fromRGBA(gray)
        #expect(accent?.red == accent?.green)
        #expect(accent?.green == accent?.blue)
        #expect(SplitBarWallpaperAccent.fromRGBA([0, 0, 0, 0]) == nil)
    }

    @Test func wallpaperAccentReadsAnImageFile() throws {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                                   bytesPerRow: 0, bitsPerPixel: 0))
        let green = NSColor(calibratedRed: 0.08, green: 0.8, blue: 0.12, alpha: 1)
        for y in 0..<4 {
            for x in 0..<4 { bitmap.setColor(green, atX: x, y: y) }
        }
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let accent = try #require(SplitBarWallpaperAccent.read(from: url))
        #expect(accent.green > accent.red)
        #expect(accent.green > accent.blue)
    }

    @Test @MainActor func statusDropdownKeepsDetailsAndSettingsInNativeMenu() {
        let menu = SplitBarDropdown.make(
            title: "NETWORK", subtitle: "Wi-Fi connection", symbol: "wifi",
            value: "Connected", visual: .activity([0.2, 0.6, 0.4]),
            details: [.init(title: "Download", value: "12 KB/s", symbol: "arrow.down"),
                      .init(title: "Upload", value: "2 KB/s", symbol: "arrow.up")],
            settingsTitle: "Open Network Settings…",
            settingsAction: #selector(NSApplication.terminate(_:)), target: NSApplication.shared)

        #expect(menu.items.count == 6)
        #expect(menu.items[0].view?.frame.size == NSSize(width: 280, height: 110))
        #expect(menu.items[0].view?.accessibilityLabel() == "NETWORK, Connected, Wi-Fi connection")
        #expect(menu.items[1].isSeparatorItem)
        #expect(menu.items[2].view?.accessibilityLabel() == "Download, 12 KB/s")
        #expect(menu.items[3].view?.accessibilityLabel() == "Upload, 2 KB/s")
        #expect(menu.items[4].isSeparatorItem)
        #expect(menu.items[5].title == "Open Network Settings…")
        #expect(menu.items[5].isEnabled)
        #expect(menu.items[5].target === NSApplication.shared)

        SplitBarDropdown.update(menu, title: "NETWORK", subtitle: "Wired connection",
            symbol: "network", value: "Connected", visual: .activity([0.8, 0.1]),
            details: [.init(title: "Download", value: "4 MB/s", symbol: "arrow.down"),
                      .init(title: "Upload", value: "20 KB/s", symbol: "arrow.up")])
        #expect(menu.items[0].view?.accessibilityLabel() == "NETWORK, Connected, Wired connection")
        #expect(menu.items[2].view?.accessibilityLabel() == "Download, 4 MB/s")
        #expect(menu.items[3].view?.accessibilityLabel() == "Upload, 20 KB/s")
        #expect(menu.items[5].target === NSApplication.shared)
    }

    @Test @MainActor func workspaceIconsRemainUnclippedAndClickable() {
        let button = WorkspaceBarButton(title: "1", target: nil, action: nil)
        button.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        let emptyWidth = button.preferredWidth
        button.appIcons = (0..<8).map { _ in NSImage(size: NSSize(width: 64, height: 64)) }
        button.frame = NSRect(x: 0, y: 0, width: button.preferredWidth, height: 22)
        #expect(button.preferredWidth > emptyWidth + 160)
        #expect(button.hitTest(NSPoint(x: button.bounds.maxX - 5, y: 11)) === button)
    }

    @Test @MainActor func workspaceSelectionReusesButtonsAcrossFocusChanges() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 160, height: 28))
        let content = WorkspaceBarContent(frame: scroll.bounds)
        scroll.documentView = content
        let makeWorkspace = { (name: String, focused: Bool) in
            OpenTileWorkspaceSummary(name: name, applications: [], applicationBundlePaths: [],
                                     windowCount: 1, isFocused: focused)
        }
        let first = [makeWorkspace("1", true), makeWorkspace("2", false)]
        content.update(first, icons: [:], target: NSApplication.shared,
                       action: #selector(NSApplication.terminate(_:)), in: scroll)
        let firstButton = content.button(named: "1")
        let secondButton = content.button(named: "2")
        let selection = content.subviews.first { $0 is WorkspaceBarSelection }
        #expect(content.selectionFrame == firstButton?.frame)
        #expect(selection?.hitTest(NSPoint(x: 12, y: 12)) == nil)

        let second = [makeWorkspace("1", false), makeWorkspace("2", true)]
        content.update(second, icons: [:], target: NSApplication.shared,
                       action: #selector(NSApplication.terminate(_:)), in: scroll)
        #expect(content.button(named: "1") === firstButton)
        #expect(content.button(named: "2") === secondButton)
        #expect(content.subviews.first { $0 is WorkspaceBarSelection } === selection)
        #expect(secondButton?.accessibilityLabel()?.contains("active") == true)
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
