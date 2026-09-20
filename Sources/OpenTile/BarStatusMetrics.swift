import AppKit
import Darwin

struct NetworkTraffic {
    struct Counters {
        let received: UInt64
        let sent: UInt64
    }
    private var previous: (time: TimeInterval, interfaces: [String: Counters])?

    mutating func sample(_ interfaces: [String: Counters], at time: TimeInterval) -> (down: Double, up: Double) {
        defer { previous = (time, interfaces) }
        guard let previous, time > previous.time else { return (0, 0) }
        var received: UInt64 = 0
        var sent: UInt64 = 0
        for (name, current) in interfaces {
            guard let old = previous.interfaces[name] else { continue }
            // Interface changes and counter resets must not produce rate spikes.
            if current.received >= old.received { received += current.received - old.received }
            if current.sent >= old.sent { sent += current.sent - old.sent }
        }
        return (Double(received) / (time - previous.time), Double(sent) / (time - previous.time))
    }

    static func readInterfaces() -> [String: Counters] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [:] }
        defer { freeifaddrs(head) }
        var result: [String: Counters] = [:]
        var cursor = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let interface = entry.pointee
            guard interface.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  interface.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let data = interface.ifa_data else { continue }
            let name = String(cString: interface.ifa_name)
            // Count physical Wi-Fi/Ethernet links, excluding VPN and peer-to-peer
            // interfaces so the same traffic is not counted twice.
            guard name.hasPrefix("en") else { continue }
            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            result[name] = Counters(received: UInt64(counters.ifi_ibytes), sent: UInt64(counters.ifi_obytes))
        }
        return result
    }

    static func format(_ bytesPerSecond: Double) -> String {
        let value = max(0, bytesPerSecond.isFinite ? bytesPerSecond : 0)
        if value >= 1_000_000_000 { return String(format: "%.1f GB/s", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1f MB/s", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1f KB/s", value / 1_000) }
        return "\(Int(value)) B/s"
    }
}

struct BatteryIndicator {
    static func fraction(current: Int, maximum: Int) -> Double {
        guard maximum > 0 else { return 0 }
        return min(1, max(0, Double(current) / Double(maximum)))
    }

    @MainActor static func image(fraction: Double) -> NSImage {
        let fill = min(1, max(0, fraction))
        let image = NSImage(size: NSSize(width: 25, height: 12), flipped: false) { _ in
            NSColor.white.setStroke()
            let outline = NSBezierPath(roundedRect: NSRect(x: 0.5, y: 0.5, width: 21, height: 11), xRadius: 2, yRadius: 2)
            outline.lineWidth = 1
            outline.stroke()
            NSColor.white.setFill()
            NSBezierPath(roundedRect: NSRect(x: 23, y: 4, width: 2, height: 4), xRadius: 1, yRadius: 1).fill()
            if fill > 0 {
                NSBezierPath(roundedRect: NSRect(x: 2.5, y: 2.5, width: 17 * fill, height: 7), xRadius: min(1, 8.5 * fill), yRadius: 1).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
