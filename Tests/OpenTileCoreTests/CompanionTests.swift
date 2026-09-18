import Testing
@testable import OpenTileCore

struct CompanionTests {
    @Test func commands() {
        #expect(CompanionCommand(" Open Safari ") == .openApp("Safari"))
        #expect(CompanionCommand("launch \"Visual Studio Code\"") == .openApp("Visual Studio Code"))
        #expect(CompanionCommand("start Notes.app") == .openApp("Notes.app"))
        #expect(CompanionCommand("help") == .help)
        for text in ["", "open", "open  ", "open /Applications", "open Safari; say hello", "open $(whoami)", "open Safari\nNotes", "delete Notes", "open https://example.com"] {
            #expect(CompanionCommand(text) == nil)
        }
    }
    @Test func springSettlesAndRemainsBounded() {
        var spring = CompanionSpring()
        spring.impulse(1000)
        for _ in 0..<600 {
            spring.step(delta: 1.0 / 60, target: 0)
            #expect(abs(spring.position) <= 0.45)
        }
        #expect(abs(spring.position) < 0.0001)
        #expect(abs(spring.velocity) < 0.0001)
        spring.impulse(.infinity)
        spring.step(delta: .nan, target: 0)
        #expect(spring.position.isFinite)
        spring.step(delta: 100, target: 100)
        #expect(abs(spring.position) <= 0.45)
        spring.reset()
        #expect(spring.position == 0 && spring.velocity == 0)
    }
}
