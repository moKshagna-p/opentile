import AppKit
import Combine

struct MusicTrack {
    var title = "Apple Music"
    var artist = "Open Music and play a song"
    var playing = false
    var artwork: Data?
    var available = false
    var album = ""
    var identity: [String] { [title, artist, album] }

    static func decode(_ result: NSAppleEventDescriptor) -> MusicTrack {
        guard result.numberOfItems >= 4 else { return MusicTrack() }
        return MusicTrack(title: result.atIndex(1)?.stringValue ?? "Unknown track",
                          artist: result.atIndex(2)?.stringValue ?? "",
                          playing: result.atIndex(3)?.booleanValue ?? false,
                          artwork: result.atIndex(4).flatMap { $0.data.isEmpty ? nil : $0.data },
                          available: true,
                          album: result.atIndex(5)?.stringValue ?? "")
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
    private var artworkState = MusicArtworkState()
    private var artworkTask: Task<Void, Never>?

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
        artworkTask?.cancel()
        artworkTask = nil
        artworkState = MusicArtworkState()
        track = MusicTrack()
    }

    func refresh() { request(nil) }
    func control(_ command: Command) { request(command) }
    enum Command: String { case toggle = "playpause", previous = "previous track", next = "next track" }

    private func request(_ command: Command?) {
        guard running else { return }
        guard !busy else { if command == nil { pending = true }; return }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty == false else {
            accept(MusicTrack())
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
                if self.generation == version { self.accept(value) }
                if self.pending || self.generation != version {
                    self.pending = false
                    self.refresh()
                }
            }
        }
    }

    private func accept(_ value: MusicTrack) {
        let changed = track.identity != value.identity || track.available != value.available
        if changed || value.artwork.flatMap(NSImage.init(data:)) != nil {
            artworkTask?.cancel()
            artworkTask = nil
        }
        track = artworkState.accept(value)
        guard track.available, track.artwork == nil, artworkTask == nil else { return }
        let expected = track.identity
        if let delay = artworkState.nextRetryDelay() {
            artworkTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, let self, self.running, self.track.identity == expected else { return }
                self.artworkTask = nil
                self.refresh()
            }
        } else if artworkState.beginCatalogLookup() {
            let snapshot = track
            artworkTask = Task { [weak self] in
                let data = await MusicArtworkCatalog.fetch(for: snapshot)
                guard !Task.isCancelled, let self, self.running, self.track.identity == expected else { return }
                self.artworkTask = nil
                if let data {
                    var updated = self.track
                    updated.artwork = data
                    self.track = self.artworkState.accept(updated)
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
                if cover is "" then
                    try
                        set cover to data of artwork 1 of t
                    end try
                end if
                return {name of t, artist of t, player state is playing, cover, album of t}
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
    private var dropdown: NSMenu!
    private var controls: [NSButton] = []
    private var artworkData: Data?
    private var hasArtwork = false
    private var artwork: NSImage?

    static let width: CGFloat = 54

    init(player: AppleMusicPlayer) {
        self.player = player
        super.init(frame: NSRect(x: 8, y: 3, width: Self.width, height: 22))
        // 9pt from each capsule edge, matching the status capsules.
        cover.frame = NSRect(x: 9, y: 2, width: 18, height: 18)
        cover.isBordered = false
        cover.imagePosition = .imageOnly
        cover.imageScaling = .scaleProportionallyDown
        cover.target = self; cover.action = #selector(showPlayer)
        toggle.frame = NSRect(x: 31, y: 0, width: 16, height: 22)
        toggle.isBordered = false
        toggle.target = self; toggle.action = #selector(playPause)
        toggle.contentTintColor = SplitBarStyle.primary
        toggle.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        addSubview(cover); addSubview(toggle)

        // Playback controls live in the same native dropdown the other bar items use.
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 46))
        for (index, symbol) in ["backward.end.fill", "play.fill", "forward.end.fill"].enumerated() {
            let label = ["Previous track", "Play or pause", "Next track"][index]
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: [#selector(previous), #selector(playPause), #selector(next)][index])
            b.frame = NSRect(x: 56 + index * 60, y: 3, width: 48, height: 40)
            b.bezelStyle = .regularSquare
            b.isBordered = false
            b.contentTintColor = .labelColor
            b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: index == 1 ? 21 : 15, weight: .semibold)
            b.toolTip = label
            b.setAccessibilityLabel(label)
            row.addSubview(b)
            controls.append(b)
        }
        dropdown = SplitBarDropdown.make(title: "APPLE MUSIC", subtitle: "", symbol: "music.note", value: "",
            visual: .none, details: [.init(title: "Album", value: "", symbol: "square.stack")],
            extraViews: [row], settingsTitle: "Open Music…", settingsAction: #selector(openMusic), target: self)
        subscription = player.$track.combineLatest(player.$busy).sink { [weak self] track, busy in
            self?.update(track, busy: busy)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { dropdown.cancelTracking() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.075).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    private func update(_ track: MusicTrack, busy: Bool) {
        if !hasArtwork || artworkData != track.artwork {
            hasArtwork = true
            artworkData = track.artwork
            artwork = track.artwork.flatMap(NSImage.init(data:))
            let image = artwork ?? NSImage(systemSymbolName: "music.note", accessibilityDescription: "Album artwork")!.tinted(SplitBarStyle.primary)
            let thumbnail = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).addClip()
                image.draw(in: rect)
                return true
            }
            cover.image = thumbnail
        }
        cover.title = ""
        cover.toolTip = track.title + " — " + track.artist
        cover.setAccessibilityLabel(cover.toolTip)
        let symbol = track.playing ? "pause.fill" : "play.fill"
        toggle.image = NSImage(systemSymbolName: symbol, accessibilityDescription: track.playing ? "Pause" : "Play")
        controls[1].image = toggle.image
        let playbackLabel = track.playing ? "Pause" : "Play"
        toggle.setAccessibilityLabel(playbackLabel)
        controls[1].setAccessibilityLabel(playbackLabel)
        controls[1].toolTip = playbackLabel
        toggle.isEnabled = track.available && !busy
        controls.forEach { $0.isEnabled = track.available && !busy }
        SplitBarDropdown.update(dropdown, title: !track.available ? "APPLE MUSIC" : track.playing ? "NOW PLAYING" : "PAUSED",
            subtitle: track.artist, symbol: "music.note", value: track.available ? track.title : "Not playing",
            visual: .none, artwork: artwork,
            details: [.init(title: "Album", value: track.album.isEmpty ? "—" : track.album, symbol: "square.stack")])
    }

    @objc private func showPlayer() {
        player.refresh()
        dropdown.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: self)
    }
    @objc private func playPause() { player.control(.toggle) }
    @objc private func previous() { player.control(.previous) }
    @objc private func next() { player.control(.next) }
    @objc private func openMusic() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}
