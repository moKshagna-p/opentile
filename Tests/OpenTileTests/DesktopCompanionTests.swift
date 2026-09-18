import AppKit
import SceneKit
import Testing
@testable import OpenTile

struct DesktopCompanionTests {
    @Test @MainActor func bundledModelLoadsAndMotionResets() {
        let character = CompanionCharacter()
        #expect(character.loadError == nil)
        var geometryCount = 0
        character.body.enumerateChildNodes { node, _ in
            if node.geometry != nil { geometryCount += 1 }
        }
        #expect(geometryCount == 6)
        #expect(character.neck.parent === character.waist)
        let (minimum, maximum) = character.body.boundingBox
        #expect(maximum.y - minimum.y > 2.8)
        #expect(maximum.y - minimum.y < 3.4)
        character.pose(time: 2, spring: 100, intensity: 1.8, animated: true)
        #expect(abs(character.body.eulerAngles.z) <= 0.061)
        #expect(character.rig.hair.position > 0)
        #expect(character.rig.tip.position < character.rig.hair.position)
        character.pose(time: 2, spring: 1, intensity: 1.8, animated: false)
        #expect(character.rig.hair.position == 0)
        #expect(character.rig.blink == 0)
        #expect(character.body.position.y == 0)
        #expect(character.body.eulerAngles.y == 0)
        #expect(character.body.eulerAngles.z == 0)
        character.pose(time: .nan, spring: .infinity, intensity: 1, animated: true)
        #expect(character.body.eulerAngles.z == 0)
    }

    @Test @MainActor func articulatedJointsMoveAndReturnToRest() {
        let character = CompanionCharacter()
        character.greet()
        for frame in 0..<30 {
            character.pose(time: Double(frame) / 30, spring: 0.1, intensity: 1, animated: true, attention: 1)
        }
        #expect(abs(character.neck.eulerAngles.z) > 0.01)
        #expect(character.waist.position.y > -0.55)
        #expect(character.body.eulerAngles.z == 0)
        character.pose(time: 1, spring: 0, intensity: 1, animated: false)
        #expect(character.neck.eulerAngles.z == 0)
        #expect(character.waist.eulerAngles.z == 0)
        #expect(abs(character.waist.position.y + 0.55) < 0.0001)
        #expect(character.waist.scale.y == 1)
    }

    @Test @MainActor func missingModelReportsFailure() {
        let character = CompanionCharacter(modelURL: URL(fileURLWithPath: "/nonexistent-companion.usdz"))
        #expect(character.loadError != nil)
        #expect(character.body.childNodes.isEmpty)
    }

    @Test @MainActor func menuShowsAndHidesCompanion() {
        _ = NSApplication.shared
        let companion = DesktopCompanion()
        defer { companion.stop() }
        let menu = NSMenu()
        companion.install(in: menu)
        let submenu = menu.items.first?.submenu
        #expect(submenu?.title == "2D Companion")
        guard let toggle = submenu?.items.first, let action = toggle.action else {
            Issue.record("Missing companion toggle")
            return
        }
        NSApp.sendAction(action, to: toggle.target, from: toggle)
        #expect(toggle.title == "Hide Companion")
        let panel = NSApp.windows.first { $0.contentView is SCNView }
        #expect(panel?.isVisible == true)
        #expect((panel?.contentView as? SCNView)?.scene != nil)
        NSApp.sendAction(action, to: toggle.target, from: toggle)
        #expect(toggle.title == "Show Companion")
        #expect(panel?.isVisible == false)
    }
}
