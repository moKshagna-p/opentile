import Foundation
import Testing
import CryptoKit
@testable import OpenTile

struct PhonePadProtocolTests {
    let key = SymmetricKey(size: .bits256)
    func encrypted(_ packet: PhonePadPacket, key: SymmetricKey? = nil) throws -> Data {
        try AES.GCM.seal(JSONEncoder().encode(packet), using: key ?? self.key).combined!
    }
    func packet(type: String = "hello", seq: Int = 0, time: Double = 10, session: String = "session", direction: String = "phone", contacts: [PhonePadPacket.Touch]? = nil) -> PhonePadPacket {
        PhonePadPacket(v: 1, session: session, direction: direction, seq: seq, type: type, time: time, contacts: contacts)
    }
    @Test func authenticatesAndRejectsReplayWrongKeySessionAndReflection() throws {
        var codec = PhonePadProtocol(key: key, session: "session")
        #expect(throws: (any Error).self) { try codec.open(encrypted(packet(), key: SymmetricKey(size: .bits256)), now: 100) }
        #expect(throws: (any Error).self) { try codec.open(encrypted(packet(session: "old")), now: 100) }
        #expect(throws: (any Error).self) { try codec.open(encrypted(packet(direction: "mac")), now: 100) }
        #expect(!codec.authenticated)
        _ = try codec.open(encrypted(packet()), now: 100)
        #expect(codec.authenticated)
        #expect(throws: (any Error).self) { try codec.open(encrypted(packet()), now: 100) }
        let frame = packet(type: "frame", seq: 1, time: 10.1, contacts: [])
        _ = try codec.open(encrypted(frame), now: 100.1)
        #expect(throws: (any Error).self) { try codec.open(encrypted(frame), now: 100.1) }
        #expect(throws: (any Error).self) { try codec.open(codec.seal(type: "status", now: 100.1), now: 100.1) }
    }
    @Test func rejectsStaleReleaseInvalidTouchAndTampering() throws {
        var codec = PhonePadProtocol(key: key, session: "session")
        _ = try codec.open(encrypted(packet()), now: 100)
        #expect(throws: (any Error).self) { try codec.open(encrypted(packet(type: "frame", seq: 1, time: 10.1, contacts: [])), now: 101) }
        let invalid = [PhonePadPacket.Touch(id: 1, x: 2, y: 0.5)]
        #expect(throws: (any Error).self) { try codec.open(encrypted(packet(type: "frame", seq: 1, time: 10.1, contacts: invalid)), now: 100.1) }
        let duplicate = Array(repeating: PhonePadPacket.Touch(id: 1, x: 0.5, y: 0.5), count: 2)
        #expect(throws: (any Error).self) { try codec.open(encrypted(packet(type: "frame", seq: 1, time: 10.1, contacts: duplicate)), now: 100.1) }
        var damaged = try encrypted(packet(type: "ping", seq: 1, time: 10.1))
        damaged[15] ^= 1
        #expect(throws: (any Error).self) { try codec.open(damaged, now: 100.1) }
        #expect(throws: (any Error).self) { try codec.open(Data(repeating: 0, count: 16_385), now: 100.1) }
    }
    @Test func staleAuthenticatedInputConsumesSequenceAndFreshInputCanResume() throws {
        var codec = PhonePadProtocol(key: key, session: "session")
        _ = try codec.open(encrypted(packet()), now: 100)
        let stale = try encrypted(packet(type: "frame", seq: 1, time: 10.1, contacts: []))
        #expect(throws: PhonePadProtocol.Failure.stale) { try codec.open(stale, now: 101) }
        // Retrying the consumed counter is replay even if its time now looks fresh.
        #expect(throws: PhonePadProtocol.Failure.invalid) { try codec.open(stale, now: 100.1) }
        let fresh = try codec.open(encrypted(packet(type: "frame", seq: 2, time: 11.1, contacts: [])), now: 101.1)
        #expect(fresh.seq == 2 && codec.authenticated)
        let malformed = try encrypted(packet(type: "frame", seq: 3, time: 11.2,
                                            contacts: [.init(id: 1, x: 2, y: 0)]))
        #expect(throws: PhonePadProtocol.Failure.invalid) { try codec.open(malformed, now: 102) }
    }

    @Test func authenticatedFeedbackHasIncreasingSequence() throws {
        var codec = PhonePadProtocol(key: key, session: "session")
        for sequence in 0..<3 {
            let sealed = try codec.seal(type: "armed", message: "Lift to apply", now: 100)
            let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key)
            let packet = try JSONDecoder().decode(PhonePadPacket.self, from: plain)
            #expect(packet.direction == "mac")
            #expect(packet.seq == sequence)
            #expect(packet.session == "session")
        }
    }
    @Test func pairingOnlyAcceptsSecureCredentialFreeEndpoints() {
        #expect(PhonePadPairing.endpoint(" https://pad.example.com ")?.absoluteString == "wss://pad.example.com")
        for endpoint in ["ws://pad.example.com", "http://pad.example.com", "https://user:password@pad.example.com", "https://pad.example.com#key", "https://pad.example.com?key=secret", "bad"] {
            #expect(PhonePadPairing.endpoint(endpoint) == nil)
        }
    }
}
