import AppKit
import QuartzCore

/// Geometry follows Omarchy's center-out, slanted reveal (Background.qml).
enum WallpaperReveal {
    static let duration = 0.420
    static func path(size: CGSize, progress: Double) -> CGPath {
        let slant = -0.18
        let spread = (size.width / 2 + abs(slant) * size.height / 2 + 4) * min(1, max(0, progress))
        let top = size.width / 2 - slant * size.height / 2
        let bottom = size.width / 2 + slant * size.height / 2
        let path = CGMutablePath()
        path.move(to: CGPoint(x: top - spread, y: size.height))
        path.addLine(to: CGPoint(x: top + spread, y: size.height))
        path.addLine(to: CGPoint(x: bottom + spread, y: 0))
        path.addLine(to: CGPoint(x: bottom - spread, y: 0))
        path.closeSubpath()
        return path
    }
}

@MainActor final class WallpaperTransition {
    private var panels: [NSPanel] = []

    func stop() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }

    func apply(url: URL, image: CGImage) async throws {
        stop()
        defer { stop() }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            for screen in screens {
                let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = false
                panel.ignoresMouseEvents = true
                panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
                panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
                let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
                view.wantsLayer = true
                let layer = CALayer()
                layer.frame = view.bounds
                layer.contents = image
                layer.contentsGravity = .resizeAspectFill
                layer.masksToBounds = true
                let mask = CAShapeLayer()
                mask.path = WallpaperReveal.path(size: view.bounds.size, progress: 1)
                layer.mask = mask
                view.layer?.addSublayer(layer)
                panel.contentView = view
                panels.append(panel)
                panel.orderFrontRegardless()
                let animation = CABasicAnimation(keyPath: "path")
                animation.fromValue = WallpaperReveal.path(size: view.bounds.size, progress: 0)
                animation.toValue = mask.path
                animation.duration = WallpaperReveal.duration
                // CSS/QML InOutCubic approximation, shared by all display masks.
                animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.65, 0, 0.35, 1)
                mask.add(animation, forKey: "reveal")
            }
            try await Task.sleep(for: .milliseconds(420))
        }
        try Task.checkCancellation()
        var failure: Error?
        for screen in screens {
            do {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [
                    .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                    .allowClipping: true
                ])
            } catch { failure = error }
        }
        // Keep the final frame in place while macOS loads the persistent desktop image.
        if !panels.isEmpty { try await Task.sleep(for: .milliseconds(350)) }
        if let failure { throw failure }
    }
}
