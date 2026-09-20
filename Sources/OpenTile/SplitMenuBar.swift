import AppKit
import AppBundle
import Combine
import CoreAudio
import IOKit.ps
import Network

struct SplitBarFrames {
    let left: CGRect
    let right: CGRect

    init(screen: CGRect, leftSafeArea: CGRect?, rightSafeArea: CGRect?) {
        let height: CGFloat = 28
        let leftEnd = leftSafeArea?.maxX ?? (screen.midX - 6)
        let rightStart = rightSafeArea?.minX ?? (screen.midX + 6)
        left = CGRect(x: screen.minX, y: screen.maxY - height,
                      width: max(0, leftEnd - screen.minX), height: height)
        right = CGRect(x: rightStart, y: screen.maxY - height,
                       width: max(0, screen.maxX - rightStart), height: height)
    }
}

final class BarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // Our frames already avoid the camera. AppKit's default constraint moves
    // windows below the entire menu-bar safe area when they are ordered onscreen.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Draw icons directly so the active workspace tint never recolors application logos.
final class WorkspaceBarButton: NSButton {
    var appIcons: [NSImage] = []
    var active = false
    var preferredWidth: CGFloat {
        let labelWidth = (title as NSString).size(withAttributes: [.font: font!]).width
        return max(30, ceil(labelWidth) + 16 + CGFloat(appIcons.count) * 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        if active || isHighlighted {
            (active ? NSColor.systemMint.withAlphaComponent(0.18) : NSColor.white.withAlphaComponent(0.1)).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font!, .foregroundColor: active ? NSColor.systemMint : NSColor(calibratedWhite: 0.85, alpha: 1)
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: 8, y: (bounds.height - size.height) / 2), withAttributes: attributes)
        var x = ceil(size.width) + 12
        for icon in appIcons {
            icon.draw(in: NSRect(x: x, y: (bounds.height - 20) / 2, width: 20, height: 20),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += 22
        }
    }
}

/// Native panels and event-driven workspaces; music updates are event-driven and the clock ticks once per minute.
@MainActor final class SplitMenuBar: NSObject {
    private let key = "splitMenuBarEnabled"
    private let music = AppleMusicPlayer()
    private let codexBar = CodexBarStatus()
    private var codexButtons: [CodexBarButton] = []
    private var musicItem: NSMenuItem?
    private var panels: [(left: BarPanel, right: BarPanel)] = []
    private var subscription: AnyCancellable?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Timer?
    private var trafficTimer: Timer?
    private var traffic = NetworkTraffic()
    private var trafficText = "↓ 0 B/s  ↑ 0 B/s"
    private var trafficButtons: [NSButton] = []
    private var network: NWPathMonitor?
    private var powerSource: CFRunLoopSource?
    private var audioListener: AudioObjectPropertyListenerBlock?
    private var audioDevice: AudioDeviceID = 0
    private var state: OpenTileBarState?
    private var renderedWorkspaces: [OpenTileWorkspaceSummary]?
    private var renderedStatus: String?
    private var appIcons: [String: NSImage] = [:]
    private var wifi = false
    private var running = false
    private var sleeping = false
    private var generation = 0
    private weak var menu: NSMenu?
    private var toggleItem: NSMenuItem?
    var selectWorkspace: ((String) -> Void)?
    private let clockFormat: DateFormatter = {
        let format = DateFormatter()
        format.dateFormat = "EEE  HH:mm"
        return format
    }()

