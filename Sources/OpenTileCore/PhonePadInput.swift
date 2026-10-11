import Foundation
import CoreGraphics

public enum PhonePadEvent: Equatable {
    case pointer(Double, Double), scroll(Double, Double), click
    case gesture(GestureEvent)
}

/// Phone contacts use the same normalized, upward-positive coordinates as the trackpad.
/// A sequence owns either scrolling or pinching until every finger lifts.
public struct PhonePadInput {
    private enum Mode { case pending, scroll, pinch, blocked }
    private var mode: Mode = .pending
    private var recognizer = GestureRecognizer()
    private var previous: [Contact] = []
    private var start: CGPoint?
    private var startTime = 0.0
    private var tapDistance = 0.0
    private var pairCenter: CGPoint?
    private var pairRadius = 0.0
    private var resize = false
    private var lastTime = -Double.infinity
    public init() {}

    public mutating func cancel() {
        mode = .blocked
        _ = recognizer.cancel()
        start = nil
    }

    public mutating func update(_ contacts: [Contact], time: Double, resize: Bool = false) -> [PhonePadEvent] {
        guard time.isFinite, time >= lastTime, contacts.count <= 2,
              contacts.allSatisfy({ $0.id >= 0 && $0.point.x.isFinite && $0.point.y.isFinite && (0...1).contains($0.point.x) && (0...1).contains($0.point.y) }),
              Set(contacts.map(\.id)).count == contacts.count else {
            cancel()
            return [.gesture(.cancelled)]
        }
        lastTime = time
        defer { previous = contacts }
        if contacts.isEmpty {
            let event = recognizer.update([], time: time)
            let tap = mode == .pending && previous.count == 1 && start != nil && time - startTime < 0.25 && tapDistance < 0.012
            mode = .pending
            start = nil
            pairCenter = nil
            pairRadius = 0
            return event.map { [.gesture($0)] } ?? (tap ? [.click] : [])
        }
        guard mode != .blocked else { return [] }
        if previous.isEmpty {
            self.resize = resize
            startTime = time
            tapDistance = 0
            start = contacts.count == 1 ? contacts[0].point : nil
        }
        if contacts.count == 1 {
            if previous.count == 2 {
                let event = recognizer.update(contacts, time: time, optionHeld: self.resize)
                cancel()
                return event.map { [.gesture($0)] } ?? []
            }
            _ = recognizer.update(contacts, time: time, optionHeld: self.resize)
            guard previous.count == 1, previous[0].id == contacts[0].id else {
                if !previous.isEmpty { cancel(); return [.gesture(.cancelled)] }
                return []
            }
            let point = contacts[0].point
            if let start { tapDistance = max(tapDistance, hypot(point.x - start.x, point.y - start.y)) }
            return [.pointer(point.x - previous[0].point.x, point.y - previous[0].point.y)]
        }
        start = nil
        let center = CGPoint(x: (contacts[0].point.x + contacts[1].point.x) / 2,
                             y: (contacts[0].point.y + contacts[1].point.y) / 2)
        let radius = hypot(contacts[0].point.x - center.x, contacts[0].point.y - center.y)
        if previous.count == 2 && Set(previous.map(\.id)) != Set(contacts.map(\.id)) {
            cancel(); return [.gesture(.cancelled)]
        }
        if pairCenter == nil { pairCenter = center; pairRadius = radius }
        if mode == .pending, let pairCenter {
            if self.resize || abs(radius - pairRadius) > max(0.008, pairRadius * 0.08) { mode = .pinch }
            else if hypot(center.x - pairCenter.x, center.y - pairCenter.y) > 0.012 {
                mode = .scroll
                _ = recognizer.cancel()
            }
        }
        if mode == .scroll {
            guard previous.count == 2 else { return [] }
            let old = CGPoint(x: (previous[0].point.x + previous[1].point.x) / 2,
                              y: (previous[0].point.y + previous[1].point.y) / 2)
            return [.scroll(center.x - old.x, center.y - old.y)]
        }
        return recognizer.update(contacts, time: time, optionHeld: self.resize).map { [.gesture($0)] } ?? []
    }
}
