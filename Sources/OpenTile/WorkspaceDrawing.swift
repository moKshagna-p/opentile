import AppKit
import OpenTileCore

private final class DrawingView: NSView {
    var strokes: [[DrawingPoint]] = [] { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 20, yRadius: 20).fill()
        NSColor.systemTeal.setStroke()
        for stroke in strokes {
            let path = NSBezierPath(); path.lineWidth = 4; path.lineCapStyle = .round
            for (index, point) in stroke.enumerated() {
                let p = CGPoint(x: 24 + point.x * (bounds.width - 48), y: 65 + point.y * (bounds.height - 125))
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
    private var mappings: [AppMapping] = []
    private var appGate = AppDrawingGate()
    private var storageKey: String { apps ? "appSymbols.v1" : "workspaceSymbols.v1" }
    private var symbols: [WorkspaceSymbol] = []
    private var choosingWorkspace = false
    private var training: String?
    private var samples: [WorkspaceSymbol] = []
    private var capture = DrawingCapture()
    private var held = false
    private var blocked = false
    private var started = 0.0
    private var previewTime = 0.0
    private var lastInput = 0.0
    private var fingerDown = false
    private let panel: NSPanel
    private let canvas = DrawingView()
    private let label = NSTextField(labelWithString: "")
    private let menu = NSMenu()
    private var chord: NSEvent.ModifierFlags {
        apps ? [.option] : UserDefaults.standard.bool(forKey: "drawingControlShift") ? [.control, .shift] : [.control, .option]
    }
    private var chordName: String { apps ? "Option" : chord.contains(.shift) ? "Control–Shift" : "Control–Option" }

    init(apps: Bool = false) {
        self.apps = apps
        panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 480, height: 340), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([WorkspaceSymbol].self, from: data) { symbols = saved }
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
            let remove = menu.addItem(withTitle: "Forget symbol for \(name)", action: #selector(forget(_:)), keyEquivalent: "")
            remove.target = self; remove.representedObject = name
        }
    }
    @objc private func changeChord() {
        cancel(); held = false
        UserDefaults.standard.set(!chord.contains(.shift), forKey: "drawingControlShift")
        rebuildMenu()
    }
    @objc private func forget(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        symbols.removeAll { $0.workspace == name }; save(); rebuildMenu()
    }
    @objc private func teach() { beginTraining() }

    private func beginTraining(firstDrawing: [[DrawingPoint]]? = nil) {
        guard canTrain?() == true else { onStatus?("Enable gestures before teaching a symbol"); return }
        guard !choosingWorkspace else { return }
        choosingWorkspace = true
        defer { choosingWorkspace = false }
        let alert = NSAlert()
        alert.messageText = firstDrawing == nil ? "Teach a workspace symbol" : "Learn this workspace symbol?"
        alert.informativeText = "Enter the exact AeroSpace workspace name (for example 1 or A). Then hold \(chordName), draw with one finger, and release the keys. Repeat three times. You can lift your finger between strokes while holding the keys."
        if firstDrawing != nil {
            alert.informativeText = "This drawing has no confident match. Enter the exact AeroSpace workspace name it should open (for example 1 or A). This drawing counts as your first example; draw it two more times to save it. Existing examples for that workspace are replaced only after all three are collected."
        }
        if apps { reloadMappings() }
        if apps && mappings.isEmpty { onStatus?("No Caps + O app mappings found in Karabiner"); return }
        let picker = NSPopUpButton(frame: CGRect(x: 0, y: 0, width: 280, height: 26))
        if apps {
            alert.messageText = "Teach an app symbol"
            alert.informativeText = "Choose one of your Caps + O shortcuts. Hold Option, draw its letter with one finger, then release Option. Save three examples; you can lift between strokes. Two fingers resize instead."
            if firstDrawing != nil { alert.informativeText += " This drawing counts as the first example." }
            picker.addItems(withTitles: mappings.map { "\($0.key.uppercased()) → \($0.application)" })
        }
        let input = NSTextField(frame: CGRect(x: 0, y: 0, width: 280, height: 24))
        input.placeholderString = "Workspace name"
        alert.accessoryView = apps ? picker : input; alert.addButton(withTitle: firstDrawing == nil ? "Start Training" : "Learn Symbol"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = apps ? picker : input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = apps ? mappings[picker.indexOfSelectedItem].key : input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("\n"), !name.contains("\r") else { return }
        guard canTrain?() == true else { return }
        cancel(); training = name
        samples = firstDrawing.map { [WorkspaceSymbol(workspace: name, strokes: $0)] } ?? []
        rebuildMenu()
        show("Teach \(name) · sample \(samples.count + 1) of 3\nHold \(chordName) and draw")
    }
    @objc private func cancelTraining() { training = nil; samples = []; cancel(); rebuildMenu() }
    private func save() {
        if let data = try? JSONEncoder().encode(symbols) { UserDefaults.standard.set(data, forKey: storageKey) }
    }
    private func reloadMappings() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/karabiner/karabiner.json")
        mappings = (try? Data(contentsOf: url)).map(AppMapping.read) ?? []
        rebuildMenu()
    }
    private var availableSymbols: [WorkspaceSymbol] {
        apps ? symbols.filter { symbol in mappings.contains { $0.key == symbol.workspace } } : symbols
    }
    private func show(_ message: String) {
        label.stringValue = message
        if !panel.isVisible {
            let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
            if let frame = screen?.visibleFrame { panel.setFrameOrigin(CGPoint(x: frame.midX-240, y: frame.midY-170)) }
            panel.orderFrontRegardless()
        }
    }
    func cancel() { blocked = true; panel.orderOut(nil); capture = DrawingCapture() }
    func stop() { cancelTraining(); held = false; appGate = AppDrawingGate() }

    /// Returns true while drawing owns this frame, including the release frame.
    func process(_ frames: [TouchBridge.Frame], allowed: Bool) -> Bool {
        let flags = NSEvent.modifierFlags.intersection([.control, .option, .shift, .command])
        let down = flags == chord
        if apps {
            let owns = appGate.ownsDrawing(optionOnly: down, contactCounts: frames.map { $0.contacts.count })
            if down && !owns { cancel(); held = false; return false }
        }
        if choosingWorkspace { held = down; blocked = true; return true }
        let now = ProcessInfo.processInfo.systemUptime
        if !allowed { cancel(); held = down; return down }
        if down && !held {
            if apps { reloadMappings() }
            held = true; blocked = false; started = now; lastInput = now; fingerDown = false; capture = DrawingCapture(); canvas.strokes = []
            show(training.map { "Teach \($0) · sample \(samples.count+1) of 3\nDraw with one finger · Escape cancels" } ?? (apps ? "Draw your app shortcut letter\nRelease Option to open · Two fingers resize" : "Draw your workspace symbol\nRelease keys to switch · Escape cancels"))
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
        for frame in frames {
                    capture.update(frame.contacts, time: frame.time)
                    lastInput = now; fingerDown = !frame.contacts.isEmpty
                }
        if capture.cancelled { cancel(); onStatus?("Drawing cancelled — use one finger"); return true }
        canvas.strokes = capture.strokes
        if training == nil && now - previewTime > 0.12 {
            previewTime = now
            let match = WorkspaceMatcher.match(capture.strokes, symbols: availableSymbols)
            show(match.map { key in apps ? "\(mappings.first { $0.key == key }?.application ?? key)\nRelease Option to open · Escape cancels" : "Workspace \(key)\nRelease keys to switch · Escape cancels" } ?? "Keep drawing · no confident match\nRelease keys to teach · Escape cancels")
        }
        return true
    }
    private func finish() {
        panel.orderOut(nil)
        guard WorkspaceMatcher.isValid(capture.strokes) else { onStatus?("Drawing too small — try again"); return }
        if apps { reloadMappings() }
        if let training {
            if apps && !mappings.contains(where: { $0.key == training }) {
                cancelTraining(); onStatus?("App shortcut was removed from Karabiner"); return
            }
            // Require repeatable training samples before persisting them.
            if !samples.isEmpty && WorkspaceMatcher.match(capture.strokes, symbols: samples) == nil {
                show("That sample looks different · try again\nTeach \(training) · sample \(samples.count+1) of 3"); return
            }
            samples.append(WorkspaceSymbol(workspace: training, strokes: capture.strokes))
            if samples.count == 3 {
                symbols.removeAll { $0.workspace == training }; symbols.append(contentsOf: samples)
                self.training = nil; samples = []; save(); rebuildMenu()
                onStatus?("Symbol saved for \(training) — hold \(chordName) and draw")
            } else { show("Sample saved · teach \(training) again\nHold \(chordName) · sample \(samples.count+1) of 3") }
        } else if let workspace = WorkspaceMatcher.match(capture.strokes, symbols: availableSymbols) {
            if apps {
                guard let mapping = mappings.first(where: { $0.key == workspace }) else { return }
                // Pass arguments directly; never execute the imported shell command.
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = ["-a", mapping.application]
                process.terminationHandler = { [weak self] task in
                    DispatchQueue.main.async { self?.onStatus?(task.terminationStatus == 0 ? "Opened \(mapping.application)" : "Could not open \(mapping.application)") }
                }
                do { try process.run() } catch { onStatus?("Could not open \(mapping.application): \(error.localizedDescription)") }
            } else { onSwitch?(workspace) }
        } else { beginTraining(firstDrawing: capture.strokes) }
    }
}
