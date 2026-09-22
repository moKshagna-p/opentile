import AppKit
import Carbon

enum WallpaperPickerStyle {
    private static let guidanceFont = NSFont.systemFont(
        ofSize: NSFont.smallSystemFontSize,
        weight: .regular
    )

    static func selectionGuidance(selected: Int, count: Int) -> NSAttributedString {
        guidance("\(selected + 1) of \(count)   ←  →  Select   ↩  Apply to All Displays   ⎋  Close")
    }

    static func searchGuidance() -> NSAttributedString {
        guidance("Type a Name or Source   ⎋  Clear Search   ⌘O  Open Folder")
    }

    private static func guidance(_ text: String) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        return NSAttributedString(string: text, attributes: [
            .font: guidanceFont,
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraphStyle,
        ])
    }
}

@MainActor final class WallpaperPicker: NSObject, NSSearchFieldDelegate, NSWindowDelegate {
    private var panel: WallpaperPanel?
    private var carousel: WallpaperCarousel?
    private let search = NSSearchField()
    private let caption = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private let transition = WallpaperTransition()
    private var entries: [WallpaperEntry] = []
    private var filtered: [WallpaperEntry] = []
    private var selected = 0
    private var applying = false
    private var generation = 0
    private var scanTask: Task<[WallpaperEntry], Never>?
    private var applyTask: Task<Void, Never>?
    private let thumbnails = NSCache<NSURL, NSImage>()
    private let thumbnailQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var pending = Set<URL>()
    private var failed = Set<URL>()
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    var onStatus: ((String) -> Void)?

