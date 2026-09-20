import AppKit

struct CodexBarSnapshot: Decodable {
    struct Host: Decodable { let usageBarsShowUsed: Bool? }
    struct Window: Decodable {
        let label: String
        let usedPercent: Double?
        let remainingPercent: Double?
        let resetAt: String?
        func percent(showUsed: Bool) -> Double? {
            let value = showUsed ? (usedPercent ?? remainingPercent.map { 100 - $0 })
                                 : (remainingPercent ?? usedPercent.map { 100 - $0 })
            return value.flatMap { $0.isFinite ? min(100, max(0, $0)) : nil }
        }
    }
    struct Provider: Decodable {
        let id: String
        let name: String
        let enabled: Bool
        let windows: [Window]?
    }
    let schemaVersion: Int
    let host: Host
    let providers: [Provider]
    var visibleProviders: [Provider] { providers.filter(\.enabled) }
    var navbarProviders: [Provider] { visibleProviders.filter { $0.id != "claude" } }
    var showUsed: Bool { host.usageBarsShowUsed ?? false }
    static func decode(_ data: Data) throws -> Self {
        let snapshot = try JSONDecoder().decode(Self.self, from: data)
        guard snapshot.schemaVersion == 1 else { throw CocoaError(.coderReadCorrupt) }
        return snapshot
    }
}

/// Runs CodexBar's supported adapter off the UI thread; one request at a time.
@MainActor final class CodexBarStatus {
    private(set) var snapshot: CodexBarSnapshot?
    private(set) var message = "Connecting to CodexBar…"
    private(set) var updatedAt: Date?
    var onChange: (() -> Void)?
    private var timer: Timer?
    private var process: Process?
    private var generation = 0
    private var running = false

