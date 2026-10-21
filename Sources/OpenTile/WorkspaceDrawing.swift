import AppKit
import OpenTileCore
import UniformTypeIdentifiers

final class DrawingIntroduction {
    private let defaults: UserDefaults
    private let key: String

    init(apps: Bool, hasSymbols: Bool, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = apps ? "hasIntroducedAppDrawing" : "hasIntroducedWorkspaceDrawing"
        if hasSymbols { markPresented() }
    }

    var shouldOffer: Bool { !defaults.bool(forKey: key) }
    func markPresented() { defaults.set(true, forKey: key) }
}

private final class DrawingView: NSView {
    var strokes: [[DrawingPoint]] = [] { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 20, yRadius: 20).fill()
        NSColor.systemTeal.setStroke()
        Self.draw(strokes, in: CGRect(x: 24, y: 65, width: bounds.width - 48, height: bounds.height - 125), lineWidth: 4)
    }

    static func draw(_ strokes: [[DrawingPoint]], in rect: CGRect, lineWidth: CGFloat) {
        for stroke in strokes {
            let path = NSBezierPath(); path.lineWidth = lineWidth; path.lineCapStyle = .round
            for (index, point) in stroke.enumerated() {
                let p = CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
                if index == 0 { path.move(to: p) } else { path.line(to: p) }
            }
            path.stroke()
        }
    }
}

final class WorkspaceDrawing: NSObject {
    var onSwitch: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    var canTrain: (() -> Bool)?
    private let apps: Bool
    private let defaults: UserDefaults
    private let introduction: DrawingIntroduction
    private let mappingsURL: URL
    private var mappingsData: Data?
    private var mappings: [AppMapping] = []
    private var appGate = AppDrawingGate()
    private var storageKey: String { apps ? "appSymbols.v1" : "workspaceSymbols.v1" }
    private var previewKey: String { apps ? "showAppDrawingPreview" : "showWorkspaceDrawingPreview" }
    private var previewEnabled: Bool { defaults.object(forKey: previewKey) as? Bool ?? true }
    private var shouldShowPreview: Bool { training != nil || previewEnabled }
    private var symbols: [WorkspaceSymbol] = []
    private var choosingWorkspace = false
    private var training: String?
    private var samples: [WorkspaceSymbol] = []
    private var capture = DrawingCapture()
    private var held = false
    private var blocked = false
    private var started = 0.0
    private var previewTime = 0.0
    private var needsPreviewMatch = true
    private var lastInput = 0.0
    private var fingerDown = false
    private var feedbackDismissal: DispatchWorkItem?
    private let panel: NSPanel
    private let canvas = DrawingView()
    private let label = NSTextField(labelWithString: "")
    private let menu = NSMenu()
    private var chord: NSEvent.ModifierFlags {
        apps ? [.option] : defaults.bool(forKey: "drawingControlShift") ? [.control, .shift] : [.control, .option]
    }
    private var chordName: String { apps ? "Option" : chord.contains(.shift) ? "Control–Shift" : "Control–Option" }

