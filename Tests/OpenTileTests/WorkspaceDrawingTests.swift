import AppKit
import Testing
@testable import OpenTile
@testable import OpenTileCore

struct WorkspaceDrawingTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "WorkspaceDrawingTests.\(UUID())")!
    }

    private func clear(_ defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys { defaults.removeObject(forKey: key) }
    }

    private var vertical: [[DrawingPoint]] {
        [(0..<20).map { DrawingPoint(x: 0.2, y: 0.1 + Double($0) * 0.035) }]
    }

    private var horizontal: [[DrawingPoint]] {
        [(0..<20).map { DrawingPoint(x: 0.1 + Double($0) * 0.035, y: 0.2) }]
    }

    // Observe the existing preview effects without adding runtime counters or matcher hooks.
    private func state<T>(_ name: String, in drawing: WorkspaceDrawing) throws -> T {
        try #require(Mirror(reflecting: drawing).children.first { $0.label == name }?.value as? T)
    }

    private func frames(_ points: [DrawingPoint], from time: Double = 1) -> [TouchBridge.Frame] {
        points.enumerated().map { index, point in
            .init(contacts: [.init(id: 1, x: point.x, y: point.y)], time: time + Double(index) * 0.01, optionHeld: true)
        }
    }

    @Test @MainActor func unchangedInkSkipsRedrawAndMatchingButDeferredInkStillMatches() throws {
        let defaults = defaults()
        defer { clear(defaults) }
        defaults.set(try JSONEncoder().encode([WorkspaceSymbol(workspace: "1", strokes: vertical)]), forKey: "workspaceSymbols.v1")
        let drawing = WorkspaceDrawing(defaults: defaults)
        defer { drawing.stop() }
        let chord: NSEvent.ModifierFlags = [.control, .option]
        let canvas: NSView = try state("canvas", in: drawing)
        _ = drawing.process([], allowed: true, modifiers: chord, now: 100)
        _ = drawing.process(frames(vertical[0]), allowed: true, modifiers: chord, now: 100.2)
        let firstMatch: Double = try state("previewTime", in: drawing)
        #expect(firstMatch == 100.2)

        // A one-second hold includes empty ticks, repeated contact points, and finger lift.
        for tick in 1...60 {
            canvas.displayIfNeeded()
            let repeated = tick.isMultiple(of: 2) ? frames([vertical[0].last!], from: 2 + Double(tick)) : []
            _ = drawing.process(repeated, allowed: true, modifiers: chord, now: 100.2 + Double(tick) / 60)
            #expect(!canvas.needsDisplay)
        }
        canvas.displayIfNeeded()
        _ = drawing.process([.init(contacts: [], time: 100, optionHeld: true)], allowed: true, modifiers: chord, now: 101.21)
        #expect(!canvas.needsDisplay)
        #expect(try state("previewTime", in: drawing) as Double == firstMatch)
        let heldCapture: DrawingCapture = try state("capture", in: drawing)
        #expect(heldCapture.strokes == vertical)

        // Starting a stroke at the same point still changes ink and must redraw.
        _ = drawing.process(frames([vertical[0].last!], from: 101), allowed: true, modifiers: chord, now: 101.22)
        #expect(canvas.needsDisplay)
        #expect(try state("previewTime", in: drawing) as Double == 101.22)
        canvas.displayIfNeeded()
        _ = drawing.process(frames([.init(x: 0.3, y: 0.8)], from: 102), allowed: true, modifiers: chord, now: 101.23)
        #expect(canvas.needsDisplay)
        #expect(try state("previewTime", in: drawing) as Double == 101.22)
        canvas.displayIfNeeded()
        _ = drawing.process([], allowed: true, modifiers: chord, now: 101.4)
        #expect(!canvas.needsDisplay)
        #expect(try state("previewTime", in: drawing) as Double == 101.4)
    }

    @MainActor private func draw(_ strokes: [[DrawingPoint]], with drawing: WorkspaceDrawing,
                                chord: NSEvent.ModifierFlags = [.control, .option]) {
        _ = drawing.process([], allowed: true, modifiers: chord)
        var time = 1.0
        for stroke in strokes {
            let frames = stroke.map { point -> TouchBridge.Frame in
                defer { time += 0.01 }
                return .init(contacts: [.init(id: 1, x: point.x, y: point.y)], time: time, optionHeld: chord.contains(.option))
            }
            _ = drawing.process(frames, allowed: true, modifiers: chord)
            _ = drawing.process([.init(contacts: [], time: time, optionHeld: true)], allowed: true, modifiers: chord)
            time += 0.01
        }
        _ = drawing.process([], allowed: true, modifiers: [])
    }

    @Test(arguments: [true, false]) @MainActor
    func releaseMatchesFinalInkEvenWhenPreviewIsDeferred(tailOnRelease: Bool) throws {
        let defaults = defaults()
        defer { clear(defaults) }
        defaults.set(try JSONEncoder().encode([WorkspaceSymbol(workspace: "1", strokes: vertical)]), forKey: "workspaceSymbols.v1")
        let drawing = WorkspaceDrawing(defaults: defaults)
        defer { drawing.stop() }
        var switches: [String] = []
        drawing.onSwitch = { switches.append($0) }
        let chord: NSEvent.ModifierFlags = [.control, .option]
        _ = drawing.process([], allowed: true, modifiers: chord, now: 100)
        _ = drawing.process(frames(Array(vertical[0].prefix(4))), allowed: true, modifiers: chord, now: 100.2)
        let tail = frames(Array(vertical[0].dropFirst(4)), from: 2)
        if !tailOnRelease {
            _ = drawing.process(tail, allowed: true, modifiers: chord, now: 100.21)
        }
        #expect(drawing.process(tailOnRelease ? tail : [], allowed: true, modifiers: [.control], now: 100.22))
        #expect(switches == ["1"])
        let captured: DrawingCapture = try state("capture", in: drawing)
        #expect(captured.strokes == vertical)
        #expect(try state("previewTime", in: drawing) as Double == 100.2)
        #expect(!drawing.needsPolling)
    }

    @Test(arguments: ["cancel", "stop", "inputLoss", "staleInput", "timeout", "extraModifier", "twoFingers", "changeChord"])
    @MainActor func pendingPreviewDoesNotSurviveCancellation(reason: String) throws {
        let defaults = defaults()
        defer { clear(defaults) }
        defaults.set(try JSONEncoder().encode([WorkspaceSymbol(workspace: "1", strokes: vertical)]), forKey: "workspaceSymbols.v1")
        let drawing = WorkspaceDrawing(defaults: defaults)
        defer { drawing.stop() }
        var switches: [String] = []
        drawing.onSwitch = { switches.append($0) }
        var chord: NSEvent.ModifierFlags = [.control, .option]
        _ = drawing.process([], allowed: true, modifiers: chord, now: 100)
        _ = drawing.process([], allowed: true, modifiers: chord, now: 100.2)
        _ = drawing.process(frames(vertical[0]), allowed: true, modifiers: chord, now: 100.21)
        switch reason {
        case "cancel": drawing.cancel()
        case "stop": drawing.stop()
        case "inputLoss": _ = drawing.process([], allowed: false, modifiers: chord, now: 100.22)
        case "staleInput": _ = drawing.process([], allowed: true, modifiers: [], now: 100.8)
        case "timeout": _ = drawing.process([], allowed: true, modifiers: chord, now: 113)
        case "extraModifier": _ = drawing.process([], allowed: true, modifiers: [.control, .option, .command], now: 100.22)
        case "twoFingers":
            _ = drawing.process([.init(contacts: [.init(id: 1, x: 0.2, y: 0.3), .init(id: 2, x: 0.4, y: 0.5)], time: 2, optionHeld: true)], allowed: true, modifiers: chord, now: 100.22)
        default:
            let parent = NSMenu()
            drawing.install(in: parent)
            let item = try #require(parent.items.first?.submenu?.items.first { $0.title == "Use Control–Shift instead" })
            drawing.perform(item.action, with: item)
            chord = [.control, .shift]
        }
        _ = drawing.process([], allowed: true, modifiers: [], now: 113.01)
        #expect(switches.isEmpty)
        #expect(!drawing.needsPolling)
        _ = drawing.process([], allowed: true, modifiers: chord, now: 120)
        _ = drawing.process(frames(vertical[0]), allowed: true, modifiers: chord, now: 120.2)
        #expect(try state("previewTime", in: drawing) as Double == 120.2)
        _ = drawing.process([], allowed: true, modifiers: [], now: 120.21)
        #expect(switches == ["1"])
    }

    @Test @MainActor func previewToggleAndSymbolRemovalRefreshUnchangedInk() throws {
        let defaults = defaults()
        defer { clear(defaults) }
        defaults.set(false, forKey: "showWorkspaceDrawingPreview")
        defaults.set(try JSONEncoder().encode([WorkspaceSymbol(workspace: "1", strokes: vertical)]), forKey: "workspaceSymbols.v1")
        let drawing = WorkspaceDrawing(defaults: defaults)
        defer { drawing.stop() }
        let parent = NSMenu()
        drawing.install(in: parent)
        let menu = try #require(parent.items.first?.submenu)
        func toggle() throws {
            let item = try #require(menu.items.first { $0.title == "Show Drawing Preview" })
            drawing.perform(item.action, with: item)
        }
        let chord: NSEvent.ModifierFlags = [.control, .option]
        _ = drawing.process([], allowed: true, modifiers: chord, now: 100)
        _ = drawing.process(frames(vertical[0]), allowed: true, modifiers: chord, now: 100.2)
        #expect(try state("previewTime", in: drawing) as Double == 0)
        try toggle()
        _ = drawing.process([], allowed: true, modifiers: chord, now: 100.3)
        let canvas: NSView = try state("canvas", in: drawing)
        let strokes: [[DrawingPoint]] = try #require(Mirror(reflecting: canvas).children.first { $0.label == "strokes" }?.value as? [[DrawingPoint]])
        #expect(strokes == vertical)
        #expect(try state("previewTime", in: drawing) as Double == 100.3)
        try toggle()
        try toggle()
        _ = drawing.process([], allowed: true, modifiers: chord, now: 100.5)
        #expect(try state("previewTime", in: drawing) as Double == 100.5)
        let entry = try #require(menu.items.first { $0.title == "Workspace 1" })
        let forget = try #require(entry.submenu?.items.first { $0.title == "Forget Symbol" })
        drawing.perform(forget.action, with: forget)
        _ = drawing.process([], allowed: true, modifiers: chord, now: 100.7)
        #expect(try state("previewTime", in: drawing) as Double == 100.7)
        let label: NSTextField = try state("label", in: drawing)
        #expect(label.stringValue.hasPrefix("Keep drawing"))
    }

    @Test func introductionIsRememberedEvenWithoutASavedSymbol() {
        let defaults = defaults()
        defer { clear(defaults) }
        let first = DrawingIntroduction(apps: false, hasSymbols: false, defaults: defaults)
        #expect(first.shouldOffer)
        first.markPresented() // Dismissing the introduction still counts as seeing it.
        #expect(!DrawingIntroduction(apps: false, hasSymbols: false, defaults: defaults).shouldOffer)
        #expect(DrawingIntroduction(apps: true, hasSymbols: false, defaults: defaults).shouldOffer)
    }

    @Test func existingSymbolsSkipIntroductionEvenAfterTheyAreForgotten() {
        let defaults = defaults()
        defer { clear(defaults) }
        #expect(!DrawingIntroduction(apps: false, hasSymbols: true, defaults: defaults).shouldOffer)
        #expect(!DrawingIntroduction(apps: false, hasSymbols: false, defaults: defaults).shouldOffer)
    }

    @Test @MainActor func unmatchedDrawingDoesNotTeachOrOverwriteExistingSymbols() throws {
        let defaults = defaults()
        defer { clear(defaults) }
        defaults.set(false, forKey: "showWorkspaceDrawingPreview")
        let saved = try JSONEncoder().encode([WorkspaceSymbol(workspace: "1", strokes: vertical)])
        defaults.set(saved, forKey: "workspaceSymbols.v1")
        let drawing = WorkspaceDrawing(defaults: defaults)
        defer { drawing.stop() }
        drawing.canTrain = { Issue.record("Recognition misses must not open training"); return false }
        var switches: [String] = []
        var statuses: [String] = []
        drawing.onSwitch = { switches.append($0) }
        drawing.onStatus = { statuses.append($0) }
        draw(horizontal, with: drawing)
        draw(horizontal, with: drawing)
        #expect(switches.isEmpty)
        #expect(statuses.count == 2)
        #expect(defaults.data(forKey: "workspaceSymbols.v1") == saved)
        #expect(!drawing.needsPolling)
        draw(vertical, with: drawing)
        #expect(switches == ["1"])
    }

    @Test @MainActor func dismissedIntroductionKeepsLaterMissesOutOfTraining() {
        let defaults = defaults()
        defer { clear(defaults) }
        defaults.set(false, forKey: "showWorkspaceDrawingPreview")
        DrawingIntroduction(apps: false, hasSymbols: false, defaults: defaults).markPresented()
        let drawing = WorkspaceDrawing(defaults: defaults)
        defer { drawing.stop() }
        drawing.canTrain = { Issue.record("A dismissed introduction must not reappear"); return false }
        var statuses: [String] = []
        drawing.onStatus = { statuses.append($0) }
        draw(vertical, with: drawing)
        #expect(statuses.count == 1)
        #expect(defaults.data(forKey: "workspaceSymbols.v1") == nil)
        #expect(!drawing.needsPolling)
    }

    @Test func directAppsAndLegacyKarabinerSymbolsResolveWithoutShellParsing() {
        let mappings = [AppMapping(key: "f", application: "Firefox.app")]
        #expect(WorkspaceDrawing.application(for: "f", mappings: mappings) == "Firefox.app")
        #expect(WorkspaceDrawing.application(for: "f", mappings: []) == nil)
        #expect(WorkspaceDrawing.application(for: "/Applications/Visual Studio Code.app", mappings: []) == "/Applications/Visual Studio Code.app")
        #expect(WorkspaceDrawing.application(for: "/Applications/Test; echo hello.app", mappings: []) == "/Applications/Test; echo hello.app")
        #expect(WorkspaceDrawing.application(for: "Notes.app", mappings: []) == nil)
        #expect(WorkspaceDrawing.application(for: "/tmp/script.sh", mappings: []) == nil)
    }

    @Test @MainActor func savedSymbolsExposePreviewsAndExplicitRetraining() throws {
        let defaults = defaults()
        defer { clear(defaults) }
        defaults.set(try JSONEncoder().encode([WorkspaceSymbol(workspace: "1", strokes: vertical)]), forKey: "workspaceSymbols.v1")
        let drawing = WorkspaceDrawing(defaults: defaults)
        defer { drawing.stop() }
        let parent = NSMenu()
        drawing.install(in: parent)
        let menu = try #require(parent.items.first?.submenu)
        let entry = try #require(menu.items.first { $0.title == "Workspace 1" })
        #expect(entry.image != nil)
        let actions = try #require(entry.submenu)
        #expect(actions.items.count == 2)
        #expect(actions.items.allSatisfy { $0.action != nil && $0.target === drawing && $0.representedObject as? String == "1" })
    }

    @Test @MainActor func retrainingOnlyReplacesSavedSamplesAfterThreeConsistentExamples() throws {
        let defaults = defaults()
        defer { clear(defaults) }
        defaults.set(false, forKey: "showWorkspaceDrawingPreview")
        let original = try JSONEncoder().encode([WorkspaceSymbol(workspace: "1", strokes: vertical)])
        defaults.set(original, forKey: "workspaceSymbols.v1")
        let drawing = WorkspaceDrawing(defaults: defaults)
        defer { drawing.stop() }
        drawing.canTrain = { true }
        let parent = NSMenu()
        drawing.install(in: parent)
        let entry = try #require(parent.items.first?.submenu?.items.first { $0.title == "Workspace 1" })
        let retrain = try #require(entry.submenu?.items.first)
        let action: Selector? = retrain.action
        drawing.perform(try #require(action), with: retrain)
        draw(horizontal, with: drawing)
        let canvas: NSView = try state("canvas", in: drawing)
        let strokes = try #require(Mirror(reflecting: canvas).children.first { $0.label == "strokes" }?.value as? [[DrawingPoint]])
        #expect(strokes == horizontal)
        #expect(try state("previewTime", in: drawing) as Double == 0)
        #expect(defaults.data(forKey: "workspaceSymbols.v1") == original)
        draw(vertical, with: drawing) // An inconsistent example must not advance training.
        draw(horizontal, with: drawing)
        #expect(defaults.data(forKey: "workspaceSymbols.v1") == original)
        draw(horizontal, with: drawing)
        let saved = try JSONDecoder().decode([WorkspaceSymbol].self, from: #require(defaults.data(forKey: "workspaceSymbols.v1")))
        #expect(saved.count == 3)
        #expect(WorkspaceMatcher.match(horizontal, symbols: saved) == "1")
        #expect(WorkspaceMatcher.match(vertical, symbols: saved) == nil)
    }

    @Test @MainActor func cancellingRetrainingKeepsOriginalSymbols() throws {
        let defaults = defaults()
        defer { clear(defaults) }
        let original = try JSONEncoder().encode([WorkspaceSymbol(workspace: "1", strokes: vertical)])
        defaults.set(original, forKey: "workspaceSymbols.v1")
        let drawing = WorkspaceDrawing(defaults: defaults)
        defer { drawing.stop() }
        drawing.canTrain = { true }
        let parent = NSMenu()
        drawing.install(in: parent)
        let entry = try #require(parent.items.first?.submenu?.items.first { $0.title == "Workspace 1" })
        let retrain = try #require(entry.submenu?.items.first)
        let action: Selector? = retrain.action
        drawing.perform(try #require(action), with: retrain)
        draw(horizontal, with: drawing)
        drawing.stop()
        #expect(defaults.data(forKey: "workspaceSymbols.v1") == original)
        #expect(!drawing.needsPolling)
    }

    @Test @MainActor func unchangedAppMappingsKeepMenuAndChangesOrRemovalRefreshIt() throws {
        let defaults = defaults()
        defer { clear(defaults) }
        defaults.set(false, forKey: "showAppDrawingPreview")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        func config(_ app: String) throws -> Data {
            let entries: [[String: Any]] = [
                ["from": ["key_code": "caps_lock"], "to": [["set_variable": ["name": "hyper", "value": 1]]]],
                ["from": ["key_code": "o"], "conditions": [["type": "variable_if", "name": "hyper", "value": 1]], "to": [["set_variable": ["name": "apps", "value": 1]]]],
                ["from": ["key_code": "f"], "conditions": [["type": "variable_if", "name": "apps", "value": 1]], "to": [["shell_command": "open -a '\(app)'"]]]
            ]
            return try JSONSerialization.data(withJSONObject: ["profiles": [["selected": true, "complex_modifications": ["rules": [["manipulators": entries]]]]]])
        }
        try config("Firefox.app").write(to: url)
        let drawing = WorkspaceDrawing(apps: true, defaults: defaults, mappingsURL: url)
        defer { drawing.stop() }
        let parent = NSMenu()
        drawing.install(in: parent)
        let menu = try #require(parent.items.first?.submenu)
        let original = try #require(menu.items.first { $0.title == "F → Firefox.app" })
        _ = drawing.process([], allowed: true, modifiers: [.option])
        #expect(menu.items.contains { $0 === original })
        _ = drawing.process([], allowed: false, modifiers: [])
        try config("Notes.app").write(to: url)
        _ = drawing.process([], allowed: true, modifiers: [.option])
        #expect(menu.items.contains { $0.title == "F → Notes.app" })
        #expect(!menu.items.contains { $0 === original })
        _ = drawing.process([], allowed: false, modifiers: [])
        try FileManager.default.removeItem(at: url)
        _ = drawing.process([], allowed: true, modifiers: [.option])
        #expect(!menu.items.contains { $0.title.hasPrefix("F →") })
    }
}
