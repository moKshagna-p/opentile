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

/// Keep controls legible while letting the lower edge fade into the wallpaper.
final class SplitBarSurface: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(colorsAndLocations:
            (NSColor(calibratedWhite: 0, alpha: 0), 0),
            (NSColor(calibratedWhite: 0, alpha: 0.96), 0.3),
            (NSColor(calibratedWhite: 0, alpha: 1), 1))?
            .draw(in: bounds, angle: 90)
    }
}

enum SplitBarStyle {
    static let primary = NSColor(calibratedWhite: 0.93, alpha: 1)
    static let secondary = NSColor(calibratedWhite: 0.56, alpha: 1)
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    static var rounded: NSFont {
        let base = NSFont.systemFont(ofSize: 12, weight: .semibold)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 12) } ?? base
    }

    /// Values read bright and their labels or units dim, so the eye lands on the numbers.
    static func text(_ runs: [(String, Bool)]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (string, bright) in runs {
            result.append(NSAttributedString(string: string, attributes: [
                .font: font, .foregroundColor: bright ? primary : secondary]))
        }
        return result
    }

    /// "2.0 KB/s" -> bright number, dim unit.
    static func rate(_ arrow: String, _ value: String) -> [(String, Bool)] {
        let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
        return [(arrow + " ", false), (parts[0], true)] + (parts.count > 1 ? [(" " + parts[1], false)] : [])
    }
}

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}

/// Groups related status items into one capsule; it never takes clicks from the buttons above it.
final class SplitBarGroupBackground: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.075).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}

private class SplitBarStatusButton: NSButton {
    var styledTitle: NSAttributedString? {
        didSet { if let styledTitle { attributedTitle = styledTitle }; needsDisplay = true }
    }
    var imageTint: NSColor?
    private var hovered = false
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        if hovered || isHighlighted {
            let pill = bounds.insetBy(dx: 1, dy: 1)
            NSColor.white.withAlphaComponent(isHighlighted ? 0.16 : 0.09).setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        }
        // Drawing the cell here adds AppKit's larger grey pressed highlight over our capsule.
        let color = SplitBarStyle.primary
        let text = styledTitle ?? NSAttributedString(string: title, attributes: [
            .font: font ?? SplitBarStyle.font, .foregroundColor: color])
        let textSize = text.size()
        let imageSize = image?.size ?? .zero
        let imageWidth = image == nil ? 0 : min(25, imageSize.width)
        let spacing: CGFloat = image != nil && text.length > 0 ? 5 : 0
        let contentWidth = imageWidth + spacing + textSize.width
        var x = (bounds.width - contentWidth) / 2
        if let image {
            let height = imageSize.width > 0 ? min(18, imageSize.height * imageWidth / imageSize.width) : 0
            image.tinted(imageTint ?? color).draw(in: NSRect(x: x, y: (bounds.height - height) / 2,
                                                             width: imageWidth, height: height))
            x += imageWidth + spacing
        }
        text.draw(at: NSPoint(x: x, y: (bounds.height - textSize.height) / 2))
    }
}

enum SplitBarMenuVisual {
    case activity([Double])
    case level(Double)
    case day(Int)
    case none
}

/// A compact status card inside a native menu, leaving the actionable item to AppKit.
private final class SplitBarMenuHeader: NSView {
    private var visual: SplitBarMenuVisual
    private let icon: NSImageView
    private let iconPlate = NSView(frame: NSRect(x: 18, y: 18, width: 32, height: 32))
    private let heading: NSTextField
    private let detail: NSTextField
    private let valueLabel: NSTextField
    override var isFlipped: Bool { true }