    func install(in menu: NSMenu) {
        let item = menu.addItem(withTitle: "Choose Wallpaper…", action: #selector(show), keyEquivalent: "w")
        item.keyEquivalentModifierMask = [.control, .option]
        item.target = self
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr, identifier.signature == 0x4F545750 else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                Unmanaged<WallpaperPicker>.fromOpaque(context).takeUnretainedValue().show()
            }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        if result == noErr {
            let status = RegisterEventHotKey(UInt32(kVK_ANSI_W), UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x4F545750, id: 1), GetApplicationEventTarget(), 0, &hotKey)
            if status != noErr { onStatus?("Wallpaper shortcut is unavailable; use Choose Wallpaper from the menu") }
        }
    }

    @objc func show() {
        guard !applying else { return }
        if let panel, panel.isVisible { panel.makeKeyAndOrderFront(nil); return }
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main else { return }
        let panel = WallpaperPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = NSColor(calibratedWhite: 0.035, alpha: 0.94)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.delegate = self
        panel.onBrowse = { [weak self] in self?.browse() }
        let content = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        panel.contentView = content
        let width = content.bounds.width
        let height = content.bounds.height
        let carousel = WallpaperCarousel(frame: CGRect(x: 24, y: height * 0.30, width: width - 48, height: min(475, height * 0.53)))
        content.addSubview(carousel)
        self.carousel = carousel
        search.frame = CGRect(x: (width - min(480, width - 80)) / 2, y: height * 0.30 - 94, width: min(480, width - 80), height: 28)
        search.placeholderString = "Type to find a wallpaper…"
        search.stringValue = ""
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel("Find wallpaper by name or source")
        content.addSubview(search)
        caption.frame = CGRect(x: 30, y: height * 0.30 - 50, width: width - 60, height: 30)
        caption.alignment = .center
        caption.font = .systemFont(ofSize: 17, weight: .semibold)
        caption.textColor = .labelColor
        content.addSubview(caption)
        hint.frame = CGRect(x: 30, y: height * 0.30 - 131, width: width - 60, height: 22)
        hint.alignment = .center
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        hint.textColor = .secondaryLabelColor
        content.addSubview(hint)
        let browse = NSButton(title: "Open Wallpapers Folder  ⌘O", target: self, action: #selector(browse))
        browse.isBordered = false
        browse.attributedTitle = NSAttributedString(string: browse.title, attributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 13, weight: .medium)])
        browse.frame = CGRect(x: (width - 260) / 2, y: height * 0.30 - 174, width: 260, height: 28)
        content.addSubview(browse)
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(search)
        load()
    }

    private func load() {
        generation += 1
        let token = generation
        scanTask?.cancel()
        thumbnailQueue.cancelAllOperations()
        pending.removeAll()
        failed.removeAll()
        thumbnails.removeAllObjects()
        entries = []
        filtered = []
        carousel?.display(entries: [], selected: 0, image: { _ in nil }, select: { _ in })
        caption.stringValue = "Looking for local wallpapers…"
        hint.stringValue = "~/Pictures/Wallpapers · includes subfolders"
        do { try WallpaperLibrary.ensureFolder() }
        catch {
            caption.stringValue = "Cannot open Wallpapers folder: \(error.localizedDescription)"
            return
        }
        let task = Task.detached(priority: .userInitiated) {
            WallpaperLibrary.scan(roots: [(WallpaperLibrary.folder(), "Wallpapers")], cancelled: { Task.isCancelled })
        }
        scanTask = task
        Task { [weak self] in
            let result = await task.value
            guard let self, self.generation == token, self.panel != nil else { return }
            self.entries = result
            self.filter()
        }
    }

    func controlTextDidChange(_ obj: Notification) { filter() }

    private func filter() {
        let previous = filtered.indices.contains(selected) ? filtered[selected].url : NSScreen.main.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        filtered = entries.filter { $0.matches(search.stringValue) }
        selected = filtered.firstIndex(where: { $0.url == previous }) ?? 0
        render()
    }

    private func render() {
        guard let carousel else { return }
        carousel.display(entries: filtered, selected: selected, image: { [weak self] entry in
            self?.thumbnail(entry)
        }, select: { [weak self] index in
            guard let self else { return }
            if self.selected == index { self.apply() }
            else { self.selected = index; self.render() }
        })
        if filtered.indices.contains(selected) {
            let entry = filtered[selected]
            caption.stringValue = "\(entry.name)  ·  \(entry.source)\(entry.isVideo ? " · still frame" : "")"
            hint.attributedStringValue = WallpaperPickerStyle.selectionGuidance(selected: selected, count: filtered.count)
        } else {
            caption.stringValue = entries.isEmpty ? "Add images to ~/Pictures/Wallpapers, then reopen the picker" : "No matching wallpapers"
            hint.attributedStringValue = WallpaperPickerStyle.searchGuidance()
        }
    }

    private func thumbnail(_ entry: WallpaperEntry) -> NSImage? {
        if let image = thumbnails.object(forKey: entry.url as NSURL) { return image }
        guard !pending.contains(entry.url), !failed.contains(entry.url) else { return nil }
        pending.insert(entry.url)
        let token = generation
        thumbnailQueue.addOperation { [weak self] in
            let cgImage = try? WallpaperLibrary.image(at: entry.url, maxPixels: 1000)
            DispatchQueue.main.async {
                guard let self, self.generation == token, self.panel != nil else { return }
                self.pending.remove(entry.url)
                if let cgImage {
                    self.thumbnails.setObject(NSImage(cgImage: cgImage, size: .zero), forKey: entry.url as NSURL, cost: cgImage.bytesPerRow * cgImage.height)
                } else { self.failed.insert(entry.url) }
                self.render()
            }
        }
        thumbnails.totalCostLimit = 64 * 1024 * 1024
        return nil
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch NSStringFromSelector(commandSelector) {
        case "moveLeft:", "moveUp:", "insertBacktab:": move(-1)
        case "moveRight:", "moveDown:", "insertTab:": move(1)
        case "insertNewline:": apply()
        case "cancelOperation:":
            if search.stringValue.isEmpty { dismiss() }
            else { search.stringValue = ""; filter() }
        default: return false
        }
        return true
    }

    private func move(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        selected = (selected + delta + filtered.count) % filtered.count
        render()
    }

    @objc private func browse() {
        guard !applying else { return }
        do {
            let folder = try WallpaperLibrary.ensureFolder()
            if NSWorkspace.shared.open(folder) { dismiss() }
            else { caption.stringValue = "Could not open Wallpapers folder in Finder" }
        } catch {
            caption.stringValue = "Cannot open Wallpapers folder: \(error.localizedDescription)"
        }
    }

    private func apply() {
        guard !applying, filtered.indices.contains(selected) else { return }
        let entry = filtered[selected]
        applying = true
        caption.stringValue = "Preparing \(entry.name)…"
        let pixels = min(8192, Int(NSScreen.screens.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }.max() ?? 4096))
        applyTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Result { try WallpaperLibrary.prepare(entry, maxPixels: pixels) } }.value
            guard let self else { return }
            defer { self.applying = false; self.applyTask = nil }
            guard !Task.isCancelled else { return }
            do {
                let (url, image) = try result.get()
                self.dismiss(cancelApply: false)
                try await self.transition.apply(url: url, image: image)
                self.onStatus?("Wallpaper changed to \(entry.name)")
            } catch is CancellationError {
            } catch {
                self.onStatus?("Could not change wallpaper: \(error.localizedDescription)")
                let alert = NSAlert()
                alert.messageText = "Could not change wallpaper"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if !applying { dismiss() }
    }

    private func dismiss(cancelApply: Bool = true) {
        generation += 1
        scanTask?.cancel()
        scanTask = nil
        thumbnailQueue.cancelAllOperations()
        pending.removeAll()
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
        carousel = nil
        if cancelApply { applyTask?.cancel(); transition.stop() }
    }

    func cancel() { dismiss() }

    func stop() {
        dismiss()
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if let eventHandler { RemoveEventHandler(eventHandler); self.eventHandler = nil }
    }
}

