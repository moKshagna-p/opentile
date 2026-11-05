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
    var showUsed: Bool { host.usageBarsShowUsed ?? false }
    static func decode(_ data: Data) throws -> Self {
        let snapshot = try JSONDecoder().decode(Self.self, from: data)
        guard snapshot.schemaVersion == 1 else { throw CocoaError(.coderReadCorrupt) }
        return snapshot
    }

    /// The provider whose usage grew since the previous refresh. Resets (capacity going back up) don't count.
    static func activeProvider(from old: CodexBarSnapshot?, to new: CodexBarSnapshot) -> String? {
        guard let old else { return nil }
        var best: (id: String, growth: Double)?
        for provider in new.visibleProviders {
            guard let before = old.providers.first(where: { $0.id == provider.id }) else { continue }
            for window in provider.windows ?? [] {
                guard let previous = before.windows?.first(where: { $0.label == window.label }),
                      let now = window.percent(showUsed: true), let then = previous.percent(showUsed: true),
                      now - then > (best?.growth ?? 0) else { continue }
                best = (provider.id, now - then)
            }
        }
        return best?.id
    }

    /// Enabled providers with the one in use first; the rest keep CodexBar's order.
    func providers(activeFirst id: String?) -> [Provider] {
        visibleProviders.filter { $0.id == id } + visibleProviders.filter { $0.id != id }
    }
}

/// The navbar always displays remaining capacity, independent of CodexBar's detail preference.
struct CodexBarRemainingUsage {
    let percent: Double?

    init(window: CodexBarSnapshot.Window?) {
        percent = window?.percent(showUsed: false)
    }

    func ringPath(center: CGPoint, radius: CGFloat) -> NSBezierPath {
        guard let percent, percent > 0 else { return NSBezierPath() }
        if percent == 100 {
            return NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius,
                                              width: radius * 2, height: radius * 2))
        }
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: radius, startAngle: 90,
                       endAngle: 90 - CGFloat(percent) * 3.6, clockwise: true)
        return path
    }
}

/// Runs CodexBar's supported adapter off the UI thread; one request at a time.
@MainActor final class CodexBarStatus {
    private(set) var snapshot: CodexBarSnapshot?
    private(set) var message = "Connecting to CodexBar…"
    private(set) var updatedAt: Date?
    private(set) var activeProviderID = UserDefaults.standard.string(forKey: "codexBarActiveProvider") ?? "claude"
    var orderedProviders: [CodexBarSnapshot.Provider] { snapshot?.providers(activeFirst: activeProviderID) ?? [] }
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
        let executable = Self.app.appendingPathComponent("Contents/Helpers/CodexBarCLI")
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
                    if let active = CodexBarSnapshot.activeProvider(from: self.snapshot, to: result) {
                        self.activeProviderID = active
                        UserDefaults.standard.set(active, forKey: "codexBarActiveProvider")
                    }
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

extension CodexBarStatus {
    static var app: URL {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.steipete.codexbar")
            ?? URL(fileURLWithPath: "/Applications/CodexBar.app")
    }