    init(title: String, subtitle: String, symbol: String, value: String,
         visual: SplitBarMenuVisual, artwork: NSImage? = nil, logo: NSImage? = nil) {
        self.visual = visual
        icon = NSImageView(frame: NSRect(x: 7, y: 7, width: 18, height: 18))
        heading = NSTextField(labelWithString: title)
        detail = NSTextField(labelWithString: subtitle)
        valueLabel = NSTextField(labelWithString: value)
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 110))
        iconPlate.wantsLayer = true
        iconPlate.layer?.cornerRadius = 10
        iconPlate.layer?.masksToBounds = true
        iconPlate.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        addSubview(iconPlate)
        icon.contentTintColor = .labelColor
        icon.imageScaling = .scaleProportionallyUpOrDown
        iconPlate.addSubview(icon)
        setIcon(symbol: symbol, artwork: artwork, logo: logo)

        heading.frame = NSRect(x: 59, y: 19, width: 197, height: 16)
        heading.font = .systemFont(ofSize: 11, weight: .bold)
        heading.textColor = .labelColor
        addSubview(heading)

        detail.frame = NSRect(x: 59, y: 36, width: 197, height: 15)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.toolTip = subtitle
        addSubview(detail)

        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.toolTip = value
        addSubview(valueLabel)
        fitValue()
        setAccessibilityLabel("\(title), \(value), \(subtitle)")
    }

    func update(title: String, subtitle: String, symbol: String, value: String,
                visual: SplitBarMenuVisual, artwork: NSImage? = nil, logo: NSImage? = nil) {
        self.visual = visual
        setIcon(symbol: symbol, artwork: artwork, logo: logo)
        heading.stringValue = title
        detail.stringValue = subtitle
        detail.toolTip = subtitle
        valueLabel.stringValue = value
        valueLabel.toolTip = value
        fitValue()
        setAccessibilityLabel("\(title), \(value), \(subtitle)")
        needsDisplay = true
    }

    required init?(coder: NSCoder) { nil }

    /// Long values (track titles) step down from 24pt to 15pt before truncating,
    /// and take the full card width when there is no graphic beside them.
    private func fitValue() {
        let width: CGFloat = { if case .none = visual { return 244 } else { return 163 } }()
        var size: CGFloat = 24
        while size > 15, (valueLabel.stringValue as NSString).size(withAttributes:
                [.font: NSFont.systemFont(ofSize: size, weight: .semibold)]).width > width {
            size -= 1
        }
        valueLabel.font = .systemFont(ofSize: size, weight: .semibold)
        valueLabel.frame = NSRect(x: 18, y: 62, width: width, height: 32)
    }

    /// Artwork fills the plate edge to edge; a symbol sits centered inside it.
    private func setIcon(symbol: String, artwork: NSImage?, logo: NSImage?) {
        icon.image = artwork ?? logo ?? NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.frame = artwork == nil ? NSRect(x: 7, y: 7, width: 18, height: 18) : iconPlate.bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.045).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 7, dy: 7), xRadius: 13, yRadius: 13).fill()
        NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 7.5, dy: 7.5), xRadius: 13, yRadius: 13).stroke()

        switch visual {
        case .activity(let samples):
            let recent = Array(samples.suffix(18))
            for index in 0..<18 {
                let sample = index >= 18 - recent.count ? recent[index - (18 - recent.count)] : 0
                let height = 4 + 24 * min(1, max(0, sample))
                NSColor.labelColor.withAlphaComponent(sample > 0.02 ? 0.7 : 0.16).setFill()
                NSBezierPath(roundedRect: NSRect(x: 186 + CGFloat(index) * 4.1, y: 86 - height,
                                                width: 2.5, height: height), xRadius: 1.25, yRadius: 1.25).fill()
            }
        case .level(let fraction):
            let filled = Int((min(1, max(0, fraction)) * 10).rounded())
            for index in 0..<10 {
                NSColor.labelColor.withAlphaComponent(index < filled ? 0.7 : 0.16).setFill()
                NSBezierPath(roundedRect: NSRect(x: 187 + CGFloat(index) * 7.2, y: 75,
                                                width: 5, height: 11), xRadius: 2.5, yRadius: 2.5).fill()
            }
        case .day(let day):
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: NSRect(x: 210, y: 63, width: 48, height: 29), xRadius: 8, yRadius: 8).fill()
            (String(day) as NSString).draw(in: NSRect(x: 210, y: 66, width: 48, height: 23),
                withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 17, weight: .semibold),
                                 .foregroundColor: NSColor.labelColor, .paragraphStyle: centeredText])
        case .none:
            break
        }
    }

    private var centeredText: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return style
    }
}

private final class SplitBarMetricRow: NSView {
    private let label: NSTextField
    private let metric: NSTextField
    private let icon = NSImageView(frame: NSRect(x: 20, y: 6, width: 16, height: 16))
    init(title: String, value: String, symbol: String, image: NSImage? = nil) {
        label = NSTextField(labelWithString: title)
        metric = NSTextField(labelWithString: value)
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 29))
        icon.image = image ?? NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .secondaryLabelColor
        addSubview(icon)

        label.frame = NSRect(x: 45, y: 5, width: 104, height: 18)
        label.font = .systemFont(ofSize: 12)
        addSubview(label)

        metric.frame = NSRect(x: 151, y: 5, width: 107, height: 18)
        metric.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        metric.alignment = .right
        metric.lineBreakMode = .byTruncatingTail
        metric.toolTip = value
        addSubview(metric)
        setAccessibilityLabel("\(title), \(value)")
    }

    func update(title: String, value: String, image: NSImage? = nil) {
        if let image { icon.image = image }
        label.stringValue = title
        metric.stringValue = value
        metric.toolTip = value
        setAccessibilityLabel("\(title), \(value)")
    }

    required init?(coder: NSCoder) { nil }
}

enum SplitBarDropdown {
    struct Detail {
        let title: String
        let value: String
        let symbol: String
        var image: NSImage? = nil
    }

    @MainActor static func make(title: String, subtitle: String, symbol: String,
                                value: String, visual: SplitBarMenuVisual, artwork: NSImage? = nil,
                                logo: NSImage? = nil, details: [Detail], extraViews: [NSView] = [], settingsTitle: String,
                                settingsAction: Selector, target: AnyObject) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let header = NSMenuItem()
        header.view = SplitBarMenuHeader(title: title, subtitle: subtitle, symbol: symbol,
                                         value: value, visual: visual, artwork: artwork, logo: logo)
        menu.addItem(header)
        menu.addItem(.separator())
        for detail in details {
            let item = NSMenuItem()
            item.view = SplitBarMetricRow(title: detail.title, value: detail.value,
                                           symbol: detail.symbol, image: detail.image)
            menu.addItem(item)
        }
        for view in extraViews {
            let item = NSMenuItem()
            item.view = view
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let settings = menu.addItem(withTitle: settingsTitle, action: settingsAction, keyEquivalent: "")
        settings.target = target
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        return menu
    }

