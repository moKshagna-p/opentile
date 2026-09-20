import AppKit
import Combine

struct MusicTrack {
    var title = "Apple Music"
    var artist = "Open Music and play a song"
    var playing = false
    var artwork: Data?
    var available = false

    static func decode(_ result: NSAppleEventDescriptor) -> MusicTrack {
        guard result.numberOfItems >= 4 else { return MusicTrack() }
        return MusicTrack(title: result.atIndex(1)?.stringValue ?? "Unknown track",
                          artist: result.atIndex(2)?.stringValue ?? "",
                          playing: result.atIndex(3)?.booleanValue ?? false,
                          artwork: result.atIndex(4).flatMap { $0.data.isEmpty ? nil : $0.data },
                          available: true)
    }
}

/// Music notifications trigger bounded, serialized requests; no playback polling.
@MainActor final class AppleMusicPlayer {
    @Published private(set) var track = MusicTrack()
    @Published private(set) var busy = false
    private let queue = DispatchQueue(label: "OpenTile.appleMusic", qos: .utility)
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var running = false
    private var generation = 0
    private var pending = false

    func start() {
        guard !running else { return }
        running = true
        for (center, name) in [
            (DistributedNotificationCenter.default() as NotificationCenter, Notification.Name("com.apple.Music.playerInfo")),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didLaunchApplicationNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didTerminateApplicationNotification)
        ] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                   app.bundleIdentifier != "com.apple.Music" { return }
                MainActor.assumeIsolated { self?.refresh() }
            }
            tokens.append((center, token))
        }
        refresh()
    }

    func stop() {
        running = false
        generation += 1
        pending = false
        tokens.forEach { $0.0.removeObserver($0.1) }
        tokens.removeAll()
        track = MusicTrack()
    }

    func refresh() { request(nil) }
    func control(_ command: Command) { request(command) }
    enum Command: String { case toggle = "playpause", previous = "previous track", next = "next track" }

    private func request(_ command: Command?) {
        guard running else { return }
        guard !busy else { if command == nil { pending = true }; return }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty == false else {
            track = MusicTrack()
            return
        }
        busy = true
        let version = generation
        let source = Self.script(command)
        queue.async { [weak self] in
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            let value: MusicTrack
            if let error {
                let denied = (error[NSAppleScript.errorNumber] as? Int) == -1743
                value = MusicTrack(artist: denied ? "Allow OpenTile → Music in Privacy & Security → Automation" : "Music is unavailable. Click to retry.")
            } else {
                value = result.map(MusicTrack.decode) ?? MusicTrack()
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                guard self.running else { return }
                if self.generation == version { self.track = value }
                if self.pending || self.generation != version {
                    self.pending = false
                    self.refresh()
                }
            }
        }
    }

    static func script(_ command: Command?) -> String {
        """
        with timeout of 5 seconds
            if application "Music" is not running then return {}
            tell application "Music"
                \(command?.rawValue ?? "")
                if player state is stopped then return {}
                set t to current track
                set cover to ""
                try
                    set cover to raw data of artwork 1 of t
                end try
                return {name of t, artist of t, player state is playing, cover}
            end tell
        end timeout
        """
    }
}

@MainActor final class MusicBarView: NSView {
    private let player: AppleMusicPlayer
    private let cover = NSButton()
    private let toggle = NSButton()
    private var subscription: AnyCancellable?
    private let popover = NSPopover()
    private let largeCover = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let artistLabel = NSTextField(wrappingLabelWithString: "")
    private var controls: [NSButton] = []
    private var artworkData: Data?
    private var hasArtwork = false

