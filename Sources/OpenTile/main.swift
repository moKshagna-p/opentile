import AppKit
import AppBundle
import Combine
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
    func show(_ rect: CGRect, text: String, color: NSColor? = nil) {
        if let color {
            panel.contentView?.layer?.borderColor = color.cgColor
            panel.contentView?.layer?.backgroundColor = color.withAlphaComponent(0.12).cgColor
            label.textColor = color
        }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        label.stringValue = text
        panel.setFrame(CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height), display: true)
        panel.orderFrontRegardless()
    }
    func hide() { panel.orderOut(nil) }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    @MainActor private lazy var appUpdater = AppUpdater()
    @MainActor private lazy var splitMenuBar = SplitMenuBar()
    @MainActor private lazy var permissions = PermissionSetup()
    @MainActor private lazy var wallpaperPicker = WallpaperPicker()
    private let bridge = TouchBridge()
    private let phonePad = PhonePad()
    private var phoneGesture = false
    private let drawing = WorkspaceDrawing()
    private let appDrawing = WorkspaceDrawing(apps: true)
    private var appDrawingOwnedFrames = false
    @MainActor private lazy var workspaceTransition = WorkspaceTransition()
    private var recognizer = GestureRecognizer()
    private let worker = DispatchQueue(label: "OpenTile.AeroSpace")
    private let polling = GesturePolling()
    private var globalKeys: Any?
    private var localKeys: Any?
    private var sleepObserver: NSObjectProtocol?
    private var item: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var statusItem: NSMenuItem!
    private let gestureActivation = GestureActivation()
    private var enabled: Bool { gestureActivation.isEnabled }
    private var committing = false {
        didSet { workspaceRequests.isBusy = committing }
    }
    private lazy var workspaceRequests = WorkspaceRequestQueue { [weak self] in
        self?.switchWorkspace($0)
    }
    private var generation = 0
    private var snapshot: DesktopSnapshot?
    private var snapshotTask: Task<Void, Never>?
    private var resizing = false
    private var latestResize: Double = 0
    private var readingWorkspace = false
    private var origin = CGPoint.zero
    private var latestPoint = CGPoint.zero
    private var cursor = CGPoint.zero
    private var lastFrame = ProcessInfo.processInfo.systemUptime
    private var lastTrustCheck = -Double.infinity
    private var destination: (WindowTile, DropAction)?
    private let ghost = Outline(color: .secondaryLabelColor)
    private let preview = Outline(color: .systemTeal)

    private var engineMessages: AnyCancellable?
    private var workspaceIndicator: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let duplicates = NSRunningApplication.runningApplications(withBundleIdentifier: "com.mokshagna.opentile")
        guard !duplicates.contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) else {
            NSApp.terminate(nil)
            return
        }
        engineMessages = MessageModel.shared.$message.compactMap { $0 }.receive(on: DispatchQueue.main).sink { message in
            let alert = NSAlert()
            alert.messageText = message.description
            alert.informativeText = message.body
            alert.runModal()
            MessageModel.shared.message = nil
        }
        let upstreamIDs = ["bobko.aerospace", "bobko.aerospace.debug"]
        if upstreamIDs.contains(where: { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }) {
            let alert = NSAlert()
            alert.messageText = "Quit AeroSpace before starting OpenTile"
            alert.informativeText = "OpenTile now includes its own window manager. Quit AeroSpace, then reopen OpenTile so only one app manages your windows."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        initAppBundle(promptForAccessibility: false)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "OpenTile")
        item.button?.imagePosition = .imageLeading
        workspaceIndicator = TrayMenuModel.shared.$trayText
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                self?.item.button?.title = text.isEmpty ? "" : " \(text)"
                self?.item.button?.setAccessibilityLabel(text.isEmpty ? "OpenTile" : "OpenTile workspaces: \(text)")
            }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let workspaces = NSMenuItem(title: "Workspaces", action: nil, keyEquivalent: "")
        let workspaceMenu = NSMenu(title: "Workspaces")
        workspaceMenu.delegate = self
        workspaces.submenu = workspaceMenu
        menu.addItem(workspaces)
        statusItem = menu.addItem(withTitle: "Ready — enable gestures to begin", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(.separator())
        toggleItem = menu.addItem(withTitle: "Enable Gestures", action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        phonePad.install(in: menu)
        phonePad.onEvent = { [weak self] in self?.handlePhone($0) }
        phonePad.onStatus = { [weak self] in self?.status($0) }
        phonePad.onDisconnect = { [weak self] in
            guard let self, self.phoneGesture else { return }
            self.cancel()
        }
        let reload = menu.addItem(withTitle: "Reload Window Manager Configuration", action: #selector(reloadEngine), keyEquivalent: "")
        reload.target = self
        let config = menu.addItem(withTitle: "Open Window Manager Configuration…", action: #selector(openEngineConfig), keyEquivalent: "")
        config.target = self
        wallpaperPicker.onStatus = { [weak self] in self?.status($0) }
        wallpaperPicker.install(in: menu)
        appDrawing.install(in: menu)
        appDrawing.canTrain = { [weak self] in self?.enabled == true && self?.committing == false }
        appDrawing.onStatus = { [weak self] message in self?.status(message) }
        drawing.install(in: menu)
        drawing.canTrain = { [weak self] in self?.enabled == true && self?.committing == false }
        drawing.onStatus = { [weak self] message in self?.status(message) }
        drawing.onSwitch = { [weak self] workspace in self?.switchWorkspace(workspace) }
        let help = menu.addItem(withTitle: "How to Use OpenTile…", action: #selector(showHelp), keyEquivalent: "")
        help.target = self
        let setup = menu.addItem(withTitle: "Permission Setup…", action: #selector(showPermissionSetup), keyEquivalent: "")
        setup.target = self
        let permission = menu.addItem(withTitle: "Accessibility Settings…", action: #selector(openSettings), keyEquivalent: "")
        permission.target = self
        let capturePermission = menu.addItem(withTitle: "Screen Recording Settings…", action: #selector(openCaptureSettings), keyEquivalent: "")
        capturePermission.target = self
        menu.addItem(.separator())
        appUpdater.install(in: menu, statusButton: item.button)
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit OpenTile", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        item.menu = menu
        splitMenuBar.selectWorkspace = { [weak self] in self?.switchWorkspace($0) }
        splitMenuBar.install(in: menu)
        globalKeys = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            if event.type == .flagsChanged { self?.wakeGestureProcessing() }
            if event.type == .keyDown && event.keyCode == 53 { self?.cancel() }
        }
        localKeys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            if event.type == .flagsChanged { self?.wakeGestureProcessing() }
            if event.type == .keyDown && event.keyCode == 53 { self?.cancel() }
            return event
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.wallpaperPicker.cancel()
                self?.disable()
            }
        }
        workspaceRequests.isReady = true
        if permissions.shouldShowOnLaunch { showPermissionSetup() }
        if gestureActivation.shouldRestore { enableGestures() }
        if let endpointText = ProcessInfo.processInfo.environment["OPENTILE_PHONE_PAD_ENDPOINT"] {
            guard let endpoint = PhonePadPairing.endpoint(endpointText) else {
                status("OPENTILE_PHONE_PAD_ENDPOINT must be an HTTPS tunnel address")
                return
            }
            guard AXIsProcessTrusted() else {
                status("Allow Accessibility in Permission Setup before pairing a phone")
                return
            }
            do { try phonePad.start(endpoint: endpoint) }
            catch { status("Phone Pad could not start: \(error.localizedDescription)") }
        }
    }

    @objc private func toggle() {
        if enabled { disable(rememberPause: true); return }
        enableGestures()
    }

    private func enableGestures() {
        guard gestureActivation.enable(start: {
            guard AXIsProcessTrusted() else {
                status("Accessibility is off — open Permission Setup from the menu")
                return false
            }
            guard AeroSpace.locate() != nil else { status("Bundled window manager CLI is missing — rebuild OpenTile"); return false }
            guard bridge.start(onFrames: { [weak self] in self?.wakeGestureProcessing() }) else { status("No supported trackpad found"); return false }
            return true
        }) else { return }
        recognizer = GestureRecognizer()
        wakeGestureProcessing()
        toggleItem.title = "Pause Gestures"
        status("Pinch and hold to move · Option + pinch to resize")
    }

    private func disable(rememberPause: Bool = false) {
        phonePad.stop()
        cancel()
        gestureActivation.disable(rememberPause: rememberPause)
        polling.stop()
        bridge.stop()
        drawing.stop()
        appDrawing.stop()
        toggleItem.title = "Enable Gestures"
        status("Gestures paused")
    }

    private func wakeGestureProcessing() {
        guard enabled else { return }
        polling.start { [weak self] in self?.tick() }
    }

    private func tick() {
        guard enabled else { return }
        // The trust check costs a TCC lookup; once a second still notices revocation promptly.
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastTrustCheck >= 1 || now < lastTrustCheck {
            lastTrustCheck = now
            guard AXIsProcessTrusted() else { disable(); status("Accessibility permission was removed"); return }
        }
        let frames = bridge.drain()
        if !frames.isEmpty { lastFrame = now }
        defer {
            let drawingActive = drawing.needsPolling || appDrawing.needsPolling
            bridge.setEngaged(!recognizer.isIdle || drawingActive || snapshot != nil || readingWorkspace || committing)
            polling.settle(idleFor: ProcessInfo.processInfo.systemUptime - lastFrame, drawingActive: drawingActive)
        }
        if phoneGesture || (phonePad.hasTouches && snapshot == nil && !readingWorkspace && !drawing.needsPolling && !appDrawing.needsPolling) {
            _ = recognizer.cancel()
            drawing.cancel()
            appDrawing.cancel()
            return
        }
        if drawing.process(frames, allowed: !committing) {
            appDrawing.cancel()
            generation += 1
            _ = recognizer.cancel()
            clearPreview()
            return
        }
        if appDrawing.process(frames, allowed: !committing) {
            appDrawingOwnedFrames = true
            generation += 1
            _ = recognizer.cancel()
            clearPreview()
            return
        }
        if appDrawingOwnedFrames {
            recognizer = GestureRecognizer()
            appDrawingOwnedFrames = false
        }
        // Lifecycle handlers can cancel recognition before the next frame is consumed.
        let events = frames.lazy.compactMap { self.recognizer.update($0.contacts, time: $0.time, optionHeld: $0.optionHeld) }
        processGesturePreviewBatch(events) { event in
            switch event {
            case .began(let point): begin(point)
            case .moved(let point): move(point)
            case .resizeBegan(let change):
                latestResize = change
                begin(.zero, resize: true)
            case .resized(let change): resizePreview(change)
            case .released: release()
            case .cancelled: cancel()
            }
        }
        if (snapshot != nil || readingWorkspace) && ProcessInfo.processInfo.systemUptime - lastFrame > 0.4 { cancel() }
    }

    private func begin(_ point: CGPoint, resize: Bool = false) {
        guard !committing, let aerospace = AeroSpace.locate() else { return }
        generation += 1
        let token = generation
        resizing = resize
        readingWorkspace = true
        origin = point
        latestPoint = point
        status("Reading workspace…")
        snapshotTask?.cancel()
        snapshotTask = Task { @MainActor in
            let result: Result<DesktopSnapshot, Error>
            do { result = .success(try await aerospace.snapshot(on: worker)) }
            catch { result = .failure(error) }
            guard self.generation == token, self.enabled || (self.phoneGesture && self.phonePad.isConnected) else { return }
            self.snapshotTask = nil
            self.readingWorkspace = false
            switch result {
            case .success(let snapshot):
                self.snapshot = snapshot
                if self.resizing {
                    self.resizePreview(self.latestResize)
                    self.status("Pinch inward to grow · Outward to shrink · Lift to apply")
                } else {
                    self.move(self.latestPoint)
                    self.status("Center to swap · Edge to insert · Escape cancels")
                }
            case .failure(let error): self.cancel(); self.status(error.localizedDescription)
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
        ghost.show(rect, text: "Center to swap · Edge to insert · Esc to cancel")
        destination = snapshot.targets.compactMap { target in DropAction.hitTest(cursor, in: target.frame).map { (target, $0) } }.first
        if let (target, action) = destination {
            switch action {
            case .swap: preview.show(target.frame, text: "Swap windows · Release to exchange places", color: .systemPurple)
            case .insert(let edge): preview.show(action.preview(in: target.frame), text: "Insert \(edge.rawValue) · OpenTile sets final size", color: .systemTeal)
            }
        } else { preview.hide() }
    }

    private func resizePreview(_ change: Double) {
        latestResize = change
        guard resizing, let snapshot else { return }
        let plan = ResizePlan(frame: snapshot.source.frame, layout: snapshot.source.tile.layout, change: change)
        let dimension = plan.horizontal ? "width" : "height"
        let amount = plan.amount > 0 ? "+\(plan.amount)" : "\(plan.amount)"
        // AX window rectangles use a top-left origin; NSScreen uses bottom-left.
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let displays = NSScreen.screens.map { screen in
            let visible = screen.visibleFrame
            return CGRect(x: visible.minX, y: top - visible.maxY,
                          width: visible.width, height: visible.height)
        }
        let bounds = displays.max { lhs, rhs in
            let left = lhs.intersection(snapshot.source.frame)
            let right = rhs.intersection(snapshot.source.frame)
            return left.width * left.height < right.width * right.height
        }
        let rect = bounds.map { plan.preview(constrainedTo: $0) } ?? plan.preview
        preview.show(rect, text: "Resize \(dimension) \(amount) · Lift to apply · Esc cancels", color: .systemOrange)
    }

    private func releaseResize() {
        guard let snapshot, let aerospace = AeroSpace.locate() else {
            clearPreview()
            if !committing { status("Workspace not ready — resize unchanged") }
            return
        }
        let plan = ResizePlan(frame: snapshot.source.frame, layout: snapshot.source.tile.layout, change: latestResize)
        clearPreview()
        guard plan.amount != 0 else { status("Size unchanged — ready for another gesture"); return }
        committing = true
        toggleItem.isEnabled = false
        status("Resizing window…")
        worker.async {
            let result = Result { try aerospace.resize(source: snapshot.source.tile, plan: plan) }
            DispatchQueue.main.async {
                self.committing = false
                self.toggleItem.isEnabled = true
                switch result {
                case .success: self.status("Window resized · ready for another gesture")
                case .failure(let error): self.status(error.localizedDescription); NSSound.beep()
                }
            }
        }
    }

    private func release() {
        generation += 1 // invalidates a snapshot still being read
        if resizing { releaseResize(); return }
        guard let snapshot, let (target, action) = destination, let aerospace = AeroSpace.locate() else {
            clearPreview()
            if !committing { status("No destination selected — layout unchanged") }
            return
        }
        clearPreview()
        committing = true
        toggleItem.isEnabled = false
        status(action == .swap ? "Swapping windows…" : "Inserting window…")
        let complete: (Result<Void, Error>) -> Void = { result in
            self.committing = false
            self.toggleItem.isEnabled = true
            switch result {
            case .success: self.status(action == .swap ? "Windows swapped · ready for another gesture" : "Window inserted · ready for another gesture")
            case .failure(let error): self.status(error.localizedDescription); NSSound.beep()
            }
        }
        if action == .swap {
            Task { @MainActor in
                do {
                    try await aerospace.swap(source: snapshot.source.tile, target: target.tile)
                    complete(.success(()))
                } catch { complete(.failure(error)) }
            }
        } else {
            worker.async {
                let result = Result {
                    if case .insert(let edge) = action {
                        try aerospace.insert(source: snapshot.source.tile, target: target.tile, edge: edge)
                    }
                }
                DispatchQueue.main.async { complete(result) }
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for request in urls.compactMap({ WorkspaceRequest(url: $0) }) {
            workspaceRequests.append(request)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for workspace in openTileWorkspaces() {
            let detail = workspace.windowCount == 0 ? "Empty" : workspace.applications.joined(separator: ", ")
            let entry = menu.addItem(withTitle: "\(workspace.name) — \(detail)", action: #selector(selectWorkspace(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = workspace.name
            entry.state = workspace.isFocused ? .on : .off
            entry.toolTip = "\(workspace.windowCount) windows"
        }
    }

    @objc private func selectWorkspace(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        workspaceRequests.append(.workspace(name))
    }

    private func switchWorkspace(_ workspace: String) {
        guard enabled else { return }
        workspaceRequests.append(.workspace(workspace))
    }

    private func switchWorkspace(_ request: WorkspaceRequest) {
        guard !committing else { return }
        cancel()
        let destination: String?
        if case .workspace(let name) = request { destination = name } else { destination = nil }
        committing = true
        toggleItem.isEnabled = false
        status("Switching workspace…")
        Task { @MainActor in
            defer {
                self.committing = false
                self.toggleItem.isEnabled = true
            }
            do {
                guard let source = openTileWorkspaces().first(where: \.isFocused)?.name else { throw AeroSpace.Failure(message: "Cannot read the current workspace") }
                let animated = try await self.workspaceTransition.perform(from: source, to: destination) {
                    _ = try await AeroSpace.command(request.arguments)
                    guard let actual = openTileWorkspaces().first(where: \.isFocused)?.name else { throw AeroSpace.Failure(message: "Cannot read the destination workspace") }
                    return actual
                }
                self.status("Workspace · \(animated ? "ready" : "ready (no animation)")")
            } catch {
                self.status(error.localizedDescription)
            }
        }
    }

    private func clearPreview() {
        snapshotTask?.cancel()
        snapshotTask = nil
        snapshot = nil; destination = nil; resizing = false; readingWorkspace = false; phoneGesture = false
        ghost.hide(); preview.hide()
    }
    private func cancel() {
        phonePad.cancelInput()
        drawing.cancel()
        appDrawing.cancel()
        generation += 1
        _ = recognizer.cancel()
        clearPreview()
        if !committing { status("Cancelled — layout unchanged") }
    }

    private func handlePhone(_ event: PhonePadEvent) {
        guard AXIsProcessTrusted(), !committing else { phonePad.cancelInput(); return }
        // A local tile preview owns the layout until it finishes or is cancelled.
        guard phoneGesture || (snapshot == nil && !readingWorkspace && !drawing.needsPolling && !appDrawing.needsPolling) else {
            phonePad.cancelInput()
            return
        }
        switch event {
        case .pointer(let dx, let dy):
            guard let current = CGEvent(source: nil)?.location else { return }
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            let displays = NSScreen.screens.map { CGRect(x: $0.frame.minX, y: top - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height) }
            let proposed = CGPoint(x: current.x + dx * 1800, y: current.y - dy * 1800)
            let candidates = displays.map { rect -> CGPoint in
                CGPoint(x: min(max(proposed.x, rect.minX), rect.maxX - 1), y: min(max(proposed.y, rect.minY), rect.maxY - 1))
            }
            let point = candidates.min { hypot($0.x - proposed.x, $0.y - proposed.y) < hypot($1.x - proposed.x, $1.y - proposed.y) } ?? proposed
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        case .scroll(let dx, let dy):
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                    wheel1: Int32(max(-1000, min(1000, dy * 1200))), wheel2: Int32(max(-1000, min(1000, -dx * 1200))), wheel3: 0)?.post(tap: .cghidEventTap)
        case .click:
            guard let point = CGEvent(source: nil)?.location else { return }
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        case .gesture(let gesture):
            switch gesture {
            case .began(let point): phoneGesture = true; begin(point); phonePad.feedback("Move together, then lift to place", type: "armed")
            case .moved(let point): move(point)
            case .resizeBegan(let change): phoneGesture = true; latestResize = change; begin(.zero, resize: true); phonePad.feedback("Lift to resize", type: "armed")
            case .resized(let change): resizePreview(change)
            case .released: if phoneGesture { release(); phonePad.feedback("Ready") }
            case .cancelled: if phoneGesture { cancel() }
            }
        }
    }
    private func status(_ message: String) {
        statusItem.title = message
        item.button?.toolTip = "OpenTile: \(message)"
    }
    @MainActor @objc private func showPermissionSetup() {
        permissions.show()
    }
    @objc private func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func openCaptureSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    @objc private func showHelp() {
        let alert = NSAlert()
        alert.messageText = "Move and resize tiles with gestures"
        alert.informativeText = "OpenTile includes its own AeroSpace window manager. Allow OpenTile in Accessibility Settings. Quit any other window manager before using OpenTile. Enable gestures from the menu bar.\n\nFocus a tiled window. Place two fingers on the trackpad, pinch inward, hold briefly, then move them together. An outline follows your gesture. Release over the middle of another tile when the purple “Swap windows” preview appears to exchange their places. Release near its edge with the teal preview to insert beside it. Press Escape before release to cancel.\n\nTo resize, hold Option before placing two fingers on the trackpad. Pinch inward to grow the focused tile or spread outward to shrink it. The orange outline previews the requested size; lift to apply or press Escape to cancel. The gesture mode stays fixed until all fingers lift. Side-by-side tiles change width; stacked tiles change height, with neighboring tiles adjusting. OpenTile determines the final size and position.\n\nTo open apps, choose Draw to Open App → Teach an App Symbol, select an application, and save three examples of any symbol. Hold Option, draw that symbol with one finger, then release Option to open the app. Karabiner is not required; existing Caps + O symbols still work. Two fingers still resize.\n\nTo switch workspaces by drawing, hold Control–Option, draw with one finger, and release the keys. Teaching is offered once on your first unrecognized drawing in each mode. Later misses show retry guidance. Add symbols from Draw to Switch Workspace → Teach a Workspace Symbol, or retrain an existing symbol from its submenu. Save three consistent examples; cancelling retraining keeps the original. Draw a saved symbol to switch. Escape cancels. You can change the activation keys in the drawing menu. Drawing switches slide vertically in first-visited workspace order. Enable Screen Recording in Permission Setup for animations; snapshots stay in memory. Reduce Motion skips the slide.\n\nTile movement supports tiles in the current workspace. The preview indicates placement; OpenTile determines final sizes. macOS trackpad gestures can also respond, so two-finger pinch-to-zoom may also respond.\n\nExperimental: the private trackpad interface has been verified only on Apple Silicon."
        alert.addButton(withTitle: "Got It")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    @MainActor @objc private func openEngineConfig() {
        do { NSWorkspace.shared.open(try openTileConfigURL()) }
        catch { status("Cannot open configuration: \(error.localizedDescription)") }
    }

    @objc private func reloadEngine() {
        Task { @MainActor [weak self] in
            do {
                _ = try await AeroSpace.command(["reload-config"])
                self?.status("Window manager configuration reloaded")
            } catch { self?.status(error.localizedDescription) }
        }
    }

    @objc private func quit() {
        guard !committing else { status("Wait for the layout change to finish before quitting"); return }
        NSApp.terminate(nil)
    }
    func applicationWillTerminate(_ notification: Notification) {
        generation += 1
        clearPreview()
        phonePad.stop()
        wallpaperPicker.stop()
        splitMenuBar.stop()
        stopOpenTileEngine()
        bridge.stop()
        polling.stop()
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