    init(apps: Bool = false, defaults: UserDefaults = .standard,
         mappingsURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/karabiner/karabiner.json")) {
        self.apps = apps
        self.defaults = defaults
        self.mappingsURL = mappingsURL
        let saved = defaults.data(forKey: apps ? "appSymbols.v1" : "workspaceSymbols.v1")
            .flatMap { try? JSONDecoder().decode([WorkspaceSymbol].self, from: $0) } ?? []
        symbols = saved
        introduction = DrawingIntroduction(apps: apps, hasSymbols: !saved.isEmpty, defaults: defaults)
        panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 480, height: 340), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.animationBehavior = .none
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.level = .floating; panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = canvas
        label.frame = CGRect(x: 20, y: 12, width: 440, height: 48)
        label.alignment = .center; label.maximumNumberOfLines = 2
        label.font = .systemFont(ofSize: 14, weight: .medium)
        canvas.addSubview(label)
        if apps { reloadMappings() }
        rebuildMenu()
    }
    func install(in parent: NSMenu) {
        let item = parent.addItem(withTitle: apps ? "Draw to Open App" : "Draw to Switch Workspace", action: nil, keyEquivalent: "")
        item.submenu = menu
    }
    private func rebuildMenu() {
        menu.removeAllItems()
        let info = menu.addItem(withTitle: "Hold \(chordName), draw, then release", action: nil, keyEquivalent: "")
        info.isEnabled = false
        let train = menu.addItem(withTitle: apps ? "Teach an App Symbol…" : "Teach a Workspace Symbol…", action: #selector(teach), keyEquivalent: ""); train.target = self
        let cancel = menu.addItem(withTitle: "Cancel Training", action: #selector(cancelTraining), keyEquivalent: ""); cancel.target = self; cancel.isEnabled = training != nil
        let preview = menu.addItem(withTitle: "Show Drawing Preview", action: #selector(togglePreview), keyEquivalent: "")
        preview.target = self; preview.state = previewEnabled ? .on : .off
        let previewInfo = menu.addItem(withTitle: "Preview always appears while teaching", action: nil, keyEquivalent: "")
        previewInfo.isEnabled = false
        if !apps {
            let shortcut = menu.addItem(withTitle: "Use Control–Shift instead", action: #selector(changeChord), keyEquivalent: "")
            shortcut.target = self; shortcut.state = chord.contains(.shift) ? .on : .off
        }
        if apps {
            for mapping in mappings {
                let entry = menu.addItem(withTitle: "\(mapping.key.uppercased()) → \(mapping.application)", action: nil, keyEquivalent: "")
                entry.isEnabled = false
            }
        }
        menu.addItem(.separator())
        for name in Set(symbols.map(\.workspace)).sorted() {
            let entry = menu.addItem(withTitle: apps ? displayName(name) : "Workspace \(name)", action: nil, keyEquivalent: "")
            let strokes = symbols.first { $0.workspace == name }!.strokes
            let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { rect in
                NSColor.labelColor.setStroke()
                DrawingView.draw(strokes, in: rect.insetBy(dx: 2, dy: 2), lineWidth: 2)
                return true
            }
            image.isTemplate = true; entry.image = image
            let actions = NSMenu()
            let retrain = actions.addItem(withTitle: "Retrain Symbol…", action: #selector(retrain(_:)), keyEquivalent: "")
            retrain.target = self; retrain.representedObject = name
            let remove = actions.addItem(withTitle: "Forget Symbol", action: #selector(forget(_:)), keyEquivalent: "")
            remove.target = self; remove.representedObject = name
            entry.submenu = actions
        }
    }
    @objc private func togglePreview() {
        defaults.set(!previewEnabled, forKey: previewKey)
        needsPreviewMatch = true
        if !shouldShowPreview { panel.orderOut(nil) }
        rebuildMenu()
    }
    @objc private func changeChord() {
        cancel(); held = false
        defaults.set(!chord.contains(.shift), forKey: "drawingControlShift")
        rebuildMenu()
    }
    @objc private func forget(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        symbols.removeAll { $0.workspace == name }; save(); rebuildMenu()
    }
    @objc private func teach() { beginTraining() }
    @objc private func retrain(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        beginTraining(target: name)
    }

    private func beginTraining(firstDrawing: [[DrawingPoint]]? = nil, target: String? = nil) {
        guard canTrain?() == true else { onStatus?("Enable gestures before teaching a symbol"); return }
        guard !choosingWorkspace else { return }
        choosingWorkspace = true
        defer { choosingWorkspace = false }
        introduction.markPresented()
        let name: String
        if let target {
            if apps && Self.application(for: target, mappings: mappings) == nil {
                onStatus?("App shortcut is unavailable — choose Teach an App Symbol from the menu"); return
            }
            name = target
        } else if apps {
            NSApp.activate(ignoringOtherApps: true)
            let picker = NSOpenPanel()
            picker.title = "Teach an App Symbol"
            picker.message = "Choose an app, then hold Option and draw any symbol with one finger. Save three examples; two fingers still resize. Add more symbols later from Draw to Open App in the menu."
            picker.prompt = "Start Training"
            picker.allowedContentTypes = [.applicationBundle]
            picker.canChooseDirectories = false
            picker.allowsMultipleSelection = false
            picker.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
            guard picker.runModal() == .OK, let url = picker.url else { return }
            name = url.path
        } else {
            let alert = NSAlert()
            alert.messageText = firstDrawing == nil ? "Teach a workspace symbol" : "Learn your first workspace symbol"
            alert.informativeText = "Enter the exact AeroSpace workspace name (for example 1 or A). Then hold \(chordName), draw with one finger, and release the keys. Repeat three times. You can lift your finger between strokes while holding the keys."
            if firstDrawing != nil {
                alert.informativeText = "Enter the workspace name this symbol should open (for example 1 or A). This drawing counts as your first example; draw it two more times to save it. After this introduction, unmatched drawings only show retry guidance. To add or retrain symbols, use Draw to Switch Workspace in the menu."
            }
            let input = NSTextField(frame: CGRect(x: 0, y: 0, width: 280, height: 24))
            input.placeholderString = "Workspace name"
            alert.accessoryView = input; alert.addButton(withTitle: firstDrawing == nil ? "Start Training" : "Learn Symbol"); alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = input
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !name.isEmpty, !name.contains("\n"), !name.contains("\r") else { return }
        guard canTrain?() == true else { return }
        cancel(); training = name
        samples = firstDrawing.map { [WorkspaceSymbol(workspace: name, strokes: $0)] } ?? []
        rebuildMenu()
        show("Teach \(displayName(name)) · sample \(samples.count + 1) of 3\nHold \(chordName) and draw")
    }
    @objc private func cancelTraining() { training = nil; samples = []; cancel(); rebuildMenu() }
    private func save() {
        needsPreviewMatch = true
        if let data = try? JSONEncoder().encode(symbols) { defaults.set(data, forKey: storageKey) }
    }
    private func reloadMappings() {
        let data = try? Data(contentsOf: mappingsURL)
        guard data != mappingsData else { return }
        mappingsData = data
        mappings = data.map(AppMapping.read) ?? []
        needsPreviewMatch = true
        rebuildMenu()
    }
    private var availableSymbols: [WorkspaceSymbol] {
        apps ? symbols.filter { Self.application(for: $0.workspace, mappings: mappings) != nil } : symbols
    }
    static func application(for symbol: String, mappings: [AppMapping]) -> String? {
        if symbol.hasPrefix("/") {
            let url = URL(fileURLWithPath: symbol)
            return url.pathExtension.lowercased() == "app" ? url.path : nil
        }
        return mappings.first { $0.key == symbol }?.application
    }
    private func displayName(_ symbol: String) -> String {
        guard apps, let application = Self.application(for: symbol, mappings: mappings) else { return symbol }
        let url = URL(fileURLWithPath: application)
        return url.pathExtension.lowercased() == "app" ? url.deletingPathExtension().lastPathComponent : application
    }
    private func show(_ message: String) {
        feedbackDismissal?.cancel(); feedbackDismissal = nil
        guard shouldShowPreview else { panel.orderOut(nil); return }
        label.stringValue = message
        if !panel.isVisible {
            let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
            if let frame = screen?.visibleFrame { panel.setFrameOrigin(CGPoint(x: frame.midX-240, y: frame.midY-170)) }
            panel.orderFrontRegardless()
        }
    }

    private func showFeedback(_ message: String) {
        onStatus?(message.replacingOccurrences(of: "\n", with: " · "))
        show(message)
        guard shouldShowPreview else { return }
        let dismissal = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        feedbackDismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: dismissal)
    }
    /// Keep timeout checks alive while a drawing chord owns input.
    var needsPolling: Bool { held && !blocked }

    func cancel() { feedbackDismissal?.cancel(); feedbackDismissal = nil; blocked = true; panel.orderOut(nil); capture = DrawingCapture() }
    func stop() { cancelTraining(); held = false; appGate = AppDrawingGate() }

    /// Returns true while drawing owns this frame, including the release frame.
    func process(_ frames: [TouchBridge.Frame], allowed: Bool, modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags,
                 now: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        let flags = modifiers.intersection([.control, .option, .shift, .command])
        let down = flags == chord
        if apps {
            let owns = appGate.ownsDrawing(optionOnly: down, contactCounts: frames.map { $0.contacts.count })
            if down && !owns { cancel(); held = false; return false }
        }
        if choosingWorkspace { held = down; blocked = true; return true }
        if !allowed { cancel(); held = down; return down }
        if down && !held {
            if apps { reloadMappings() }
            held = true; blocked = false; started = now; lastInput = now; fingerDown = false; capture = DrawingCapture(); canvas.strokes = []
            needsPreviewMatch = true
            show(training.map { "Teach \(displayName($0)) · sample \(samples.count+1) of 3\nDraw with one finger · Escape cancels" } ?? (apps ? "Draw your app symbol\nRelease Option to open · Two fingers resize" : "Draw your workspace symbol\nRelease keys to switch · Escape cancels"))
            return true // discard frames queued before activation
        }
        if !down && held {
            held = false
            if !blocked && now - started <= 12 && (!fingerDown || now - lastInput < 0.5) && flags.isSubset(of: chord) {
                for frame in frames {
                    capture.update(frame.contacts, time: frame.time)
                    lastInput = now; fingerDown = !frame.contacts.isEmpty
                }
                if !capture.cancelled { finish() } else { panel.orderOut(nil) }
            } else { panel.orderOut(nil) }
            blocked = false
            return true
        }
        guard down else { return false }
        guard !blocked else { return true }
        if now - started > 12 { cancel(); onStatus?("Drawing timed out — try again"); return true }
        // Capture only appends ink; these counts detect changes without comparing point arrays.
        let previousInkSize = (capture.strokes.count, capture.strokes.last?.count)
        for frame in frames {
                    capture.update(frame.contacts, time: frame.time)
                    lastInput = now; fingerDown = !frame.contacts.isEmpty
                }
        if capture.cancelled { cancel(); onStatus?("Drawing cancelled — use one finger"); return true }
        let inkSize = (capture.strokes.count, capture.strokes.last?.count)
        if inkSize != previousInkSize { needsPreviewMatch = true }
        if shouldShowPreview && inkSize != (canvas.strokes.count, canvas.strokes.last?.count) {
            canvas.strokes = capture.strokes
        }
        if needsPreviewMatch && previewEnabled && training == nil && now - previewTime > 0.12 {
            previewTime = now
            needsPreviewMatch = false
            let match = WorkspaceMatcher.match(capture.strokes, symbols: availableSymbols)
            show(match.map { key in apps ? "\(displayName(key))\nRelease Option to open · Escape cancels" : "Workspace \(key)\nRelease keys to switch · Escape cancels" } ?? (introduction.shouldOffer ? "Keep drawing · no confident match\nRelease keys to teach your first symbol" : "Keep drawing · no confident match\nRetry, or teach a symbol from the menu"))
        }
        return true
    }
    private func finish() {
        panel.orderOut(nil)
        guard WorkspaceMatcher.isValid(capture.strokes) else { showFeedback("Drawing too small — try again"); return }
        if apps { reloadMappings() }
        if let training {
            if apps && Self.application(for: training, mappings: mappings) == nil {
                cancelTraining(); onStatus?("App shortcut was removed from Karabiner"); return
            }
            // Require repeatable training samples before persisting them.
            if !samples.isEmpty && WorkspaceMatcher.match(capture.strokes, symbols: samples) == nil {
                show("That sample looks different · try again\nTeach \(displayName(training)) · sample \(samples.count+1) of 3"); return
            }
            samples.append(WorkspaceSymbol(workspace: training, strokes: capture.strokes))
            if samples.count == 3 {
                symbols.removeAll { $0.workspace == training }; symbols.append(contentsOf: samples)
                self.training = nil; samples = []; save(); rebuildMenu()
                showFeedback("Symbol saved for \(displayName(training))\nHold \(chordName) and draw")
            } else { show("Sample saved · teach \(displayName(training)) again\nHold \(chordName) · sample \(samples.count+1) of 3") }
        } else if let workspace = WorkspaceMatcher.match(capture.strokes, symbols: availableSymbols) {
            if apps {
                guard let application = Self.application(for: workspace, mappings: mappings) else { return }
                // Pass arguments directly; never execute the imported shell command.
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = ["-a", application]
                let name = displayName(workspace)
                process.terminationHandler = { [weak self] task in
                    DispatchQueue.main.async { self?.onStatus?(task.terminationStatus == 0 ? "Opened \(name)" : "Could not open \(name)") }
                }
                do { try process.run() } catch { onStatus?("Could not open \(name): \(error.localizedDescription)") }
            } else { onSwitch?(workspace) }
        } else if introduction.shouldOffer {
            beginTraining(firstDrawing: capture.strokes)
        } else {
            showFeedback("Symbol not recognized — try again\nTeach or retrain symbols from the menu")
        }
    }

    deinit { feedbackDismissal?.cancel() }
}