    init(player: AppleMusicPlayer, width: CGFloat) {
        self.player = player
        super.init(frame: NSRect(x: 8, y: 3, width: width, height: 22))
        cover.frame = NSRect(x: 0, y: 0, width: max(24, width - 28), height: 22)
        cover.isBordered = false
        cover.imagePosition = .imageLeading
        cover.imageScaling = .scaleProportionallyDown
        cover.font = .systemFont(ofSize: 11, weight: .medium)
        cover.lineBreakMode = .byTruncatingTail
        cover.target = self; cover.action = #selector(showPlayer)
        cover.contentTintColor = .white
        toggle.frame = NSRect(x: width - 24, y: 0, width: 24, height: 22)
        toggle.isBordered = false
        toggle.target = self; toggle.action = #selector(playPause)
        toggle.contentTintColor = .white
        addSubview(cover); addSubview(toggle)
        let controller = NSViewController()
        let surface = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 296, height: 400))
        surface.material = .popover
        surface.blendingMode = .behindWindow
        surface.state = .active
        controller.view = surface

        let heading = NSTextField(labelWithString: "APPLE MUSIC")
        heading.frame = NSRect(x: 24, y: 366, width: 248, height: 16)
        heading.font = .systemFont(ofSize: 10, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        surface.addSubview(heading)

        largeCover.frame = NSRect(x: 42, y: 138, width: 212, height: 212)
        largeCover.imageScaling = .scaleProportionallyUpOrDown
        largeCover.wantsLayer = true
        largeCover.layer?.cornerRadius = 10
        largeCover.layer?.masksToBounds = true
        largeCover.setAccessibilityLabel("Album artwork")
        titleLabel.frame = NSRect(x: 24, y: 106, width: 248, height: 22)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        artistLabel.frame = NSRect(x: 24, y: 66, width: 248, height: 36)
        artistLabel.font = .systemFont(ofSize: 12)
        artistLabel.textColor = .secondaryLabelColor
        artistLabel.alignment = .center
        for view in [largeCover, titleLabel, artistLabel] { surface.addSubview(view) }
        for (index, symbol) in ["backward.end.fill", "play.fill", "forward.end.fill"].enumerated() {
            let label = ["Previous track", "Play or pause", "Next track"][index]
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: [#selector(previous), #selector(playPause), #selector(next)][index])
            b.frame = NSRect(x: 64 + index * 60, y: 16, width: 48, height: 40)
            b.bezelStyle = .regularSquare
            b.isBordered = false
            b.contentTintColor = .labelColor
            b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: index == 1 ? 23 : 17, weight: .semibold)
            b.toolTip = label
            b.setAccessibilityLabel(label)
            surface.addSubview(b)
            controls.append(b)
        }
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = true
        subscription = player.$track.combineLatest(player.$busy).sink { [weak self] track, busy in
            self?.update(track, busy: busy)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func resize(to width: CGFloat) {
        frame.size.width = width
        cover.frame.size.width = max(24, width - 28)
        toggle.frame.origin.x = width - 24
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { popover.performClose(nil) }
        super.viewWillMove(toWindow: newWindow)
    }

    private func update(_ track: MusicTrack, busy: Bool) {
        if !hasArtwork || artworkData != track.artwork {
            hasArtwork = true
            artworkData = track.artwork
            let image = track.artwork.flatMap(NSImage.init(data:)) ?? NSImage(systemSymbolName: "music.note", accessibilityDescription: "Album artwork")!
            largeCover.image = image
            let thumbnail = NSImage(size: NSSize(width: 20, height: 20))
            thumbnail.lockFocus()
            image.draw(in: NSRect(x: 0, y: 0, width: 20, height: 20))
            thumbnail.unlockFocus()
            cover.image = thumbnail
        }
        cover.title = "  " + track.title
        cover.toolTip = track.title + " — " + track.artist
        cover.setAccessibilityLabel(cover.toolTip)
        titleLabel.stringValue = track.title
        artistLabel.stringValue = track.artist
        let symbol = track.playing ? "pause.fill" : "play.fill"
        toggle.image = NSImage(systemSymbolName: symbol, accessibilityDescription: track.playing ? "Pause" : "Play")
        controls[1].image = toggle.image
        let playbackLabel = track.playing ? "Pause" : "Play"
        toggle.setAccessibilityLabel(playbackLabel)
        controls[1].setAccessibilityLabel(playbackLabel)
        controls[1].toolTip = playbackLabel
        titleLabel.toolTip = track.title
        artistLabel.toolTip = track.artist
        toggle.isEnabled = track.available && !busy
        controls.forEach { $0.isEnabled = track.available && !busy }
    }

    @objc private func showPlayer() {
        if popover.isShown { popover.performClose(nil); return }
        popover.show(relativeTo: cover.bounds, of: cover, preferredEdge: .minY)
        player.refresh()
    }
    @objc private func playPause() { player.control(.toggle) }
    @objc private func previous() { player.control(.previous) }
    @objc private func next() { player.control(.next) }
}
