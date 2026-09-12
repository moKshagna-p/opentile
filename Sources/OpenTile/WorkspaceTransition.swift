import AppKit
import QuartzCore
import ScreenCaptureKit
import OpenTileCore

/// Covers the CLI switch, then animates two captured views as one vertical strip.
/// Images are transient and never written to disk.
@MainActor final class WorkspaceTransition {
    private var stack = WorkspaceStack(workspaces: UserDefaults.standard.stringArray(forKey: "workspaceStack") ?? [])

    private struct Surface {
        let panel: NSPanel
        let layer: CALayer
        let displayID: CGDirectDisplayID
        let configuration: SCStreamConfiguration
    }

    func perform(from source: String, to destination: String?,
                 switchWorkspace: () async throws -> String) async throws -> Bool {
        if destination == source { return false }
        var surfaces: [Surface] = []
        var watchdog: Timer?
        defer {
            watchdog?.invalidate()
            surfaces.forEach { $0.panel.orderOut(nil) }
        }
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // Permission requests belong to first-launch setup, never a workspace switch.
            if CGPreflightScreenCaptureAccess() { surfaces = (try? await prepare()) ?? [] }
        }
        // Never leave a snapshot covering the desktop if capture stalls.
        let panels = surfaces.map(\.panel)
        watchdog = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { _ in
            panels.forEach { $0.orderOut(nil) }
        }
        let actualDestination = try await switchWorkspace()
        var nextStack = stack
        let direction = nextStack.direction(from: source, to: actualDestination)
        stack = nextStack
        UserDefaults.standard.set(stack.workspaces, forKey: "workspaceStack")
        guard direction != 0, !surfaces.isEmpty else { return false }
        // Give the window server a few frames to present AeroSpace's new layout.
        try await Task.sleep(nanoseconds: 80_000_000)
        // Refresh after showing the overlays: OpenTile may have had no visible
        // windows in the initial shareable-content list. Exclude panel IDs too.
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return false }
        let panelIDs = Set(panels.map { CGWindowID($0.windowNumber) })
        let excluded = content.windows.filter {
            $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier || panelIDs.contains($0.windowID)
        }
        var incoming: [CGImage] = []
        for surface in surfaces {
            guard let display = content.displays.first(where: { $0.displayID == surface.displayID }) else { return false }
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: surface.configuration) else {
                return false
            }
            incoming.append(image)
        }
        guard panels.allSatisfy(\.isVisible) else { return false }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            CATransaction.begin()
            // Only the explicit translation below may animate. In particular,
            // the incoming contents must not fade in over the outgoing image.
            CATransaction.setDisableActions(true)
            CATransaction.setAnimationDuration(0.24)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.16, 0.85, 0.22, 1))
            CATransaction.setCompletionBlock { continuation.resume() }
            for (surface, image) in zip(surfaces, incoming) {
                let outgoing = surface.layer.sublayers!.first!
                let next = CALayer()
                next.frame = surface.layer.bounds
                next.contents = image
                next.contentsGravity = .resize
                surface.layer.addSublayer(next)
                let distance = surface.layer.bounds.height * CGFloat(direction)
                // AppKit layers use bottom-left coordinates: below is negative y.
                for (layer, start, end) in [(outgoing, CGFloat(0), distance), (next, -distance, CGFloat(0))] {
                    let animation = CABasicAnimation(keyPath: "transform.translation.y")
                    animation.fromValue = start
                    animation.toValue = end
                    layer.transform = CATransform3DMakeTranslation(0, end, 0)
                    layer.add(animation, forKey: "workspaceSlide")
                }
            }
            CATransaction.commit()
        }
        return true
    }

    private func prepare() async throws -> [Surface] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        var surfaces: [Surface] = []
        // Prepare every snapshot before showing any panels.
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = content.displays.first(where: { $0.displayID == id.uint32Value }) else { continue }
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            let config = SCStreamConfiguration()
            let visible = screen.visibleFrame
            config.sourceRect = CGRect(x: visible.minX - screen.frame.minX, y: screen.frame.maxY - visible.maxY,
                                       width: visible.width, height: visible.height)
            config.width = Int(visible.width * screen.backingScaleFactor)
            config.height = Int(visible.height * screen.backingScaleFactor)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let panel = NSPanel(contentRect: visible, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.level = .screenSaver
            panel.hasShadow = false
            panel.animationBehavior = .none
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let view = NSView(frame: CGRect(origin: .zero, size: visible.size))
            view.wantsLayer = true
            let layer = view.layer!
            layer.masksToBounds = true
            let snapshot = CALayer()
            snapshot.frame = layer.bounds
            snapshot.contents = image
            snapshot.contentsGravity = .resize
            layer.addSublayer(snapshot)
            panel.contentView = view
            surfaces.append(Surface(panel: panel, layer: layer, displayID: display.displayID, configuration: config))
        }
        surfaces.forEach { $0.panel.orderFrontRegardless() }
        CATransaction.flush()
        return surfaces
    }
}
