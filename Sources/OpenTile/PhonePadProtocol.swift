import Foundation
import CryptoKit
import OpenTileCore

struct PhonePadPairing: Codable {
    let v: Int
    let endpoint: String
    let key: String

    static func endpoint(_ text: String) -> URL? {
        guard var parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["wss", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.fragment == nil, parts.query == nil else { return nil }
        parts.scheme = "wss"
        return parts.url
    }
}

struct PhonePadPacket: Codable {
    struct Touch: Codable {
        let id: Int
        let x: Double
        let y: Double
    }
    let v: Int
    let session: String
    let direction: String
    let seq: Int
    let type: String
    let time: Double
    var contacts: [Touch]?
    var resize: Bool?
    var message: String?
}

/// AES-GCM authenticates input end-to-end, including through a TLS-terminating tunnel.
/// Fresh session challenges and increasing counters reject replay and reflected responses.
struct PhonePadProtocol {
    enum Failure: Error { case invalid, stale }
    let key: SymmetricKey
    let session: String
    private(set) var authenticated = false
    private var received = -1
    private var sent = 0
    private var clockOffset = 0.0
    private var lastTime = -Double.infinity

    init(key: SymmetricKey, session: String = UUID().uuidString) {
        self.key = key
        self.session = session
    }

    mutating func open(_ data: Data, now: Double) throws -> PhonePadPacket {
        guard (28...16_384).contains(data.count) else { throw Failure.invalid }
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
        let packet = try JSONDecoder().decode(PhonePadPacket.self, from: plain)
        guard packet.v == 1, packet.session == session, packet.direction == "phone",
              packet.seq >= 0, packet.seq <= 9_007_199_254_740_991, packet.seq > received,
              packet.time.isFinite, packet.time >= lastTime else { throw Failure.invalid }
        if !authenticated {
            guard packet.type == "hello", packet.seq == 0 else { throw Failure.invalid }
            clockOffset = now - packet.time
        } else {
            guard ["frame", "cancel", "ping"].contains(packet.type) else { throw Failure.invalid }
        }
        if packet.type == "frame" {
            guard let contacts = packet.contacts, contacts.count <= 2,
                  contacts.allSatisfy({ $0.id >= 0 && $0.id <= 1_000_000 && $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }),
                  Set(contacts.map(\.id)).count == contacts.count else { throw Failure.invalid }
        }
        // Consume valid counters even when input is stale, so it cannot be
        // replayed later. A delayed release must never commit a timed-out preview.
        let stale = authenticated && abs(now - packet.time - clockOffset) >= 0.4
        received = packet.seq
        lastTime = packet.time
        if stale { throw Failure.stale }
        authenticated = true
        return packet
    }

    mutating func seal(type: String, message: String? = nil, now: Double) throws -> Data {
        defer { sent += 1 }
        let packet = PhonePadPacket(v: 1, session: session, direction: "mac", seq: sent, type: type, time: now, message: message)
        return try AES.GCM.seal(JSONEncoder().encode(packet), using: key).combined!
    }
}
