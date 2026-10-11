import Testing
import Foundation
import CryptoKit
import Network
import OpenTileCore
@testable import OpenTile

@MainActor
private final class PhonePadClient {
    var pairing: PhonePadPairing?
    var messages: [Data] = []
    var connection: NWConnection?
    var session = ""
    var sequence = 0
    var state = "setup"

    func connect(port: UInt16) {
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        let connection = NWConnection(to: .url(URL(string: "ws://127.0.0.1:\(port)/")!), using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { state in
            MainActor.assumeIsolated {
                self.state = String(describing: state)
                if case .ready = state { self.receive() }
            }
        }
        connection.start(queue: .main)
    }

    private func receive() {
        connection?.receiveMessage { data, _, _, error in
            MainActor.assumeIsolated {
                if let data { self.messages.append(data) }
                if error == nil { self.receive() }
            }
        }
    }

    func send(_ type: String, contacts: [PhonePadPacket.Touch]? = nil, key: SymmetricKey? = nil) throws {
        let pairing = try #require(pairing)
        let packet = PhonePadPacket(v: 1, session: session, direction: "phone", seq: sequence, type: type,
                                    time: ProcessInfo.processInfo.systemUptime, contacts: contacts)
        sequence += 1
        let sealed = try AES.GCM.seal(JSONEncoder().encode(packet), using: key ?? SymmetricKey(data: Data(base64Encoded: pairing.key)!))
        let context = NWConnection.ContentContext(identifier: "test", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection?.send(content: Data(sealed.combined!.base64EncodedString().utf8), contentContext: context,
                         isComplete: true, completion: .contentProcessed { _ in })
    }

    func close() { connection?.cancel(); connection = nil }
}

@MainActor
struct PhonePadTransportTests {
    private func waitFor(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func pair(_ pad: PhonePad, _ client: PhonePadClient) async throws {
        pad.onPairing = { client.pairing = $0 }
        try pad.start(endpoint: URL(string: "wss://example.com")!, port: 0)
        #expect(await waitFor { client.pairing != nil })
        client.connect(port: try #require(pad.listeningPort))
        #expect(await waitFor { !client.messages.isEmpty }, "Client state: \(client.state)")
        let challenge = try JSONDecoder().decode([String: String].self, from: #require(client.messages.first))
        client.session = try #require(challenge["session"])
        try client.send("hello")
        #expect(await waitFor { pad.isConnected && client.messages.count == 2 })
    }

    @Test func encryptedWebSocketTapAndStopRevokesConnection() async throws {
        let pad = PhonePad(isTrusted: { true })
        let client = PhonePadClient()
        defer { pad.stop(); client.close() }
        var events: [PhonePadEvent] = []
        var disconnects = 0
        pad.onEvent = { events.append($0) }
        pad.onDisconnect = { disconnects += 1 }
        try await pair(pad, client)
        let pairing = try #require(client.pairing)
        let encrypted = try #require(Data(base64Encoded: client.messages[1]))
        let ready = try JSONDecoder().decode(PhonePadPacket.self, from: AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: SymmetricKey(data: Data(base64Encoded: pairing.key)!)))
        #expect(ready.type == "ready" && ready.direction == "mac")
        try client.send("frame", contacts: [.init(id: 1, x: 0.5, y: 0.5)])
        #expect(await waitFor { pad.hasTouches })
        try client.send("frame", contacts: [])
        #expect(await waitFor { events == [.click] })
        pad.stop()
        #expect(!pad.isConnected && !pad.hasTouches && pad.listeningPort == nil)
        #expect(disconnects == 1)
    }

    @Test func lostTouchFramesCancelBeforeDelayedRelease() async throws {
        let pad = PhonePad(isTrusted: { true })
        let client = PhonePadClient()
        defer { pad.stop(); client.close() }
        var events: [PhonePadEvent] = []
        var disconnected = false
        pad.onEvent = { events.append($0) }
        pad.onDisconnect = { disconnected = true }
        try await pair(pad, client)
        try client.send("frame", contacts: [.init(id: 1, x: 0.5, y: 0.5)])
        #expect(await waitFor { pad.hasTouches })
        #expect(await waitFor { disconnected })
        #expect(!pad.isConnected && !pad.hasTouches && events.isEmpty)
        try client.send("frame", contacts: [])
        try await Task.sleep(for: .milliseconds(30))
        #expect(events.isEmpty)
    }

    @Test func permissionRevocationDisconnectsIdlePhone() async throws {
        var trusted = true
        let pad = PhonePad(isTrusted: { trusted })
        let client = PhonePadClient()
        defer { pad.stop(); client.close() }
        try await pair(pad, client)
        trusted = false
        #expect(await waitFor { !pad.isConnected })
    }

    @Test func interruptedActivePinchDisconnectsWithoutRelease() async throws {
        let pad = PhonePad(isTrusted: { true })
        let client = PhonePadClient()
        defer { pad.stop(); client.close() }
        var events: [PhonePadEvent] = []
        var disconnected = false
        pad.onEvent = { events.append($0) }
        pad.onDisconnect = { disconnected = true }
        try await pair(pad, client)
        try client.send("frame", contacts: [.init(id: 1, x: 0.35, y: 0.5), .init(id: 2, x: 0.65, y: 0.5)])
        #expect(await waitFor { pad.hasTouches })
        for _ in 0..<6 {
            try client.send("frame", contacts: [.init(id: 1, x: 0.4, y: 0.5), .init(id: 2, x: 0.6, y: 0.5)])
            try await Task.sleep(for: .milliseconds(40))
        }
        #expect(events.contains(.gesture(.began(CGPoint(x: 0.5, y: 0.5)))))
        #expect(await waitFor { disconnected })
        try client.send("frame", contacts: [])
        try await Task.sleep(for: .milliseconds(30))
        #expect(!events.contains(.gesture(.released)))
    }
}
