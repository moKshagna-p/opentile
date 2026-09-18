import AppKit
import SceneKit
import OpenTileCore

@MainActor
private final class CompanionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class CompanionView: SCNView {
    var clicked: (() -> Void)?
    var dragged: ((Double) -> Void)?
    private var start = NSPoint.zero
    private var origin = NSPoint.zero
    private var moved = false
    override func mouseDown(with event: NSEvent) {
        start = NSEvent.mouseLocation
        origin = window?.frame.origin ?? .zero
        moved = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let point = NSEvent.mouseLocation
        let dx = point.x - start.x, dy = point.y - start.y
        guard moved || hypot(dx, dy) > 4 else { return }
        moved = true
        var next = NSPoint(x: origin.x + dx, y: origin.y + dy)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            let bounds = screen.visibleFrame
            next.x = max(bounds.minX, min(bounds.maxX - window.frame.width, next.x))
            next.y = max(bounds.minY, min(bounds.maxY - window.frame.height, next.y))
        }
        dragged?(Double(next.x - window.frame.minX) * 0.035)
        window.setFrameOrigin(next)
    }
    override func mouseUp(with event: NSEvent) { if !moved { clicked?() } }
}

/// A local command surface: application names are resolved from standard app folders, never a shell.
@MainActor
final class DesktopCompanion: NSObject {
    private lazy var character = CompanionCharacter()
    private var panel: NSPanel?
    private var bubble: NSPanel?
    private var input: NSTextField?
    private var reply: NSTextField?
    private var timer: Timer?
    private var spring = CompanionSpring()
    private var elapsed = 0.0
    private var paused = false
    private var sleeping = false
    private var intensity = 1.0
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var showItem: NSMenuItem?
    private var pauseItem: NSMenuItem?
    private var request = UUID()
    private var launching = false