    func install(in menu: NSMenu) {
        self.menu = menu
        let item = NSMenuItem(title: "Enable Split Menu Bar", action: #selector(toggle), keyEquivalent: "")
        item.target = self
        item.toolTip = "For the top-edge bar, set the macOS menu bar to automatically hide in System Settings."
        menu.addItem(item)
        toggleItem = item
        let musicItem = NSMenuItem(title: "Show Apple Music Player", action: #selector(toggleMusic), keyEquivalent: "")
        musicItem.target = self
        musicItem.state = UserDefaults.standard.bool(forKey: "splitBarAppleMusic") ? .on : .off
        menu.addItem(musicItem)
        self.musicItem = musicItem
        item.state = UserDefaults.standard.bool(forKey: key) ? .on : .off
        if item.state == .on { start() }
    }

    @objc private func toggle() {
        let enabled = toggleItem?.state != .on
        UserDefaults.standard.set(enabled, forKey: key)
        toggleItem?.state = enabled ? .on : .off
        if enabled { start() } else { stop() }
    }

    @objc private func toggleMusic() {
        let enabled = musicItem?.state != .on
        musicItem?.state = enabled ? .on : .off
        UserDefaults.standard.set(enabled, forKey: "splitBarAppleMusic")
        if enabled && running && !sleeping { music.start() } else { music.stop() }
        renderedStatus = nil
        renderStatus()
    }

    private func start() {
        guard !running else { return }
        running = true
        sleeping = false
        setOpenTileBarHeight(28)
        subscription = TrayMenuModel.shared.$openTileBar.compactMap { $0 }.removeDuplicates().sink { [weak self] state in
            self?.state = state
            self?.renderWorkspaces()
        }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { $0.rebuild() }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification) {
            $0.sleeping = true
            $0.stopStatus()
            $0.panels.forEach { $0.left.orderOut(nil); $0.right.orderOut(nil) }
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) {
            $0.sleeping = false
            $0.startStatus()
            $0.rebuild()
        }
        startStatus()
        rebuild()
    }

    func stop() {
        running = false
        subscription = nil
        stopStatus()
        observers.forEach { $0.0.removeObserver($0.1) }
        observers.removeAll()
        panels.forEach { $0.left.close(); $0.right.close() }
        panels.removeAll()
        setOpenTileBarHeight(0)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         action: @escaping (SplitMenuBar) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self, self.running { action(self) } }
        }
        observers.append((center, token))
    }

    private func rebuild() {
        renderedWorkspaces = nil
        renderedStatus = nil
        panels.forEach { $0.left.close(); $0.right.close() }
        panels = NSScreen.screens.map { screen in
            let frames = SplitBarFrames(screen: screen.frame, leftSafeArea: screen.auxiliaryTopLeftArea,
                                        rightSafeArea: screen.auxiliaryTopRightArea)
            return (makePanel(frames.left), makePanel(frames.right))
        }
        renderWorkspaces()
        renderStatus()
    }

