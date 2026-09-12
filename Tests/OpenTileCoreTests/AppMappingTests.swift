import Foundation
import Testing
@testable import OpenTileCore

struct AppMappingTests {
    private func config(_ entries: [[String: Any]], selected: Bool = true, caps: Bool = true, layer: Bool = true) -> Data {
        var manipulators: [[String: Any]] = []
        if caps { manipulators.append(["from": ["key_code": "caps_lock"], "to": [["set_variable": ["name": "hyper", "value": 1]]]]) }
        if layer { manipulators.append(["from": ["key_code": "o"], "conditions": [["type": "variable_if", "name": "hyper", "value": 1]], "to": [["set_variable": ["name": "apps", "value": 1]]]]) }
        manipulators += entries
        let profile: [String: Any] = ["selected": selected, "complex_modifications": ["rules": [["manipulators": manipulators]]]]
        return try! JSONSerialization.data(withJSONObject: ["profiles": [profile]])
    }
    private func entry(_ key: String = "f", _ command: String = "open -a 'Firefox.app'", layer: String = "apps") -> [String: Any] {
        ["from": ["key_code": key], "conditions": [["type": "variable_if", "name": layer, "value": 1]], "to": [["shell_command": command]]]
    }
    @Test
    func testReadsOnlyAppLayer() {
        let mappings = AppMapping.read(config([entry(), entry("b", "open -a 'Notes.app'"), entry("x", "open -a 'Other.app'", layer: "web")]))
        #expect((mappings.map(\.key)) == (["b", "f"]))
        #expect((mappings.map(\.application)) == (["Notes.app", "Firefox.app"]))
    }
    @Test
    func testSingleProfileWithoutSelectionFlag() throws {
        var root = try JSONSerialization.jsonObject(with: config([entry()])) as! [String: Any]
        var profiles = root["profiles"] as! [[String: Any]]
        profiles[0].removeValue(forKey: "selected")
        root["profiles"] = profiles
        #expect((AppMapping.read(try JSONSerialization.data(withJSONObject: root)).first?.key) == ("f"))
        root["profiles"] = profiles + profiles
        #expect(AppMapping.read(try JSONSerialization.data(withJSONObject: root)).isEmpty)
    }
    @Test
    func testRequiresActiveCapsOLayer() {
        #expect(AppMapping.read(config([entry()], selected: false)).isEmpty)
        #expect(AppMapping.read(config([entry()], caps: false)).isEmpty)
        #expect(AppMapping.read(config([entry()], layer: false)).isEmpty)
        #expect(AppMapping.read(Data("invalid".utf8)).isEmpty)
    }
    @Test
    func testRejectsNonAppCommandsAndAmbiguousShortcuts() {
        for command in ["open https://example.com", "open -a 'Firefox.app'; echo bad", "open -a \"$(echo bad)\"", "open -a Firefox.app && open -a Notes.app"] {
            #expect(AppMapping.read(config([entry("f", command)])).isEmpty)
        }
        #expect(AppMapping.read(config([entry(), entry("f", "open -a 'Notes.app'")])).isEmpty)
        var contextual = entry()
        contextual["conditions"] = [["type": "variable_if", "name": "apps", "value": 1], ["type": "frontmost_application_if", "bundle_identifiers": ["test"]]]
        #expect(AppMapping.read(config([contextual])).isEmpty)
    }
    @Test
    func testAcceptsQuotedAppNamesWithSpaces() {
        #expect((AppMapping.read(config([entry("c", "open -a 'Visual Studio Code.app'")])).first?.application) == ("Visual Studio Code.app"))
    }
    @Test
    func testSecondFingerHandsOffUntilOptionReleased() {
        var gate = AppDrawingGate()
        #expect(gate.ownsDrawing(optionOnly: true, contactCounts: []) == true)
        #expect(gate.ownsDrawing(optionOnly: true, contactCounts: [1, 0, 1]) == true)
        #expect(gate.ownsDrawing(optionOnly: true, contactCounts: [1, 2]) == false)
        #expect(gate.ownsDrawing(optionOnly: true, contactCounts: [1, 0]) == false)
        #expect(gate.ownsDrawing(optionOnly: false, contactCounts: []) == false)
        #expect(gate.ownsDrawing(optionOnly: true, contactCounts: [1]) == true)
    }
    @Test
    func testStaggeredPlacementCanResizeAfterDrawingCancellation() {
        var gate = AppDrawingGate()
        var recognizer = GestureRecognizer()
        #expect(gate.ownsDrawing(optionOnly: true, contactCounts: [1]) == true)
        _ = recognizer.cancel()
        #expect(gate.ownsDrawing(optionOnly: true, contactCounts: [2]) == false)
        // The app resets the cancelled recognizer when handing frames back.
        recognizer = GestureRecognizer()
        #expect(recognizer.update([.init(id: 1, x: 0.3, y: 0.5), .init(id: 2, x: 0.7, y: 0.5)], time: 0, optionHeld: true) == nil)
        guard case .resizeBegan = recognizer.update([.init(id: 1, x: 0.4, y: 0.5), .init(id: 2, x: 0.6, y: 0.5)], time: 0.1, optionHeld: true) else { Issue.record("Resize must start"); return }
    }
}