    private static var logos: [String: NSImage] = [:]
    /// CodexBar ships a monochrome SVG per provider; reuse it instead of bundling brand assets.
    static func logo(for id: String) -> NSImage? {
        if let cached = logos[id] { return cached }
        guard let image = NSImage(contentsOf: app.appendingPathComponent("Contents/Resources/ProviderIcon-\(id).svg"))
        else { return nil }
        image.isTemplate = true
        logos[id] = image
        return image
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
    private var dropdown: NSMenu?
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
        toolTip = status.message.isEmpty ? "CodexBar · Remaining usage — click for details" : status.message
        needsDisplay = true
        if let dropdown { refresh(dropdown) }
    }
    override func draw(_ dirtyRect: NSRect) {
        // Same capsule language as the status groups on the right.
        let pill = bounds.insetBy(dx: 1, dy: 0)
        NSColor.white.withAlphaComponent(isHighlighted ? 0.16 : 0.075).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        let providers = status.orderedProviders
        guard bounds.width >= 60, !providers.isEmpty else {
            let symbol = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: nil)
            symbol?.tinted(SplitBarStyle.primary).draw(in: CGRect(x: (bounds.width - 16) / 2, y: 4, width: 16, height: 14))
            return
        }
        let cellWidth = bounds.width
        for provider in providers.prefix(1) {
            let x: CGFloat = 10
            let color = provider.id == "claude" ? NSColor.systemOrange : NSColor.systemMint
            let usage = CodexBarRemainingUsage(window: provider.windows?.first)
            let percent = usage.percent
            let ring = NSBezierPath(ovalIn: CGRect(x: x - 1, y: 3, width: 16, height: 16))
            ring.lineWidth = 1.75
            NSColor.white.withAlphaComponent(0.14).setStroke()
            ring.stroke()
            CodexBarStatus.logo(for: provider.id)?.tinted(SplitBarStyle.primary)
                .draw(in: CGRect(x: x + 2.5, y: 6.5, width: 9, height: 9))
            if let percent, percent > 0 {
                let arc = usage.ringPath(center: CGPoint(x: x + 7, y: 11), radius: 8)
                arc.lineWidth = 1.75
                arc.lineCapStyle = .round
                color.withAlphaComponent(status.message.isEmpty ? 1 : 0.4).setStroke()
                arc.stroke()
            }
            let name = NSAttributedString(string: provider.name, attributes: [
                .font: SplitBarStyle.font, .foregroundColor: SplitBarStyle.secondary])
            let value = NSAttributedString(string: percent.map { "\(Int($0.rounded()))%" } ?? "—", attributes: [
                .font: SplitBarStyle.font, .foregroundColor: SplitBarStyle.primary])
            let nameWidth = min(name.size().width, cellWidth - value.size().width - 40)
            let textY = (bounds.height - value.size().height) / 2
            name.draw(in: CGRect(x: x + 21, y: textY, width: nameWidth, height: value.size().height))
            value.draw(at: CGPoint(x: x + 21 + nameWidth + 5, y: textY))
        }
    }

    /// Ring, name and percentage plus even 10pt padding; the bar never stretches the capsule past this.
    var preferredWidth: CGFloat {
        guard let provider = status.orderedProviders.first else { return 32 }
        let percent = CodexBarRemainingUsage(window: provider.windows?.first).percent
        let text = [provider.name, percent.map { "\(Int($0.rounded()))%" } ?? "—"]
            .map { ($0 as NSString).size(withAttributes: [.font: SplitBarStyle.font]).width }
        return ceil(10 + 21 + text[0] + 5 + text[1] + 10)
    }

    private struct Content {
        let title: String
        let logo: NSImage?
        let subtitle: String
        let value: String
        let fraction: Double
        let details: [SplitBarDropdown.Detail]
    }

    private var content: Content {
        let showUsed = status.snapshot?.showUsed == true
        let providers = status.orderedProviders
        let lead = providers.first
        let leadPercent = lead?.windows?.first?.percent(showUsed: showUsed)
        var details: [SplitBarDropdown.Detail] = []
        for provider in providers {
            for window in provider.windows ?? [] {
                var value = window.percent(showUsed: showUsed).map { "\(Int($0.rounded()))%" } ?? "—"
                if let raw = window.resetAt, let date = ISO8601DateFormatter().date(from: raw) {
                    value += " · " + date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
                }
                details.append(.init(title: "\(provider.name) \(window.label.lowercased())", value: value,
                                     symbol: "chart.bar", image: CodexBarStatus.logo(for: provider.id)))
            }
        }
        let subtitle = !status.message.isEmpty ? status.message
            : status.updatedAt.map { "\(showUsed ? "Used" : "Left") · updated \($0.formatted(date: .omitted, time: .shortened))" }
            ?? "Remaining across your providers"
        return Content(title: lead?.name.uppercased() ?? "USAGE",
                       logo: lead.flatMap { CodexBarStatus.logo(for: $0.id) }, subtitle: subtitle,
                       value: leadPercent.map { "\(Int($0.rounded()))% \(showUsed ? "used" : "left")" } ?? "—",
                       fraction: (leadPercent ?? 0) / 100, details: details)
    }

    private func refresh(_ menu: NSMenu) {
        let content = content
        SplitBarDropdown.update(menu, title: content.title, subtitle: content.subtitle,
                                symbol: "gauge.with.dots.needle.67percent", value: content.value,
                                visual: .level(content.fraction), logo: content.logo, details: content.details)
    }

    @objc private func showDetails() {
        let content = content
        let menu = SplitBarDropdown.make(title: content.title, subtitle: content.subtitle,
            symbol: "gauge.with.dots.needle.67percent", value: content.value,
            visual: .level(content.fraction), logo: content.logo, details: content.details,
            settingsTitle: "Open CodexBar…", settingsAction: #selector(openCodexBar), target: self)
        self.dropdown = menu
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: self)
        self.dropdown = nil
    }
    func closeDetails() { dropdown?.cancelTracking() }
    @objc private func openCodexBar() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.steipete.codexbar") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}
