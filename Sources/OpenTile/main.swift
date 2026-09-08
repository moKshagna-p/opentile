import AppKit
import ApplicationServices
import OpenTileCore

final class Outline {
    let panel: NSPanel
    let label = NSTextField(labelWithString: "")
    init(color: NSColor) {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.borderWidth = 3
        view.layer?.borderColor = color.cgColor
        view.layer?.backgroundColor = color.withAlphaComponent(0.12).cgColor
        panel.contentView = view
        label.textColor = color
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -20)
        ])
    }
    func show(_ rect: CGRect, text: String) {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        panel.setFrame(CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height), display: true)
        label.stringValue = text
        panel.orderFrontRegardless()
    }
    func hide() { panel.orderOut(nil) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let bridge = TouchBridge()
    private var recognizer = GestureRecognizer()
    private let worker = DispatchQueue(label: "OpenTile.AeroSpace")
    private var timer: Timer?
    private var globalKeys: Any?
    private var localKeys: Any?
    private var sleepObserver: NSObjectProtocol?
    private var item: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var statusItem: NSMenuItem!
    private var enabled = false
    private var committing = false
    private var generation = 0
    private var snapshot: DesktopSnapshot?
    private var origin = CGPoint.zero
    private var latestPoint = CGPoint.zero
    private var cursor = CGPoint.zero
    private var lastFrame = ProcessInfo.processInfo.systemUptime
    private var destination: (WindowTile, Edge)?
    private let ghost = Outline(color: .secondaryLabelColor)
    private let preview = Outline(color: .systemTeal)

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "OpenTile")
        let menu = NSMenu()
        menu.autoenablesItems = false
        statusItem = menu.addItem(withTitle: "Ready — enable gestures to begin", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(.separator())
        toggleItem = menu.addItem(withTitle: "Enable Gestures", action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        let help = menu.addItem(withTitle: "How to Use OpenTile…", action: #selector(showHelp), keyEquivalent: "")
        help.target = self
        let permission = menu.addItem(withTitle: "Accessibility Settings…", action: #selector(openSettings), keyEquivalent: "")
        permission.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit OpenTile", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        item.menu = menu
        globalKeys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancel() }
        }
        localKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancel() }
            return event
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.disable() }
        timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        if !UserDefaults.standard.bool(forKey: "hasShownHelp") {
            UserDefaults.standard.set(true, forKey: "hasShownHelp")
            showHelp()
        }
    }

    @objc private func toggle() {
        if enabled { disable(); return }
        guard AXIsProcessTrusted() else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            status("Allow Accessibility, then enable gestures again")
            return
        }
        guard AeroSpace.locate() != nil else { status("AeroSpace CLI not found — install AeroSpace first"); return }
        guard bridge.start() else { status("No supported trackpad found"); return }
        recognizer = GestureRecognizer()
        enabled = true
        toggleItem.title = "Pause Gestures"
        status("Pinch three fingers, hold briefly, then drag")
    }

    private func disable() {
        cancel()
        enabled = false
        bridge.stop()
        toggleItem.title = "Enable Gestures"
        status("Gestures paused")
    }

    private func tick() {
        guard enabled else { return }
        guard AXIsProcessTrusted() else { disable(); status("Accessibility permission was removed"); return }
        let frames = bridge.drain()
        if !frames.isEmpty { lastFrame = ProcessInfo.processInfo.systemUptime }
        for frame in frames {
            guard let event = recognizer.update(frame.contacts, time: frame.time) else { continue }
            switch event {
            case .began(let point): begin(point)
            case .moved(let point): move(point)
            case .released: release()
            case .cancelled: cancel()
            }
        }
        if snapshot != nil && ProcessInfo.processInfo.systemUptime - lastFrame > 0.4 { cancel() }
    }

    private func begin(_ point: CGPoint) {
        guard !committing, let aerospace = AeroSpace.locate() else { return }
        generation += 1
        let token = generation
        origin = point
        latestPoint = point
        status("Reading workspace…")
        worker.async {
            let result = Result { try aerospace.snapshot() }
            DispatchQueue.main.async {
                guard self.generation == token, self.enabled else { return }
                switch result {
                case .success(let snapshot):
                    self.snapshot = snapshot
                    self.move(self.latestPoint)
                    self.status("Drag the outline to a tile edge · Escape cancels")
                case .failure(let error): self.cancel(); self.status(error.localizedDescription)
                }
            }
        }
    }

    private func move(_ point: CGPoint) {
        latestPoint = point
        guard let snapshot else { return }
        let screen = NSScreen.screens.first?.frame.size ?? CGSize(width: 1440, height: 900)
        cursor = CGPoint(x: snapshot.source.frame.midX + (point.x - origin.x) * screen.width * 2,
                         y: snapshot.source.frame.midY - (point.y - origin.y) * screen.height * 2)
        let rect = CGRect(x: cursor.x - snapshot.source.frame.width / 2, y: cursor.y - snapshot.source.frame.height / 2,
                          width: snapshot.source.frame.width, height: snapshot.source.frame.height)
        ghost.show(rect, text: "Release over a tile edge · Esc to cancel")
        destination = snapshot.targets.compactMap { target in Edge.nearest(to: cursor, in: target.frame).map { (target, $0) } }.first
        if let (target, edge) = destination {
            preview.show(edge.preview(in: target.frame), text: "Insert \(edge.rawValue) · AeroSpace sets final size")
        } else { preview.hide() }
    }

    private func release() {
        generation += 1 // invalidates a snapshot still being read
        guard let snapshot, let (target, edge) = destination, let aerospace = AeroSpace.locate() else {
            clearPreview()
            if !committing { status("No destination selected — layout unchanged") }
            return
        }
        clearPreview()
        committing = true
        toggleItem.isEnabled = false
        status("Inserting window…")
        worker.async {
            let result = Result { try aerospace.insert(source: snapshot.source.tile, target: target.tile, edge: edge) }
            DispatchQueue.main.async {
                self.committing = false
                self.toggleItem.isEnabled = true
                switch result {
                case .success: self.status("Window inserted · ready for another gesture")
                case .failure(let error): self.status(error.localizedDescription); NSSound.beep()
                }
            }
        }
    }

    private func clearPreview() { snapshot = nil; destination = nil; ghost.hide(); preview.hide() }
    private func cancel() {
        generation += 1
        _ = recognizer.cancel()
        clearPreview()
        if !committing { status("Cancelled — layout unchanged") }
    }
    private func status(_ message: String) {
        statusItem.title = message
        item.button?.toolTip = "OpenTile: \(message)"
    }
    @objc private func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func showHelp() {
        let alert = NSAlert()
        alert.messageText = "Move tiles with a deliberate gesture"
        alert.informativeText = "Start AeroSpace and allow OpenTile in Accessibility Settings. Enable gestures from the menu bar.\n\nFocus a tiled window. Place three fingers on the trackpad, pinch inward, hold briefly, then move them together. An outline follows your gesture. Release over another tile to insert beside its highlighted edge. Press Escape before release to cancel.\n\nThis version supports tiles in the current workspace. The preview indicates placement; AeroSpace determines final sizes. macOS trackpad gestures can also respond, so avoid conflicting three-finger gestures in System Settings.\n\nExperimental: the private trackpad interface has been verified only on Apple Silicon."
        alert.addButton(withTitle: "Got It")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    @objc private func quit() {
        guard !committing else { status("Wait for the insertion to finish before quitting"); return }
        NSApp.terminate(nil)
    }
    func applicationWillTerminate(_ notification: Notification) {
        bridge.stop()
        timer?.invalidate()
        if let globalKeys { NSEvent.removeMonitor(globalKeys) }
        if let localKeys { NSEvent.removeMonitor(localKeys) }
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
