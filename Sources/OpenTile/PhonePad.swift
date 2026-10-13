import AppKit
import ApplicationServices
import CoreImage.CIFilterBuiltins
import CryptoKit
import Network
import OpenTileCore

/// All transport, recognizer, and UI state is confined to the main queue.
/// The listener is loopback-only; a user-selected HTTPS tunnel provides reachability.
final class PhonePad: NSObject {
    var onEvent: ((PhonePadEvent) -> Void)?
    var onDisconnect: (() -> Void)?
    var onStatus: ((String) -> Void)?
    var onPairing: ((PhonePadPairing) -> Void)?
    private(set) var isConnected = false
    private(set) var hasTouches = false
    var listeningPort: UInt16? { listener?.port?.rawValue }
    private let isTrusted: () -> Bool
    private var listener: NWListener?
    private var connection: NWConnection?
    private var codec: PhonePadProtocol?
    private var input = PhonePadInput()
    private var inputStalled = false
    private var timer: Timer?
    private var lastPacket = 0.0
    private var lastTouchFrame = 0.0
    private var acceptedAt = 0.0
    private var pendingWrites = 0
    private var key: SymmetricKey?
    private var epoch = UUID()
    private var panel: NSPanel?
    private var stopItem: NSMenuItem?

    init(isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.isTrusted = isTrusted
        super.init()
    }

    func install(in menu: NSMenu) {
        let pair = menu.addItem(withTitle: "Pair Phone Pad…", action: #selector(pairPhone), keyEquivalent: "")
        pair.target = self
        stopItem = menu.addItem(withTitle: "Stop Phone Pad", action: #selector(stop), keyEquivalent: "")
        stopItem?.target = self
        stopItem?.isEnabled = false
    }

    @objc private func pairPhone() {
        guard isTrusted() else {
            onStatus?("Allow Accessibility in Permission Setup before pairing a phone")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Pair your phone"
        alert.informativeText = "Start a tunnel to http://127.0.0.1:8765, then paste its HTTPS address. For example: ngrok http http://127.0.0.1:8765. OpenTile will show a pairing QR for the Phone Pad app."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 26))
        field.placeholderString = "https://your-tunnel.ngrok-free.app"
        field.stringValue = UserDefaults.standard.string(forKey: "phonePadEndpoint") ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Create Pairing QR")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let endpoint = PhonePadPairing.endpoint(field.stringValue) else {
            onStatus?("Enter an HTTPS or WSS tunnel address without credentials, query, or fragment")
            return
        }
        UserDefaults.standard.set(endpoint.absoluteString, forKey: "phonePadEndpoint")
        do { try start(endpoint: endpoint) }
        catch { onStatus?("Phone Pad could not start: \(error.localizedDescription)") }
    }

    func start(endpoint: URL, port: UInt16 = 8765) throws {
        stop()
        let token = UUID()
        epoch = token
        let newKey = SymmetricKey(size: .bits256)
        key = newKey
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.maximumMessageSize = 24_576
        options.setClientRequestHandler(.main) { _, _ in
            NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, self.epoch == token else { connection.cancel(); return }
            self.accept(connection, key: newKey)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, self.epoch == token else { return }
            switch state {
            case .ready:
                self.stopItem?.isEnabled = true
                let pairing = PhonePadPairing(v: 1, endpoint: endpoint.absoluteString, key: newKey.withUnsafeBytes { Data($0).base64EncodedString() })
                if let onPairing = self.onPairing { onPairing(pairing) }
                else { self.showPairing(pairing) }
                self.onStatus?("Phone Pad ready to pair")
            case .failed(let error): self.stop(); self.onStatus?("Phone Pad: \(error.localizedDescription)")
            default: break
            }
        }
        listener.start(queue: .main)
    }