    @MainActor static func update(_ menu: NSMenu, title: String, subtitle: String, symbol: String,
                                  value: String, visual: SplitBarMenuVisual, artwork: NSImage? = nil,
                                  logo: NSImage? = nil, details: [Detail]) {
        (menu.items.first?.view as? SplitBarMenuHeader)?.update(
            title: title, subtitle: subtitle, symbol: symbol, value: value, visual: visual,
            artwork: artwork, logo: logo)
        for (item, detail) in zip(menu.items.dropFirst(2), details) {
            (item.view as? SplitBarMetricRow)?.update(title: detail.title, value: detail.value, image: detail.image)
        }
    }
}

/// Traffic rates in fixed columns: numbers right-aligned, units left-aligned, so nothing shifts as rates change.
private final class TrafficBarButton: SplitBarStatusButton {
    var down = "0 B/s" { didSet { needsDisplay = true } }
    var up = "0 B/s" { didSet { needsDisplay = true } }
    private static func width(_ string: String) -> CGFloat {
        ceil((string as NSString).size(withAttributes: [.font: SplitBarStyle.font]).width)
    }
    private static let arrow = width("↓ ")
    private static let number = width("999.9")
    private static let unit = width(" KB/s")
    private static let gap: CGFloat = 10
    static let contentWidth = 2 * (arrow + number + unit) + gap

    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted {
            let pill = bounds.insetBy(dx: 1, dy: 1)
            NSColor.white.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        }
        var x = (bounds.width - Self.contentWidth) / 2
        for (arrow, rate) in [("↓", down), ("↑", up)] {
            let parts = rate.split(separator: " ", maxSplits: 1).map(String.init)
            func draw(_ string: String, bright: Bool, at origin: CGFloat) {
                let text = SplitBarStyle.text([(string, bright)])
                text.draw(at: NSPoint(x: origin, y: (bounds.height - text.size().height) / 2))
            }
            draw(arrow, bright: false, at: x)
            x += Self.arrow
            let number = parts.first ?? ""
            draw(number, bright: true, at: x + Self.number - Self.width(number))
            x += Self.number
            draw(" " + (parts.count > 1 ? parts[1] : ""), bright: false, at: x)
            x += Self.unit + Self.gap
        }
    }
}

/// The selection lives behind the buttons so it can move without replacing the row.
final class WorkspaceBarSelection: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.white.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        NSColor.white.withAlphaComponent(0.1).setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5).stroke()
    }
}

/// Draw icons directly so the selection never recolors application logos.
final class WorkspaceBarButton: NSButton {
    var appIcons: [NSImage] = []
    var active = false
    private var hovered = false
    private var hoverArea: NSTrackingArea?
    var preferredWidth: CGFloat {
        let labelWidth = (title as NSString).size(withAttributes: [.font: font!]).width
        return max(30, ceil(labelWidth) + 16 + CGFloat(appIcons.count) * 22)
    }

    override func updateTrackingAreas() {
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        if hovered || isHighlighted {
            let pill = bounds.insetBy(dx: 1, dy: 1)
            NSColor.white.withAlphaComponent(isHighlighted ? 0.11 : active ? 0.045 : 0.075).setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font!, .foregroundColor: active ? NSColor.white : SplitBarStyle.secondary
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: 9, y: (bounds.height - size.height) / 2), withAttributes: attributes)
        var x = ceil(size.width) + 13
        for icon in appIcons {
            icon.draw(in: NSRect(x: x, y: (bounds.height - 20) / 2, width: 20, height: 20),
                      from: .zero, operation: .sourceOver, fraction: active ? 1 : 0.8, respectFlipped: true, hints: nil)
            x += 22
        }
    }
}