    private func makePanel(_ frame: CGRect) -> BarPanel {
        let panel = BarPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenNone]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = true
        panel.backgroundColor = NSColor(calibratedWhite: 0.055, alpha: 1)
        panel.hasShadow = false
        panel.animationBehavior = .none
        return panel
    }

    private func button(_ title: String, symbol: String? = nil, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        button.contentTintColor = .init(calibratedWhite: 0.85, alpha: 1)
        if let symbol { button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title); button.imagePosition = .imageLeading }
        return button
    }

    private func renderWorkspaces() {
        guard running else { return }
        let workspaces = (state?.workspaces ?? openTileWorkspaces()).filter {
            WorkspaceBarLayout.showsWorkspace(windowCount: $0.windowCount, isFocused: $0.isFocused)
        }
        let needsButtons = renderedWorkspaces != workspaces
        if needsButtons {
            let paths = Set(workspaces.flatMap(\.applicationBundlePaths))
            appIcons = appIcons.filter { paths.contains($0.key) }
            for path in paths where appIcons[path] == nil {
                appIcons[path] = NSWorkspace.shared.icon(forFile: path)
            }
        }
        renderedWorkspaces = workspaces
        if needsButtons {
            codexButtons.forEach { $0.closeDetails() }
            codexButtons.removeAll()
        }
        for (index, pair) in panels.enumerated() {
            let hidden = sleeping || state?.fullscreenScreenIndices.contains(index + 1) == true
            if hidden { pair.left.orderOut(nil); pair.right.orderOut(nil) }
            else { pair.left.orderFrontRegardless(); pair.right.orderFrontRegardless() }
            guard needsButtons else { continue }
            let container = NSView(frame: pair.left.contentView!.bounds)
            let scroll = NSScrollView(frame: container.bounds)
            scroll.autoresizingMask = [.width, .height]
            scroll.drawsBackground = false
            scroll.hasHorizontalScroller = false
            let content = NSView()
            var x: CGFloat = 10
            for workspace in workspaces {
                let b = WorkspaceBarButton(title: workspace.name, target: self, action: #selector(workspaceClicked))
                b.isBordered = false
                b.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
                b.appIcons = workspace.applicationBundlePaths.compactMap { appIcons[$0] }
                b.active = workspace.isFocused
                b.identifier = NSUserInterfaceItemIdentifier(workspace.name)
                b.toolTip = "\(workspace.name) — \(workspace.windowCount) windows\n\(workspace.applications.joined(separator: ", "))"
                b.setAccessibilityLabel("Workspace \(workspace.name)\(workspace.isFocused ? ", active" : ""), \(workspace.applications.joined(separator: ", "))")
                b.frame = CGRect(x: x, y: 3, width: b.preferredWidth, height: 22)
                content.addSubview(b)
                x += b.frame.width + 4
            }
            let layout = WorkspaceBarLayout(width: container.bounds.width, contentWidth: x + 6)
            scroll.frame.size.width = layout.workspaceWidth
            content.frame = CGRect(x: 0, y: 0, width: max(x + 6, scroll.bounds.width), height: 28)
            scroll.documentView = content
            container.addSubview(scroll)
            if layout.statusWidth > 0 {
                let usage = CodexBarButton(status: codexBar)
                usage.frame = CGRect(x: container.bounds.width - layout.statusWidth - 4, y: 3, width: layout.statusWidth, height: 22)
                usage.update()
                container.addSubview(usage)
                codexButtons.append(usage)
            }
            pair.left.contentView = container
            if let active = content.subviews.first(where: { $0.identifier?.rawValue == workspaces.first(where: \.isFocused)?.name }) {
                active.scrollToVisible(active.bounds)
            }
        }
    }

    @objc private func workspaceClicked(_ sender: NSButton) {
        if let name = sender.identifier?.rawValue { selectWorkspace?(name) }
    }

    private func startStatus() {
        stopStatus()
        let version = generation
        codexBar.onChange = { [weak self] in self?.codexButtons.forEach { $0.update() } }
        codexBar.start()
        if musicItem?.state == .on { music.start() }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.status == .satisfied && path.usesInterfaceType(.wifi)
            DispatchQueue.main.async {
                guard let self, self.running, self.generation == version else { return }
                self.wifi = wifi
                self.renderStatus()
            }
        }
        network = monitor
        monitor.start(queue: DispatchQueue(label: "OpenTile.menuBar.network", qos: .utility))
        updateTraffic()
        let trafficTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateTraffic() }
        }
        trafficTimer.tolerance = 0.2
        self.trafficTimer = trafficTimer
        RunLoop.main.add(trafficTimer, forMode: .common)
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<SplitMenuBar>.fromOpaque(context).takeUnretainedValue().renderStatus()
            }
        }, context)?.takeRetainedValue() {
            powerSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.running, self.generation == version else { return }
            self.observeAudioDevice()
            self.renderStatus()
        }
        audioListener = listener
        var address = Self.audioAddress(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        observeAudioDevice()
        let timer = Timer(fire: Date(timeIntervalSince1970: (floor(Date().timeIntervalSince1970 / 60) + 1) * 60), interval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderStatus() }
        }
        timer.tolerance = 1
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateTraffic() {
        guard running, !sleeping else { return }
        let rates = traffic.sample(NetworkTraffic.readInterfaces(), at: ProcessInfo.processInfo.systemUptime)
        trafficText = "↓ \(NetworkTraffic.format(rates.down))  ↑ \(NetworkTraffic.format(rates.up))"
        for button in trafficButtons {
            button.title = trafficText
            button.setAccessibilityLabel("Download \(NetworkTraffic.format(rates.down)), upload \(NetworkTraffic.format(rates.up))")
        }
    }

    private static func audioAddress(_ selector: AudioObjectPropertySelector, output: Bool = false) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: output ? kAudioDevicePropertyScopeOutput : kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private func observeAudioDevice() {
        var address = Self.audioAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout.size(ofValue: device))
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != audioDevice, let listener = audioListener else { return }
        for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
            var property = Self.audioAddress(selector, output: true)
            if audioDevice != 0 { AudioObjectRemovePropertyListenerBlock(audioDevice, &property, .main, listener) }
            AudioObjectAddPropertyListenerBlock(device, &property, .main, listener)
        }
        audioDevice = device
    }

    private func stopStatus() {
        generation += 1
        codexBar.stop()
        codexButtons.forEach { $0.closeDetails() }
        music.stop()
        timer?.invalidate(); timer = nil
        network?.cancel(); network = nil
        trafficTimer?.invalidate(); trafficTimer = nil
        traffic = NetworkTraffic()
        trafficButtons.removeAll()
        if let source = powerSource { CFRunLoopSourceInvalidate(source) }
        powerSource = nil
        if let listener = audioListener {
            var address = Self.audioAddress(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
            for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
                var property = Self.audioAddress(selector, output: true)
                if audioDevice != 0 { AudioObjectRemovePropertyListenerBlock(audioDevice, &property, .main, listener) }
            }
        }
        audioListener = nil
        audioDevice = 0
    }

    private func renderStatus() {
        guard running, !sleeping else { return }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: volume))
        var address = Self.audioAddress(kAudioDevicePropertyVolumeScalar, output: true)
        let hasVolume = AudioObjectGetPropertyData(audioDevice, &address, 0, nil, &size, &volume) == noErr
        var muted: UInt32 = 0
        size = UInt32(MemoryLayout.size(ofValue: muted))
        address = Self.audioAddress(kAudioDevicePropertyMute, output: true)
        _ = AudioObjectGetPropertyData(audioDevice, &address, 0, nil, &size, &muted)
        var battery: String?
        var batteryFraction: Double = 0
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                      let current = description[kIOPSCurrentCapacityKey] as? Int,
                      let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
                batteryFraction = BatteryIndicator.fraction(current: current, maximum: maximum)
                battery = "\(Int((batteryFraction * 100).rounded()))%" + ((description[kIOPSIsChargingKey] as? Bool == true) ? " +" : "")
            }
        }
        let clock = clockFormat.string(from: Date())
        let sound = muted != 0 ? "Muted" : (hasVolume ? "\(Int(volume * 100))%" : "Sound")
        let presentation = "\(wifi)|\(sound)|\(battery ?? "")|\(clock)"
        guard renderedStatus != presentation else { return }
        renderedStatus = presentation
        trafficButtons.removeAll()
        for pair in panels {
            let view = pair.right.contentView!
            let existingMusic = view.subviews.compactMap { $0 as? MusicBarView }.first
            view.subviews.filter { !($0 is MusicBarView) }.forEach { $0.removeFromSuperview() }
            var modules: [NSButton] = []
            let networkButton = button("", symbol: wifi ? "wifi" : "network", action: #selector(networkSettings))
            networkButton.toolTip = wifi ? "Connected through Wi-Fi" : "Network settings"
            networkButton.setAccessibilityLabel(networkButton.toolTip)
            modules.append(networkButton)
            let trafficButton = button(trafficText, action: #selector(networkSettings))
            trafficButton.toolTip = "Download / upload over Wi-Fi and Ethernet"
            trafficButton.setAccessibilityLabel(trafficText)
            trafficButtons.append(trafficButton)
            modules.append(trafficButton)
            let soundButton = button("", symbol: muted != 0 ? "speaker.slash" : "speaker.wave.2", action: #selector(soundSettings))
            soundButton.toolTip = sound
            soundButton.setAccessibilityLabel("Sound: \(sound)")
            modules.append(soundButton)
            if let battery {
                let batteryButton = button(battery, action: #selector(batterySettings))
                batteryButton.image = BatteryIndicator.image(fraction: batteryFraction)
                batteryButton.imagePosition = .imageLeading
                batteryButton.setAccessibilityLabel("Battery \(battery)")
                modules.append(batteryButton)
            }
            modules.append(button(clock, action: #selector(clockSettings)))
            let appButton = button("", symbol: "rectangle.3.group", action: #selector(showMenu))
            appButton.setAccessibilityLabel("OpenTile menu")
            appButton.toolTip = "OpenTile menu"
            modules.append(appButton)
            var x = view.bounds.width - 8
            for b in modules.reversed() {
                b.sizeToFit()
                let width = b === trafficButton ? 190 : max(25, b.frame.width + 16)
                guard x - width >= 0 else { continue }
                x -= width
                b.frame = CGRect(x: x, y: 3, width: width, height: 22)
                view.addSubview(b)
            }
            if musicItem?.state == .on, x >= 68 {
                let musicView = existingMusic ?? MusicBarView(player: music, width: min(52, x - 16))
                musicView.resize(to: min(52, x - 16))
                if musicView.superview == nil { view.addSubview(musicView) }
            }
            if musicItem?.state != .on || x < 68 { existingMusic?.removeFromSuperview() }
        }
    }

    @objc private func showMenu(_ sender: NSButton) { menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: sender) }
    private func settings(_ pane: String) { if let url = URL(string: "x-apple.systempreferences:\(pane)") { NSWorkspace.shared.open(url) } }
    @objc private func networkSettings() { settings("com.apple.wifi-settings-extension") }
    @objc private func soundSettings() { settings("com.apple.Sound-Settings.extension") }
    @objc private func batterySettings() { settings("com.apple.Battery-Settings.extension") }
    @objc private func clockSettings() { settings("com.apple.Date-Time-Settings.extension") }
}