    private func accept(_ connection: NWConnection, key: SymmetricKey) {
        guard self.connection == nil else { connection.cancel(); return }
        self.connection = connection
        pendingWrites = 0
        codec = PhonePadProtocol(key: key)
        input = PhonePadInput()
        inputStalled = false
        acceptedAt = ProcessInfo.processInfo.systemUptime
        lastPacket = acceptedAt
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self, weak connection] _ in
            guard let self, let connection, self.connection === connection else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if (!self.isConnected && now - self.acceptedAt > 5) ||
                (self.isConnected && now - self.lastPacket > 10) || !self.isTrusted() {
                self.disconnect(connection)
            } else if self.hasTouches && now - self.lastTouchFrame > 0.4 {
                self.cancelStalledInput()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.connection === connection else { return }
            switch state {
            case .ready:
                let challenge = ["v": "1", "session": self.codec!.session]
                self.sendRaw(try! JSONEncoder().encode(challenge), to: connection)
                self.receive(connection)
            case .failed, .cancelled: self.disconnect(connection)
            default: break
            }
        }
        connection.start(queue: .main)
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, context, _, error in
            guard let self, let connection, self.connection === connection else { return }
            guard error == nil, let data, data.count <= 24_576,
                  let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
                  metadata.opcode == .text, let encrypted = Data(base64Encoded: data) else {
                self.disconnect(connection); return
            }
            guard self.isTrusted() else { self.disconnect(connection); return }
            do {
                let packet = try self.codec!.open(encrypted, now: ProcessInfo.processInfo.systemUptime)
                self.lastPacket = ProcessInfo.processInfo.systemUptime
                switch packet.type {
                case "hello":
                    self.isConnected = true
                    self.panel?.orderOut(nil)
                    self.feedback("Connected", type: "ready")
                    self.onStatus?("Phone Pad connected · Escape cancels · Stop Phone Pad disconnects")
                case "frame":
                    let contacts = packet.contacts!.map { Contact(id: $0.id, x: $0.x, y: $0.y) }
                    self.hasTouches = !contacts.isEmpty
                    self.lastTouchFrame = self.lastPacket
                    for event in self.input.update(contacts, time: packet.time, resize: packet.resize ?? false) {
                        self.onEvent?(event)
                    }
                    if contacts.isEmpty { self.inputStalled = false }
                case "cancel":
                    self.input.cancel()
                    self.onEvent?(.gesture(.cancelled))
                case "ping": self.feedback("Connected", type: "pong")
                default: break
                }
                self.receive(connection)
            } catch PhonePadProtocol.Failure.stale {
                self.cancelStalledInput()
                self.receive(connection)
            } catch { self.disconnect(connection) }
        }
    }

    private func cancelStalledInput() {
        hasTouches = false
        input.cancel()
        guard !inputStalled else { return }
        inputStalled = true
        feedback("Input delayed — lift all fingers to continue", type: "cancelled")
        onEvent?(.gesture(.cancelled))
    }

    func cancelInput() {
        input.cancel()
        feedback("Cancelled — lift all fingers", type: "cancelled")
    }

    func feedback(_ message: String, type: String = "status") {
        guard isConnected, let connection, let data = try? codec?.seal(type: type, message: message, now: ProcessInfo.processInfo.systemUptime) else { return }
        sendRaw(Data(data.base64EncodedString().utf8), to: connection)
    }

    private func sendRaw(_ data: Data, to connection: NWConnection) {
        guard self.connection === connection, pendingWrites < 8 else {
            disconnect(connection)
            return
        }
        pendingWrites += 1
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "phone-pad", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection, self.connection === connection else { return }
            self.pendingWrites -= 1
            if error != nil { self.disconnect(connection) }
        })
    }

    private func disconnect(_ connection: NWConnection) {
        guard self.connection === connection else { return }
        let wasConnected = isConnected
        self.connection = nil
        isConnected = false
        hasTouches = false
        codec = nil
        pendingWrites = 0
        input.cancel()
        timer?.invalidate()
        timer = nil
        connection.cancel()
        if wasConnected {
            onDisconnect?()
            onStatus?("Phone Pad disconnected — layout preview cancelled")
        }
    }

    @objc func stop() {
        epoch = UUID()
        listener?.cancel()
        listener = nil
        if let connection { disconnect(connection) }
        key = nil
        panel?.orderOut(nil)
        panel = nil
        stopItem?.isEnabled = false
    }

    private func showPairing(_ pairing: PhonePadPairing) {
        guard let data = try? JSONEncoder().encode(pairing) else { return }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"
        guard let code = filter.outputImage,
              let image = CIContext().createCGImage(code.transformed(by: CGAffineTransform(scaleX: 8, y: 8)), from: code.extent.applying(CGAffineTransform(scaleX: 8, y: 8))) else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 490), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "OpenTile Phone Pad"
        panel.isReleasedWhenClosed = false
        let title = NSTextField(labelWithString: "Scan with Phone Pad")
        title.font = .systemFont(ofSize: 23, weight: .semibold)
        let qr = NSImageView()
        qr.image = NSImage(cgImage: image, size: NSSize(width: 290, height: 290))
        qr.imageScaling = .scaleProportionallyUpOrDown
        let hint = NSTextField(wrappingLabelWithString: "This QR gives control of your Mac. Keep it private. Stop Phone Pad revokes this pairing. Closing this window keeps pairing available.")
        hint.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, qr, hint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 28),
            qr.widthAnchor.constraint(equalToConstant: 290), qr.heightAnchor.constraint(equalToConstant: 290)
        ])
        self.panel = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }
}
