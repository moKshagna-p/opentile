import Testing
@testable import OpenTileCore

struct CompanionRigTests {
    @Test func chainLagsAndSettles() {
        var rig = CompanionRig()
        rig.step(delta: 1.0 / 30, time: 1, drive: 0.3, intensity: 1)
        #expect(rig.hair.position > rig.tip.position)
        #expect(rig.tip.position > 0)
        #expect(rig.bow.position < 0)
        for i in 0..<600 {
            rig.step(delta: 1.0 / 30, time: Double(i) / 30, drive: 0, intensity: 1)
        }
        #expect(abs(rig.hair.position) < 0.0001)
        #expect(abs(rig.tip.position) < 0.0001)
        #expect(abs(rig.sash.position) < 0.0001)
    }

    @Test func blinkAndReset() {
        var rig = CompanionRig()
        rig.step(delta: 1.0 / 30, time: 0.11, drive: 100, intensity: 1.8)
        #expect(abs(rig.blink - 1) < 0.0001)
        #expect(abs(rig.hair.position) <= 0.45)
        rig.step(delta: 1.0 / 30, time: 0.22, drive: 1, intensity: 0)
        #expect(rig.blink == 0)
        #expect(rig.hair.position == 0)
        #expect(rig.bow.position == 0)
        rig.step(delta: 1.0 / 30, time: .nan, drive: .infinity, intensity: 1)
        #expect(rig.hair.position == 0)
        #expect(rig.blink == 0)
        #expect(rig.breath == 0)
    }
}