@MainActor final class WorkspaceBarContent: NSView {
    private let selection = WorkspaceBarSelection(frame: .zero)
    private var buttons: [String: WorkspaceBarButton] = [:]
    private var focusedName: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        selection.isHidden = true
        addSubview(selection)
    }
    required init?(coder: NSCoder) { nil }

    @discardableResult
    func update(_ workspaces: [OpenTileWorkspaceSummary], icons: [String: NSImage],
                target: AnyObject, action: Selector, in scroll: NSScrollView) -> CGFloat {
        let names = Set(workspaces.map(\.name))
        for (name, button) in buttons where !names.contains(name) {
            button.removeFromSuperview()
            buttons.removeValue(forKey: name)
        }

        var x: CGFloat = 10
        for workspace in workspaces {
            let button = buttons[workspace.name] ?? WorkspaceBarButton(title: workspace.name, target: target, action: action)
            if buttons[workspace.name] == nil {
                button.isBordered = false
                button.font = SplitBarStyle.rounded
                button.identifier = NSUserInterfaceItemIdentifier(workspace.name)
                buttons[workspace.name] = button
                addSubview(button)
            }
            button.appIcons = workspace.applicationBundlePaths.compactMap { icons[$0] }
            button.active = workspace.isFocused
            button.toolTip = "\(workspace.name) — \(workspace.windowCount) windows\n\(workspace.applications.joined(separator: ", "))"
            button.setAccessibilityLabel("Workspace \(workspace.name)\(workspace.isFocused ? ", active" : ""), \(workspace.applications.joined(separator: ", "))")
            button.frame = CGRect(x: x, y: 3, width: button.preferredWidth, height: 22)
            button.needsDisplay = true
            x += button.frame.width + 4
        }

        let contentWidth = x + 6
        let layout = WorkspaceBarLayout(width: scroll.superview?.bounds.width ?? scroll.bounds.width,
                                        contentWidth: contentWidth)
        scroll.frame.size.width = layout.workspaceWidth
        frame = CGRect(x: 0, y: 0, width: max(contentWidth, scroll.bounds.width), height: 28)

        let nextFocusedName = workspaces.first(where: \.isFocused)?.name
        if let nextFocusedName, let button = buttons[nextFocusedName] {
            let shouldAnimate = focusedName != nil && focusedName != nextFocusedName
                && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            selection.isHidden = false
            let targetFrame = button.frame
            let clip = scroll.contentView
            let visible = clip.bounds
            var origin = visible.minX
            if targetFrame.minX < visible.minX + 8 {
                origin = targetFrame.minX - 8
            } else if targetFrame.maxX > visible.maxX - 8 {
                origin = targetFrame.maxX - visible.width + 8
            }
            origin = min(max(0, origin), max(0, frame.width - visible.width))
            if shouldAnimate {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.28
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.8, 0.25, 1)
                    selection.animator().frame = targetFrame
                    clip.animator().setBoundsOrigin(NSPoint(x: origin, y: 0))
                }
            } else {
                selection.frame = targetFrame
                clip.setBoundsOrigin(NSPoint(x: origin, y: 0))
            }
        } else {
            selection.isHidden = true
        }
        focusedName = nextFocusedName
        return contentWidth
    }

    var selectionFrame: NSRect { selection.frame }
    func button(named name: String) -> WorkspaceBarButton? { buttons[name] }
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
    private var trafficButtons: [TrafficBarButton] = []
    private var pomodoro: Pomodoro = {
        var timer = Pomodoro()
        let defaults = UserDefaults.standard
        for (key, path) in [("pomodoroFocusMinutes", \Pomodoro.focusLength),
                            ("pomodoroShortBreakMinutes", \Pomodoro.shortBreakLength),
                            ("pomodoroLongBreakMinutes", \Pomodoro.longBreakLength)] {
            let minutes = defaults.integer(forKey: key)
            if minutes > 0 { timer[keyPath: path] = TimeInterval(minutes * 60) }
        }
        return timer
    }()
    private var pomodoroSound: Bool {
        get { UserDefaults.standard.object(forKey: "pomodoroSound") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "pomodoroSound") }
    }
    private var pomodoroTimer: Timer?
    private var pomodoroButtons: [SplitBarStatusButton] = []
    private var network: NWPathMonitor?
    private var powerSource: CFRunLoopSource?
    private var audioListener: AudioObjectPropertyListenerBlock?
    private var audioDevice: AudioDeviceID = 0
    private var state: OpenTileBarState?
    private var renderedStatus: String?
    private var appIcons: [String: NSImage] = [:]
    private var wifi = false
    private var networkConnected = false
    private var downloadRate = "0 B/s"
    private var uploadRate = "0 B/s"
    private var trafficHistory: [Double] = []
    private var soundLevel: Int?
    private var soundMuted = false
    private var batteryLevel: String?
    private var batteryCharging = false
    private var batteryFill = 0.0
    private var showingStatusMenu = false
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
    private let dayFormat: DateFormatter = {
        let format = DateFormatter()
        format.dateFormat = "EEE"
        return format
    }()
    private let clockTimeFormat: DateFormatter = {
        let format = DateFormatter()
        format.dateFormat = "HH:mm"
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
        renderedStatus = nil
        codexButtons.forEach { $0.closeDetails() }
        codexButtons.removeAll()
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
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.contentView = SplitBarSurface(frame: panel.contentView!.bounds)
        return panel
    }

    private func button(_ title: String, symbol: String? = nil, action: Selector) -> SplitBarStatusButton {
        let button = SplitBarStatusButton(title: title, target: self, action: action)
        button.isBordered = false
        button.font = SplitBarStyle.font
        button.contentTintColor = SplitBarStyle.primary
        if let symbol { button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title); button.imagePosition = .imageLeading }
        return button
    }

    private func renderWorkspaces() {
        guard running else { return }
        let workspaces = (state?.workspaces ?? openTileWorkspaces()).filter {
            WorkspaceBarLayout.showsWorkspace(windowCount: $0.windowCount, isFocused: $0.isFocused)
        }
        let paths = Set(workspaces.flatMap(\.applicationBundlePaths))
        appIcons = appIcons.filter { paths.contains($0.key) }
        for path in paths where appIcons[path] == nil {
            appIcons[path] = NSWorkspace.shared.icon(forFile: path)
        }
        codexButtons.removeAll()
        for (index, pair) in panels.enumerated() {
            let hidden = sleeping || state?.fullscreenScreenIndices.contains(index + 1) == true
            if hidden { pair.left.orderOut(nil); pair.right.orderOut(nil) }
            else { pair.left.orderFrontRegardless(); pair.right.orderFrontRegardless() }
            let container = pair.left.contentView!
            let scroll = (container.subviews.first { $0 is NSScrollView } as? NSScrollView) ?? {
                let view = NSScrollView(frame: container.bounds)
                view.autoresizingMask = [.width, .height]
                view.drawsBackground = false
                view.hasHorizontalScroller = false
                view.documentView = WorkspaceBarContent(frame: container.bounds)
                container.addSubview(view)
                return view
            }()
            let content = scroll.documentView as! WorkspaceBarContent
            let contentWidth = content.update(workspaces, icons: appIcons, target: self,
                                              action: #selector(workspaceClicked), in: scroll)
            let layout = WorkspaceBarLayout(width: container.bounds.width, contentWidth: contentWidth)
            if layout.statusWidth > 0 {
                let usage = (container.subviews.first { $0 is CodexBarButton } as? CodexBarButton)
                    ?? CodexBarButton(status: codexBar)
                let width = layout.statusWidth >= 60 ? min(layout.statusWidth, usage.preferredWidth) : layout.statusWidth
                usage.frame = CGRect(x: container.bounds.width - width - 6, y: 3, width: width, height: 22)
                usage.update()
                if usage.superview == nil { container.addSubview(usage) }
                codexButtons.append(usage)
            } else if let usage = container.subviews.first(where: { $0 is CodexBarButton }) as? CodexBarButton {
                usage.closeDetails()
                usage.removeFromSuperview()
            }
        }
    }

    @objc private func workspaceClicked(_ sender: NSButton) {
        if let name = sender.identifier?.rawValue { selectWorkspace?(name) }
    }

    private func startStatus() {
        stopStatus()
        let version = generation
        // Re-layout, not just redraw: the capsule hugs the active provider's name and percentage.
        codexBar.onChange = { [weak self] in self?.renderWorkspaces() }
        codexBar.start()
        if musicItem?.state == .on { music.start() }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.status == .satisfied && path.usesInterfaceType(.wifi)
            DispatchQueue.main.async {
                guard let self, self.running, self.generation == version else { return }
                self.wifi = wifi
                self.networkConnected = path.status == .satisfied
                self.renderStatus()
            }
        }
        network = monitor
        monitor.start(queue: DispatchQueue(label: "OpenTile.menuBar.network", qos: .utility))
        schedulePomodoro()
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
        // Volume is read only when CoreAudio reports a change: battery updates
        // re-render the bar often, and each read is a round trip to the audio server.
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.running, self.generation == version else { return }
            self.observeAudioDevice()
            self.sampleSound()
            self.renderStatus()
        }
        audioListener = listener
        var address = Self.audioAddress(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        observeAudioDevice()
        sampleSound()
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
        downloadRate = NetworkTraffic.format(rates.down)
        uploadRate = NetworkTraffic.format(rates.up)
        trafficHistory.append(min(1, log10(max(0, rates.down + rates.up) + 1) / 6))
        if trafficHistory.count > 18 { trafficHistory.removeFirst(trafficHistory.count - 18) }
        let text = "↓ \(downloadRate)  ↑ \(uploadRate)"
        guard text != trafficText else { return }
        trafficText = text
        for button in trafficButtons {
            button.down = downloadRate
            button.up = uploadRate
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
        trafficHistory.removeAll()
        trafficButtons.removeAll()
        pomodoroTimer?.invalidate(); pomodoroTimer = nil
        pomodoroButtons.removeAll()
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

    private func sampleSound() {
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: volume))
        var address = Self.audioAddress(kAudioDevicePropertyVolumeScalar, output: true)
        let hasVolume = AudioObjectGetPropertyData(audioDevice, &address, 0, nil, &size, &volume) == noErr
        var muted: UInt32 = 0
        size = UInt32(MemoryLayout.size(ofValue: muted))
        address = Self.audioAddress(kAudioDevicePropertyMute, output: true)
        _ = AudioObjectGetPropertyData(audioDevice, &address, 0, nil, &size, &muted)
        soundLevel = hasVolume ? Int(volume * 100) : nil
        soundMuted = muted != 0
    }

    private func renderStatus() {
        guard running, !sleeping else { return }
        var battery: String?
        var batteryFraction: Double = 0
        var charging = false
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                      let current = description[kIOPSCurrentCapacityKey] as? Int,
                      let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
                batteryFraction = BatteryIndicator.fraction(current: current, maximum: maximum)
                charging = description[kIOPSIsChargingKey] as? Bool == true
                battery = "\(Int((batteryFraction * 100).rounded()))%" + (charging ? " +" : "")
            }
        }
        let clock = clockFormat.string(from: Date())
        let sound = soundMuted ? "Muted" : soundLevel.map { "\($0)%" } ?? "Sound"
        batteryLevel = battery
        batteryCharging = charging
        batteryFill = batteryFraction
        let presentation = "\(wifi)|\(sound)|\(battery ?? "")|\(clock)|\(pomodoro.phase)|\(pomodoro.running)"
        guard !showingStatusMenu else { return }
        guard renderedStatus != presentation else { return }
        renderedStatus = presentation
        trafficButtons.removeAll()
        pomodoroButtons.removeAll()
        for pair in panels {
            let view = pair.right.contentView!
            let existingMusic = view.subviews.compactMap { $0 as? MusicBarView }.first
            view.subviews.filter { !($0 is MusicBarView) }.forEach { $0.removeFromSuperview() }
            let networkButton = button("", symbol: wifi ? "wifi" : "network", action: #selector(showNetworkMenu(_:)))
            networkButton.toolTip = wifi ? "Wi-Fi details" : "Network details"
            networkButton.setAccessibilityLabel(networkButton.toolTip)
            let trafficButton = TrafficBarButton(title: "", target: self, action: #selector(showNetworkMenu(_:)))
            trafficButton.isBordered = false
            trafficButton.down = downloadRate
            trafficButton.up = uploadRate
            trafficButton.toolTip = "Download / upload over Wi-Fi and Ethernet"
            trafficButton.setAccessibilityLabel(trafficText)
            trafficButtons.append(trafficButton)
            let soundButton = button("", symbol: soundMuted ? "speaker.slash" : "speaker.wave.2", action: #selector(showSoundMenu(_:)))
            soundButton.toolTip = sound
            soundButton.setAccessibilityLabel("Sound: \(sound)")
            if soundMuted { soundButton.imageTint = SplitBarStyle.secondary }
            var power: [NSButton] = [soundButton]
            if let battery {
                let batteryButton = button(battery, action: #selector(showBatteryMenu(_:)))
                batteryButton.styledTitle = SplitBarStyle.text([("\(Int((batteryFraction * 100).rounded()))%", true)])
                batteryButton.image = BatteryIndicator.image(fraction: batteryFraction)
                batteryButton.imagePosition = .imageLeading
                batteryButton.imageTint = charging ? .systemGreen : batteryFraction <= 0.2 ? .systemRed : nil
                batteryButton.setAccessibilityLabel("Battery \(battery)")
                power.append(batteryButton)
            }
            let clockButton = button(clock, action: #selector(showClockMenu(_:)))
            let now = Date()
            clockButton.styledTitle = SplitBarStyle.text([(dayFormat.string(from: now) + "  ", false),
                                                          (clockTimeFormat.string(from: now), true)])
            let pomodoroButton = button("", symbol: "timer", action: #selector(showPomodoroMenu(_:)))
            if pomodoro.phase != .idle {
                pomodoroButton.styledTitle = pomodoroText(Date())
                pomodoroButton.imageTint = pomodoro.phase == .focus ? .systemRed : .systemGreen
            }
            pomodoroButton.toolTip = "Pomodoro timer"
            pomodoroButton.setAccessibilityLabel("Pomodoro timer")
            pomodoroButtons.append(pomodoroButton)
            let appButton = button("", symbol: "square.grid.2x2", action: #selector(showMenu))
            appButton.setAccessibilityLabel("OpenTile menu")
            appButton.toolTip = "OpenTile menu"
            // Related items share a capsule; groups are separated by a gap rather than dividers.
            let groups: [[NSButton]] = [[pomodoroButton], [networkButton, trafficButton], power, [clockButton], [appButton]]
            var x = view.bounds.width - 6
            for group in groups.reversed() {
                let capsule = group.first !== appButton
                let inset: CGFloat = capsule ? 5 : 0
                let groupEnd = x
                x -= inset
                var placed = false
                for b in group.reversed() {
                    let width = b === trafficButton ? TrafficBarButton.contentWidth + 8 : Self.contentWidth(b) + 14
                    guard x - width - inset >= 0 else { continue }
                    if placed { x -= 2 }
                    x -= width
                    b.frame = CGRect(x: x, y: 3, width: width, height: 22)
                    view.addSubview(b)
                    placed = true
                }
                x -= inset
                if placed, capsule {
                    view.addSubview(SplitBarGroupBackground(frame: CGRect(x: x, y: 3, width: groupEnd - x, height: 22)),
                                    positioned: .below, relativeTo: nil)
                }
                if !placed { x = groupEnd } else { x -= 8 }
            }
            if musicItem?.state == .on, x >= MusicBarView.width + 8 {
                let musicView = existingMusic ?? MusicBarView(player: music)
                musicView.frame.origin.x = x - MusicBarView.width
                if musicView.superview == nil { view.addSubview(musicView) }
            }
            if musicItem?.state != .on || x < MusicBarView.width + 8 { existingMusic?.removeFromSuperview() }
        }
    }

    /// Width of an item's icon and text, without padding.
    private static func contentWidth(_ button: NSButton) -> CGFloat {
        let text = (button as? SplitBarStatusButton)?.styledTitle?.size().width
            ?? (button.title as NSString).size(withAttributes: [.font: button.font ?? SplitBarStyle.font]).width
        let image = button.image.map { min(25, $0.size.width) } ?? 0
        return ceil(image + text + (image > 0 && text > 0 ? 5 : 0))
    }

    // MARK: Pomodoro

    private func pomodoroText(_ now: Date) -> NSAttributedString {
        SplitBarStyle.text([(Pomodoro.clock(pomodoro.remaining(at: now)), pomodoro.running)])
    }

    /// Ticks once a second only while a phase is counting down.
    private func schedulePomodoro() {
        pomodoroTimer?.invalidate(); pomodoroTimer = nil
        guard pomodoro.running, running, !sleeping else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickPomodoro() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        pomodoroTimer = timer
    }

    private func tickPomodoro() {
        let now = Date()
        if pomodoro.running, pomodoro.remaining(at: now) <= 0 {
            let finishedFocus = pomodoro.phase == .focus
            pomodoro.finish(at: now)
            if pomodoroSound { NSSound(named: finishedFocus ? "Glass" : "Hero")?.play() }
            schedulePomodoro()
            renderStatus()
            return
        }
        let text = pomodoroText(now)
        pomodoroButtons.forEach { $0.styledTitle = text }
    }

    private var pomodoroHeading: String {
        switch pomodoro.phase {
        case .idle: "POMODORO"
        case .focus: "FOCUS"
        case .shortBreak: "SHORT BREAK"
        case .longBreak: "LONG BREAK"
        }
    }

    private func refreshPomodoroMenu(_ menu: NSMenu) {
        let now = Date()
        let subtitle = pomodoro.phase == .idle
            ? "\(Int(pomodoro.focusLength / 60)) min focus · \(Int(pomodoro.shortBreakLength / 60)) min break"
            : pomodoro.endsAt.map { "Ends at \(clockTimeFormat.string(from: $0))" } ?? "Paused"
        let next = pomodoro.phase == .focus
            ? ((pomodoro.completedFocus + 1).isMultiple(of: 4) ? "Long break" : "Short break") : "Focus"
        SplitBarDropdown.update(menu, title: pomodoroHeading, subtitle: subtitle, symbol: "timer",
            value: Pomodoro.clock(pomodoro.remaining(at: now)), visual: .level(pomodoro.progress(at: now)),
            details: [.init(title: "Sessions done", value: "\(pomodoro.completedFocus)", symbol: "checkmark.circle"),
                      .init(title: "Up next", value: next, symbol: "arrow.forward.circle")])
        if let primary = menu.item(withTag: 1) {
            primary.title = pomodoro.running ? "Pause" : pomodoro.phase == .idle ? "Start Focus" : "Resume"
            primary.image = NSImage(systemSymbolName: pomodoro.running ? "pause.fill" : "play.fill", accessibilityDescription: nil)
        }
        menu.item(withTag: 2)?.isEnabled = pomodoro.phase != .idle
    }

    @objc private func showPomodoroMenu(_ sender: NSButton) {
        let menu = SplitBarDropdown.make(title: pomodoroHeading, subtitle: "", symbol: "timer", value: "",
            visual: .level(0), details: [.init(title: "Sessions done", value: "", symbol: "checkmark.circle"),
                                         .init(title: "Up next", value: "", symbol: "arrow.forward.circle")],
            settingsTitle: "Start Focus", settingsAction: #selector(togglePomodoro), target: self)
        menu.items.last?.tag = 1
        let reset = menu.addItem(withTitle: "Reset", action: #selector(resetPomodoro), keyEquivalent: "")
        reset.target = self
        reset.tag = 2
        reset.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: nil)
        menu.addItem(.separator())
        let settings = menu.addItem(withTitle: "Timer Settings", action: nil, keyEquivalent: "")
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        let options = NSMenu()
        for (kind, title, choices, current) in [
            (1, "Focus", [15, 20, 25, 30, 45, 50, 60], pomodoro.focusLength),
            (2, "Short Break", [3, 5, 10, 15], pomodoro.shortBreakLength),
            (3, "Long Break", [10, 15, 20, 30], pomodoro.longBreakLength)
        ] {
            let minutes = Int(current / 60)
            let item = options.addItem(withTitle: "\(title) — \(minutes) min", action: nil, keyEquivalent: "")
            let lengths = NSMenu()
            for choice in choices {
                let option = lengths.addItem(withTitle: "\(choice) minutes", action: #selector(setPomodoroLength(_:)), keyEquivalent: "")
                option.target = self
                option.tag = kind * 1000 + choice
                option.state = choice == minutes ? .on : .off
            }
            item.submenu = lengths
        }
        options.addItem(.separator())
        let sound = options.addItem(withTitle: "Play Sound When a Phase Ends", action: #selector(togglePomodoroSound), keyEquivalent: "")
        sound.target = self
        sound.state = pomodoroSound ? .on : .off
        settings.submenu = options
        showStatus(menu, from: sender) { [weak self] in self?.refreshPomodoroMenu(menu) }
    }

    @objc private func togglePomodoro() {
        if pomodoro.running { pomodoro.pause(at: Date()) } else { pomodoro.start(at: Date()) }
        schedulePomodoro()
        renderStatus()
    }

    @objc private func setPomodoroLength(_ sender: NSMenuItem) {
        let minutes = sender.tag % 1000
        let (key, path) = [1: ("pomodoroFocusMinutes", \Pomodoro.focusLength),
                           2: ("pomodoroShortBreakMinutes", \Pomodoro.shortBreakLength),
                           3: ("pomodoroLongBreakMinutes", \Pomodoro.longBreakLength)][sender.tag / 1000]!
        pomodoro[keyPath: path] = TimeInterval(minutes * 60)
        UserDefaults.standard.set(minutes, forKey: key)
        renderedStatus = nil
        renderStatus()
    }

    @objc private func togglePomodoroSound() { pomodoroSound.toggle() }

    @objc private func resetPomodoro() {
        pomodoro.reset()
        schedulePomodoro()
        renderStatus()
    }

    private func show(_ menu: NSMenu, from sender: NSButton) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: sender)
    }

    private func showStatus(_ menu: NSMenu, from sender: NSButton, refresh: @escaping () -> Void) {
        showingStatusMenu = true
        refresh()
        let liveTimer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { refresh() }
        }
        RunLoop.main.add(liveTimer, forMode: .common)
        defer {
            liveTimer.invalidate()
            showingStatusMenu = false
            renderStatus()
        }
        show(menu, from: sender)
    }

    @objc private func showMenu(_ sender: NSButton) {
        if let menu { show(menu, from: sender) }
    }

    @objc private func showNetworkMenu(_ sender: NSButton) {
        let subtitle = wifi ? "Wi-Fi connection" : (networkConnected ? "Wired connection" : "Check your connection")
        let menu = SplitBarDropdown.make(title: "NETWORK", subtitle: subtitle, symbol: wifi ? "wifi" : "network",
            value: networkConnected ? "Connected" : "Offline", visual: .activity(trafficHistory),
            details: [.init(title: "Download", value: downloadRate, symbol: "arrow.down"),
                      .init(title: "Upload", value: uploadRate, symbol: "arrow.up")],
            settingsTitle: "Open Network Settings…", settingsAction: #selector(networkSettings), target: self)
        showStatus(menu, from: sender) { [weak self] in
            guard let self else { return }
            let subtitle = self.wifi ? "Wi-Fi connection" : (self.networkConnected ? "Wired connection" : "Check your connection")
            SplitBarDropdown.update(menu, title: "NETWORK", subtitle: subtitle,
                symbol: self.wifi ? "wifi" : "network", value: self.networkConnected ? "Connected" : "Offline",
                visual: .activity(self.trafficHistory),
                details: [.init(title: "Download", value: self.downloadRate, symbol: "arrow.down"),
                          .init(title: "Upload", value: self.uploadRate, symbol: "arrow.up")])
        }
    }

    @objc private func showSoundMenu(_ sender: NSButton) {
        let subtitle = soundMuted ? "Output is muted" : "Output volume"
        let value = soundMuted ? "Muted" : soundLevel.map { "\($0)%" } ?? "Unavailable"
        let menu = SplitBarDropdown.make(title: "SOUND", subtitle: subtitle,
            symbol: soundMuted ? "speaker.slash" : "speaker.wave.2",
            value: value, visual: .level(soundMuted ? 0 : Double(soundLevel ?? 0) / 100),
            details: [.init(title: "Volume", value: soundLevel.map { "\($0)%" } ?? "Unavailable",
                            symbol: "speaker.wave.2")],
            settingsTitle: "Open Sound Settings…", settingsAction: #selector(soundSettings), target: self)
        showStatus(menu, from: sender) { [weak self] in
            guard let self else { return }
            self.sampleSound()
            let value = self.soundMuted ? "Muted" : self.soundLevel.map { "\($0)%" } ?? "Unavailable"
            SplitBarDropdown.update(menu, title: "SOUND",
                subtitle: self.soundMuted ? "Output is muted" : "Output volume",
                symbol: self.soundMuted ? "speaker.slash" : "speaker.wave.2", value: value,
                visual: .level(self.soundMuted ? 0 : Double(self.soundLevel ?? 0) / 100),
                details: [.init(title: "Volume", value: self.soundLevel.map { "\($0)%" } ?? "Unavailable",
                                symbol: "speaker.wave.2")])
        }
    }

    @objc private func showBatteryMenu(_ sender: NSButton) {
        let level = batteryLevel ?? "Battery unavailable"
        let menu = SplitBarDropdown.make(title: "BATTERY", subtitle: batteryCharging ? "Charging" : "On battery power",
            symbol: batteryCharging ? "bolt.fill" : "battery.100percent",
            value: batteryCharging ? String(level.dropLast(2)) : level,
            visual: .level(batteryFill),
            details: [.init(title: "Charge", value: batteryCharging ? String(level.dropLast(2)) : level,
                            symbol: "battery.100percent")],
            settingsTitle: "Open Battery Settings…", settingsAction: #selector(batterySettings), target: self)
        showStatus(menu, from: sender) { [weak self] in
            guard let self else { return }
            let level = self.batteryLevel ?? "Battery unavailable"
            let display = self.batteryCharging ? String(level.dropLast(2)) : level
            SplitBarDropdown.update(menu, title: "BATTERY",
                subtitle: self.batteryCharging ? "Charging" : "On battery power",
                symbol: self.batteryCharging ? "bolt.fill" : "battery.100percent", value: display,
                visual: .level(self.batteryFill),
                details: [.init(title: "Charge", value: display, symbol: "battery.100percent")])
        }
    }

    @objc private func showClockMenu(_ sender: NSButton) {
        let now = Date()
        let date = now.formatted(.dateTime.weekday(.wide).month(.wide).day())
        let time = clockTimeFormat.string(from: now)
        let zone = TimeZone.current.abbreviation(for: now) ?? TimeZone.current.identifier
        let menu = SplitBarDropdown.make(title: "TODAY", subtitle: date, symbol: "calendar",
            value: time, visual: .day(Calendar.current.component(.day, from: now)),
            details: [.init(title: "Time zone", value: zone, symbol: "globe")],
            settingsTitle: "Open Date & Time Settings…", settingsAction: #selector(clockSettings), target: self)
        showStatus(menu, from: sender) { [weak self] in
            guard let self else { return }
            let now = Date()
            SplitBarDropdown.update(menu, title: "TODAY",
                subtitle: now.formatted(.dateTime.weekday(.wide).month(.wide).day()), symbol: "calendar",
                value: self.clockTimeFormat.string(from: now),
                visual: .day(Calendar.current.component(.day, from: now)),
                details: [.init(title: "Time zone",
                                value: TimeZone.current.abbreviation(for: now) ?? TimeZone.current.identifier,
                                symbol: "globe")])
        }
    }
    private func settings(_ pane: String) { if let url = URL(string: "x-apple.systempreferences:\(pane)") { NSWorkspace.shared.open(url) } }
    @objc private func networkSettings() { settings("com.apple.wifi-settings-extension") }
    @objc private func soundSettings() { settings("com.apple.Sound-Settings.extension") }
    @objc private func batterySettings() { settings("com.apple.Battery-Settings.extension") }
    @objc private func clockSettings() { settings("com.apple.Date-Time-Settings.extension") }
}