    func install(in menu: NSMenu) {
        let submenu = NSMenu(title: "2D Companion")
        let root = menu.addItem(withTitle: "2D Companion", action: nil, keyEquivalent: "")
        root.submenu = submenu
        showItem = submenu.addItem(withTitle: "Show Companion", action: #selector(toggle), keyEquivalent: "")
        showItem?.target = self
        pauseItem = submenu.addItem(withTitle: "Pause Animation", action: #selector(togglePause), keyEquivalent: "")
        pauseItem?.target = self
        let motion = NSMenu(title: "Spring Motion")
        let motionItem = submenu.addItem(withTitle: "Spring Motion", action: nil, keyEquivalent: "")
        motionItem.submenu = motion
        for (index, name) in ["Off", "Gentle", "Lively"].enumerated() {
            let item = motion.addItem(withTitle: name, action: #selector(changeMotion(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = index == 1 ? .on : .off
        }
        submenu.addItem(.separator())
        let credit = submenu.addItem(withTitle: "Artwork and model credits", action: #selector(showModelCredit), keyEquivalent: "")
        credit.target = self
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification) { [weak self] in
            self?.sleeping = true; self?.updateAnimation()
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { [weak self] in
            self?.sleeping = false; self?.updateAnimation()
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { [weak self] in
            self?.updateAnimation()
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        }
        observers.append((center, token))
    }

    @objc private func toggle() {
        if panel?.isVisible == true {
            panel?.orderOut(nil); bubble?.orderOut(nil)
            showItem?.title = "Show Companion"
            request = UUID(); launching = false
        } else {
            if let error = character.loadError {
                let alert = NSAlert()
                alert.messageText = "Couldn’t load the companion"
                alert.informativeText = error.localizedDescription
                alert.runModal()
                return
            }
            if panel == nil { createPanel() }
            panel?.orderFrontRegardless()
            showItem?.title = "Hide Companion"
        }
        updateAnimation()
    }

    private func createPanel() {
        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 700)
        let panel = NSPanel(contentRect: NSRect(x: frame.maxX - 310, y: frame.minY + 20, width: 300, height: 340), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        let view = CompanionView(frame: NSRect(x: 0, y: 0, width: 300, height: 340))
        view.scene = character.scene
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.isPlaying = false
        view.setAccessibilityLabel("2D companion. Click to type an app command; drag to move.")
        view.clicked = { [weak self] in self?.showCommands() }
        view.dragged = { [weak self] impulse in
            self?.spring.impulse(impulse)
            self?.bubble?.orderOut(nil)
        }
        panel.contentView = view
        self.panel = panel
    }

    @objc private func showModelCredit() {
        if let url = CompanionCharacter.resourceBundle.url(forResource: "Attribution", withExtension: "txt", subdirectory: "Companion") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func togglePause() {
        paused.toggle()
        pauseItem?.state = paused ? .on : .off
        updateAnimation()
    }

    @objc private func changeMotion(_ sender: NSMenuItem) {
        intensity = [0.0, 1.0, 1.8][sender.tag]
        sender.menu?.items.forEach { $0.state = $0 === sender ? .on : .off }
        spring.reset()
        updateAnimation()
    }

    private func updateAnimation() {
        timer?.invalidate(); timer = nil
        let animate = panel?.isVisible == true && !paused && !sleeping && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        spring.reset()
        character.pose(time: elapsed, spring: 0, intensity: intensity, animated: false)
        guard animate else { return }
        character.greet()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.elapsed += 1.0 / 30
                self.spring.step(delta: 1.0 / 30, target: sin(self.elapsed * 1.8) * 0.035)
                let attention = self.panel.map { (NSEvent.mouseLocation.x - $0.frame.midX) / 400 } ?? 0
                self.character.pose(time: self.elapsed, spring: self.spring.position, intensity: self.intensity, animated: true, attention: attention)
            }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func showCommands() {
        character.greet()
        guard let panel else { return }
        if bubble == nil {
            let bubble = CompanionPanel(contentRect: NSRect(x: 0, y: 0, width: 310, height: 130), styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
            bubble.title = "OpenTile Companion"
            bubble.level = .floating
            bubble.isReleasedWhenClosed = false
            bubble.hidesOnDeactivate = false
            bubble.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let reply = NSTextField(wrappingLabelWithString: "Hi! Tell me which app to open.")
            reply.frame = NSRect(x: 16, y: 68, width: 278, height: 48)
            let input = NSTextField(frame: NSRect(x: 16, y: 25, width: 278, height: 28))
            input.placeholderString = "open Safari · launch Notes"
            input.target = self; input.action = #selector(submit)
            input.setAccessibilityLabel("App command")
            bubble.contentView?.addSubview(reply)
            bubble.contentView?.addSubview(input)
            self.bubble = bubble; self.input = input; self.reply = reply
        }
        guard let bubble else { return }
        let bounds = panel.screen?.visibleFrame ?? panel.frame
        bubble.setFrameOrigin(NSPoint(x: max(bounds.minX, min(bounds.maxX - bubble.frame.width, panel.frame.midX - bubble.frame.width / 2)), y: max(bounds.minY, min(bounds.maxY - bubble.frame.height, panel.frame.maxY - 30))))
        bubble.makeKeyAndOrderFront(nil)
        bubble.makeFirstResponder(input)
    }

    @objc private func submit() {
        guard !launching, let input else { return }
        guard let command = CompanionCommand(input.stringValue) else {
            reply?.stringValue = "Try ‘open Safari’, ‘launch Notes’, or ‘help’."
            return
        }
        guard case .openApp(let name) = command else {
            reply?.stringValue = "Use open, launch, or start plus an installed app name. Drag me to move; use the OpenTile menu to hide or pause me."
            return
        }
        let workspace = NSWorkspace.shared
        guard let applicationURL = applicationURL(named: name) else {
            reply?.stringValue = "I couldn’t find \(name). Try its name from Applications."
            return
        }
        launching = true
        let id = UUID(); request = id
        reply?.stringValue = "Opening \(name)…"
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.openApplication(at: applicationURL, configuration: configuration) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self, self.request == id else { return }
                self.launching = false
                self.reply?.stringValue = error == nil ? "Opened \(name). What’s next?" : "I couldn’t open \(name): \(error!.localizedDescription)"
                if error == nil {
                    self.input?.stringValue = ""
                    self.spring.impulse(2)
                    self.character.greet()
                }
            }
        }
    }

    private func applicationURL(named name: String) -> URL? {
        let fileManager = FileManager.default
        let requestedName = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]

        for root in roots {
            guard let applications = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isApplicationKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            if let match = applications.first(where: {
                $0.pathExtension.caseInsensitiveCompare("app") == .orderedSame
                    && $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(requestedName) == .orderedSame
            }) {
                return match
            }
        }
        return nil
    }

    func stop() {
        timer?.invalidate(); timer = nil
        panel?.orderOut(nil); bubble?.orderOut(nil)
        request = UUID()
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }
}
