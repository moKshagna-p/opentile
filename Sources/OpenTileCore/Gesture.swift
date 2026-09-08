import Foundation
import CoreGraphics

public struct Contact: Sendable {
    public let id: Int
    public let point: CGPoint
    public init(id: Int, x: Double, y: Double) {
        self.id = id
        self.point = CGPoint(x: x, y: y)
    }
}

public enum GestureEvent: Equatable {
    case began(CGPoint), moved(CGPoint), released, cancelled
}

/// A deliberate three-finger pinch followed by a short hold arms the drag.
/// After release/cancel, all fingers must lift before another gesture can begin.
public struct GestureRecognizer {
    private enum Phase { case idle, tracking, holding, dragging, blocked }
    private var phase: Phase = .idle
    private var ids: Set<Int> = []
    private var initialRadius: Double = 0
    private var holdTime: Double = 0
    private var holdPoint = CGPoint.zero
    private var lastTime: Double = -.infinity
    public init() {}

    public mutating func cancel() -> GestureEvent? {
        let active = phase == .dragging
        phase = .blocked
        return active ? .cancelled : nil
    }

    public mutating func update(_ contacts: [Contact], time: Double) -> GestureEvent? {
        guard time.isFinite, time >= lastTime else { return cancel() }
        lastTime = time
        guard contacts.allSatisfy({ $0.point.x.isFinite && $0.point.y.isFinite && (0...1).contains($0.point.x) && (0...1).contains($0.point.y) }), Set(contacts.map(\.id)).count == contacts.count else { return cancel() }
        if contacts.isEmpty {
            let event: GestureEvent? = phase == .dragging ? .released : nil
            phase = .idle
            return event
        }
        if phase == .blocked { return nil }
        if phase == .dragging {
            // A partial lift finishes the gesture; additional/replaced fingers cancel.
            if contacts.count < 3 && Set(contacts.map(\.id)).isSubset(of: ids) {
                phase = .blocked
                return .released
            }
            guard contacts.count == 3, Set(contacts.map(\.id)) == ids else { return cancel() }
            return .moved(Self.centroid(contacts))
        }
        guard contacts.count == 3 else { phase = .idle; return nil }
        let center = Self.centroid(contacts)
        let radius = contacts.reduce(0) { $0 + hypot($1.point.x - center.x, $1.point.y - center.y) } / 3
        if phase == .idle || Set(contacts.map(\.id)) != ids {
            ids = Set(contacts.map(\.id))
            initialRadius = radius
            phase = .tracking
        }
        if phase == .tracking, initialRadius > 0.025, radius < initialRadius * 0.82 {
            phase = .holding
            holdTime = time
            holdPoint = center
        }
        if phase == .holding {
            if radius > initialRadius * 0.9 { phase = .tracking; return nil }
            if hypot(center.x - holdPoint.x, center.y - holdPoint.y) > 0.025 {
                holdTime = time
                holdPoint = center
            }
            if time - holdTime >= 0.18 {
                phase = .dragging
                return .began(center)
            }
        }
        return nil
    }

    private static func centroid(_ contacts: [Contact]) -> CGPoint {
        CGPoint(x: contacts.reduce(0) { $0 + $1.point.x } / Double(contacts.count),
                y: contacts.reduce(0) { $0 + $1.point.y } / Double(contacts.count))
    }
}

public enum Edge: String, CaseIterable {
    case left, right, top, bottom
    public var horizontal: Bool { self == .left || self == .right }
    public var before: Bool { self == .left || self == .top }
    public static func nearest(to point: CGPoint, in rect: CGRect) -> Edge? {
        guard rect.width > 0, rect.height > 0, rect.contains(point) else { return nil }
        let x = (point.x - rect.minX) / rect.width
        let y = (point.y - rect.minY) / rect.height
        return [(Edge.left, x), (.right, 1-x), (.top, y), (.bottom, 1-y)].min { $0.1 < $1.1 }?.0
    }
    public func preview(in rect: CGRect) -> CGRect {
        switch self {
        case .left: return CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .right: return CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .top: return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)
        case .bottom: return CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
        }
    }
}

public struct InsertionPlan {
    public let commands: [[String]]
    public init(source: Int, target: Int, targetLayout: String, edge: Edge) {
        let horizontal = targetLayout == "h_tiles"
        let previous = horizontal ? "left" : "up"
        var result = [["layout", "--window-id", "\(source)", "floating"],
                      ["focus", "--window-id", "\(target)"],
                      ["layout", "--window-id", "\(source)", "tiling"]]
        // AeroSpace inserts after the most recently focused tile in its parent.
        if horizontal != edge.horizontal {
            result.append(["join-with", "--window-id", "\(source)", previous])
        }
        if edge.before {
            result.append(["move", "--window-id", "\(source)", edge.horizontal ? "left" : "up"])
        }
        result.append(["focus", "--window-id", "\(source)"])
        commands = result
    }
}

public enum DropAction: Equatable {
    case swap, insert(Edge)
    public static func hitTest(_ point: CGPoint, in rect: CGRect) -> DropAction? {
        guard let edge = Edge.nearest(to: point, in: rect) else { return nil }
        return rect.insetBy(dx: rect.width * 0.25, dy: rect.height * 0.25).contains(point) ? .swap : .insert(edge)
    }
    public func preview(in rect: CGRect) -> CGRect {
        switch self {
        case .swap: return rect
        case .insert(let edge): return edge.preview(in: rect)
        }
    }
}

/// Exchange the endpoints of a forward DFS path, restoring every intermediate slot.
public struct SwapPlan {
    public let commands: [[String]]
    public init(source: Int, target: Int, distance: Int) {
        guard source != target, distance > 0 else { commands = []; return }
        commands = Array(repeating: ["swap", "--window-id", "\(source)", "--wrap-around", "dfs-next"], count: distance)
            + Array(repeating: ["swap", "--window-id", "\(target)", "--wrap-around", "dfs-prev"], count: distance - 1)
    }
}
