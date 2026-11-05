import Foundation
import Testing
@testable import OpenTile

struct BarStatusMetricsTests {
    @Test func pomodoroCyclesThroughFocusAndBreaks() {
        let t0 = Date(timeIntervalSince1970: 0)
        var timer = Pomodoro()
        #expect(timer.remaining(at: t0) == 25 * 60)
        timer.start(at: t0)
        #expect(timer.phase == .focus && timer.running)
        timer.pause(at: t0 + 600)
        #expect(!timer.running && timer.remaining(at: t0 + 9999) == 900)
        timer.start(at: t0 + 1000)
        #expect(timer.remaining(at: t0 + 1000) == 900)
        #expect(Pomodoro.clock(timer.remaining(at: t0 + 1000.5)) == "15:00")
        timer.finish(at: t0 + 1900)
        #expect(timer.phase == .shortBreak && timer.remaining(at: t0 + 1900) == 300)
        timer.finish(at: t0 + 2200)
        #expect(timer.phase == .idle && !timer.running)
        for _ in 0..<2 { timer.start(at: t0); timer.finish(at: t0); timer.finish(at: t0) }
        timer.start(at: t0)
        timer.finish(at: t0)
        #expect(timer.completedFocus == 4 && timer.phase == .longBreak)
        timer.reset()
        #expect(timer.phase == .idle && timer.completedFocus == 4)
        timer.focusLength = 50 * 60
        #expect(timer.remaining(at: t0) == 50 * 60)
    }

    @Test func batteryFillTracksChargeAndClampsInvalidValues() {
        #expect(BatteryIndicator.fraction(current: 71, maximum: 100) == 0.71)
        #expect(BatteryIndicator.fraction(current: 35, maximum: 50) == 0.7)
        #expect(BatteryIndicator.fraction(current: 110, maximum: 100) == 1)
        #expect(BatteryIndicator.fraction(current: -1, maximum: 100) == 0)
        #expect(BatteryIndicator.fraction(current: 50, maximum: 0) == 0)
    }

    @Test func networkRatesUseElapsedTimeAndBothDirections() {
        var traffic = NetworkTraffic()
        let first = traffic.sample(["en0": .init(received: 100, sent: 200)], at: 10)
        #expect(first.down == 0 && first.up == 0)
        let next = traffic.sample(["en0": .init(received: 4100, sent: 1200)], at: 12)
        #expect(next.down == 2000)
        #expect(next.up == 500)
    }

    @Test func networkInterfaceChangesAndResetsDoNotSpike() {
        var traffic = NetworkTraffic()
        _ = traffic.sample(["en0": .init(received: 10000, sent: 10000)], at: 1)
        let reset = traffic.sample(["en0": .init(received: 1, sent: 1), "en1": .init(received: 999999, sent: 999999)], at: 2)
        #expect(reset.down == 0 && reset.up == 0)
        let next = traffic.sample(["en1": .init(received: 1000099, sent: 1000199)], at: 3)
        #expect(next.down == 100 && next.up == 200)
        let disconnected = traffic.sample([:], at: 4)
        #expect(disconnected.down == 0 && disconnected.up == 0)
    }

    @Test func ratesHaveReadableUnits() {
        #expect(NetworkTraffic.format(0) == "0 B/s")
        #expect(NetworkTraffic.format(1500) == "1.5 KB/s")
        #expect(NetworkTraffic.format(2500000) == "2.5 MB/s")
        #expect(NetworkTraffic.format(.infinity) == "0 B/s")
    }
}
