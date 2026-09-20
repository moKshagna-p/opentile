import Testing
@testable import OpenTile

struct BarStatusMetricsTests {
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