    func start() {
        guard !running else { return }
        running = true
        refresh()
        let timer = Timer(timeInterval: 180, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 15
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        running = false
        generation += 1
        timer?.invalidate(); timer = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
    }

    func refresh() {
        guard running, process == nil else { return }
        let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.steipete.codexbar")
            ?? URL(fileURLWithPath: "/Applications/CodexBar.app")
        let executable = app.appendingPathComponent("Contents/Helpers/CodexBarCLI")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            message = "Install CodexBar to see usage"
            onChange?()
            return
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["dashboard", "--identity", "redacted", "--timeout", "30"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let version = generation
        self.process = process
        do { try process.run() }
        catch {
            self.process = nil
            message = "Couldn’t start CodexBar"
            onChange?()
            return
        }
        // Drain stdout concurrently so even a large provider list cannot fill the pipe.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let result = process.terminationStatus == 0 ? try? CodexBarSnapshot.decode(data) : nil
            DispatchQueue.main.async {
                guard let self, self.running, self.generation == version else { return }
                self.process = nil
                if let result {
                    self.snapshot = result
                    self.updatedAt = Date()
                    self.message = result.visibleProviders.isEmpty ? "Enable providers in CodexBar" : ""
                } else {
                    self.message = "Usage unavailable · Open CodexBar to check your connection"
                }
                self.onChange?()
            }
        }
    }
}

/// Horizontal layout gives workspaces priority and collapses usage to a single icon.
struct WorkspaceBarLayout {
    let workspaceWidth: CGFloat
    let statusWidth: CGFloat
    init(width: CGFloat, contentWidth: CGFloat) {
        let available = max(0, width)
        statusWidth = available < 100 ? 0 : min(130, max(32, available - contentWidth - 12))
        workspaceWidth = max(0, available - statusWidth - (statusWidth > 0 ? 8 : 0))
    }
    static func showsWorkspace(windowCount: Int, isFocused: Bool) -> Bool { windowCount > 0 || isFocused }
}

@MainActor final class CodexBarButton: NSButton {
    let status: CodexBarStatus
    private var popover: NSPopover?
    init(status: CodexBarStatus) {
        self.status = status
        super.init(frame: .zero)
        isBordered = false
        target = self
        action = #selector(showDetails)
        setAccessibilityLabel("CodexBar usage. Click for provider limits and reset times")
    }
    required init?(coder: NSCoder) { nil }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { closeDetails() }
        super.viewWillMove(toWindow: newWindow)
    }
    func update() {
        toolTip = status.message.isEmpty ? "CodexBar · \(status.snapshot?.showUsed == true ? "Used" : "Remaining") usage — click for details" : status.message
        needsDisplay = true
        if popover?.isShown == true { popover?.contentViewController = detailController() }
    }
    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted {
            NSColor.white.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        let providers = status.snapshot?.navbarProviders ?? []
        guard bounds.width >= 130, !providers.isEmpty else {
            let symbol = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: nil)
            symbol?.draw(in: CGRect(x: (bounds.width - 16) / 2, y: 4, width: 16, height: 14))
            return
        }
        let count = min(providers.count, bounds.width >= 230 ? 2 : 1)
        let cellWidth = bounds.width / CGFloat(count)
        for (index, provider) in providers.prefix(count).enumerated() {
            let x = CGFloat(index) * cellWidth + 9
            let color = provider.id == "claude" ? NSColor.systemOrange : NSColor.systemMint
            let percent = provider.windows?.first?.percent(showUsed: status.snapshot?.showUsed == true)
            let ring = NSBezierPath(ovalIn: CGRect(x: x, y: 5, width: 12, height: 12))
            ring.lineWidth = 2
            NSColor.white.withAlphaComponent(0.14).setStroke()
            ring.stroke()
            if let percent, percent > 0 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: CGPoint(x: x + 6, y: 11), radius: 6,
                              startAngle: 90, endAngle: 90 - CGFloat(percent) * 3.6, clockwise: true)
                arc.lineWidth = 2
                arc.lineCapStyle = .round
                color.withAlphaComponent(status.message.isEmpty ? 1 : 0.4).setStroke()
                arc.stroke()
            }
            let name = NSAttributedString(string: provider.name, attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.75)])
            name.draw(in: CGRect(x: x + 20, y: 5, width: cellWidth - 65, height: 13))
            let value = NSAttributedString(string: percent.map { "\(Int($0.rounded()))%" } ?? "—", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.white])
            value.draw(at: CGPoint(x: CGFloat(index + 1) * cellWidth - value.size().width - 9, y: 5))
        }
    }

    @objc private func showDetails() {
        if popover?.isShown == true { popover?.performClose(nil); return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = detailController()
        self.popover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .minY)
    }
    func closeDetails() { popover?.close(); popover = nil }
    private func detailController() -> NSViewController {
        let controller = NSViewController()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 18, right: 20)
        func label(_ text: String, size: CGFloat, color: NSColor = .labelColor, bold: Bool = false) -> NSTextField {
            let field = NSTextField(wrappingLabelWithString: text)
            field.font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
            field.textColor = color
            field.preferredMaxLayoutWidth = 280
            return field
        }
        stack.addArrangedSubview(label("CodexBar", size: 18, bold: true))
        let showUsed = status.snapshot?.showUsed == true
        stack.addArrangedSubview(label(showUsed ? "Usage across your providers" : "Remaining across your providers", size: 11, color: .secondaryLabelColor))
        for provider in status.snapshot?.visibleProviders ?? [] {
            stack.addArrangedSubview(NSBox.separator())
            stack.addArrangedSubview(label(provider.name, size: 13, bold: true))
            if provider.windows?.isEmpty != false { stack.addArrangedSubview(label("Usage unavailable", size: 11, color: .secondaryLabelColor)) }
            for window in provider.windows ?? [] {
                let percent = window.percent(showUsed: showUsed)
                let row = NSStackView()
                row.orientation = .horizontal
                row.addArrangedSubview(label(window.label, size: 12, color: .secondaryLabelColor))
                row.addArrangedSubview(NSView())
                let value = label("\(percent.map { "\(Int($0.rounded()))%" } ?? "—") \(showUsed ? "used" : "left")", size: 12, bold: true)
                value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
                row.addArrangedSubview(value)
                row.widthAnchor.constraint(equalToConstant: 280).isActive = true
                stack.addArrangedSubview(row)
                let meter = NSLevelIndicator(frame: .zero)
                meter.levelIndicatorStyle = .continuousCapacity
                meter.minValue = 0; meter.maxValue = 100
                meter.warningValue = 101; meter.criticalValue = 101
                meter.doubleValue = percent ?? 0
                meter.fillColor = provider.id == "claude" ? .systemOrange : .systemMint
                meter.heightAnchor.constraint(equalToConstant: 6).isActive = true
                meter.widthAnchor.constraint(equalToConstant: 280).isActive = true
                stack.addArrangedSubview(meter)
                if let raw = window.resetAt, let date = ISO8601DateFormatter().date(from: raw) {
                    stack.addArrangedSubview(label("Resets \(date.formatted(date: .abbreviated, time: .shortened))", size: 10, color: .secondaryLabelColor))
                }
            }
        }
        if !status.message.isEmpty { stack.addArrangedSubview(label(status.message, size: 11, color: .secondaryLabelColor)) }
        if let date = status.updatedAt { stack.addArrangedSubview(label("Updated \(date.formatted(date: .omitted, time: .shortened)) · refreshes every 3 min", size: 10, color: .tertiaryLabelColor)) }
        let open = NSButton(title: "Open CodexBar ↗", target: self, action: #selector(openCodexBar))
        open.bezelStyle = .rounded
        stack.addArrangedSubview(open)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        stack.frame = CGRect(x: 0, y: 0, width: 320, height: stack.fittingSize.height)
        scroll.documentView = stack
        controller.view = scroll
        controller.preferredContentSize = NSSize(width: 320, height: min(560, stack.fittingSize.height))
        scroll.frame.size = controller.preferredContentSize
        return controller
    }
    @objc private func openCodexBar() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.steipete.codexbar") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}

private extension NSBox {
    static func separator() -> NSBox { let box = NSBox(); box.boxType = .separator; return box }
}