private final class WallpaperPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    var onBrowse: (() -> Void)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "o" {
            onBrowse?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Omarchy-inspired carousel: expanded center image surrounded by overlapping slanted slices.
private final class WallpaperCarousel: NSView {
    private var cards: [URL: WallpaperCard] = [:]
    func display(entries: [WallpaperEntry], selected: Int, image: (WallpaperEntry) -> NSImage?, select: @escaping (Int) -> Void) {
        let indices = entries.indices.filter { abs($0 - selected) <= 6 }
        let visible = Set(indices.map { entries[$0].url })
        for url in Array(cards.keys) where !visible.contains(url) { cards.removeValue(forKey: url)?.removeFromSuperview() }
        let scale = min(1, bounds.height / 475, bounds.width / 1100)
        let expanded = 768 * scale
        let centerX = (bounds.width - expanded) / 2
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for index in indices {
                let entry = entries[index]
                let existing = cards[entry.url]
                let card = existing ?? WallpaperCard()
                if existing == nil { cards[entry.url] = card; addSubview(card) }
                card.image = image(entry)
                card.isSelected = index == selected
                card.onClick = { select(index) }
                card.setAccessibilityElement(true)
                card.setAccessibilityRole(.button)
                card.setAccessibilityLabel(entry.name)
                card.setAccessibilityValue(index == selected ? "Selected" : "")
                let relative = index - selected
                let x = relative == 0 ? centerX : relative < 0 ? centerX + CGFloat(relative) * 78 * scale : centerX + expanded - 30 * scale + CGFloat(relative - 1) * 78 * scale
                let height = (relative == 0 ? 475.0 : 432.0) * scale
                let frame = CGRect(x: x, y: (bounds.height - height) / 2, width: (relative == 0 ? 768 : 108) * scale, height: height)
                card.layer?.zPosition = relative == 0 ? 100 : CGFloat(50 - abs(relative))
                if existing == nil { card.frame = frame } else { card.animator().frame = frame }
                card.needsDisplay = true
            }
        }
    }
}

private final class WallpaperCard: NSView {
    var image: NSImage?
    var isSelected = false
    var onClick: (() -> Void)?
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func draw(_ dirtyRect: NSRect) {
        let inset = min(28, bounds.width * 0.12)
        let path = NSBezierPath()
        path.move(to: CGPoint(x: inset, y: 0))
        path.line(to: CGPoint(x: bounds.width, y: 0))
        path.line(to: CGPoint(x: bounds.width - inset, y: bounds.height))
        path.line(to: CGPoint(x: 0, y: bounds.height))
        path.close()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSColor(white: 0.13, alpha: 1).setFill()
        bounds.fill()
        if let image, image.size.width > 0, image.size.height > 0 {
            let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
        }
        if !isSelected { NSColor.black.withAlphaComponent(0.42).setFill(); bounds.fill() }
        NSColor.white.withAlphaComponent(isSelected ? 0.75 : 0.12).setStroke()
        path.lineWidth = isSelected ? 2 : 1
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}
