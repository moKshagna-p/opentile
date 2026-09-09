import Foundation

public struct DrawingPoint: Codable, Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}
public struct WorkspaceSymbol: Codable {
    public let workspace: String
    public let strokes: [[DrawingPoint]]
    public init(workspace: String, strokes: [[DrawingPoint]]) {
        self.workspace = workspace; self.strokes = strokes
    }
}

/// Captures separate strokes without drawing connecting lines across finger lifts.
public struct DrawingCapture {
    public private(set) var strokes: [[DrawingPoint]] = []
    public private(set) var cancelled = false
    private var finger: Int?
    private var lastTime: Double?
    private var count = 0
    public init() {}
    public mutating func update(_ contacts: [Contact], time: Double) {
        guard !cancelled else { return }
        guard time.isFinite, lastTime.map({ time >= $0 }) ?? true,
              contacts.count <= 1, count < 4096,
              contacts.allSatisfy({ $0.point.x.isFinite && $0.point.y.isFinite && (0...1).contains($0.point.x) && (0...1).contains($0.point.y) }) else {
            cancelled = true; return
        }
        lastTime = time
        guard let contact = contacts.first else { finger = nil; return }
        if let finger, finger != contact.id { cancelled = true; return }
        if finger == nil { strokes.append([]) }
        finger = contact.id
        let point = DrawingPoint(x: contact.point.x, y: contact.point.y)
        if strokes[strokes.count - 1].last != point {
            strokes[strokes.count - 1].append(point); count += 1
        }
    }
}

public enum WorkspaceMatcher {
    private static func distance(_ a: DrawingPoint, _ b: DrawingPoint) -> Double {
        hypot(a.x - b.x, a.y - b.y)
    }
    static func normalized(_ strokes: [[DrawingPoint]]) -> [DrawingPoint]? {
        let points = strokes.flatMap { $0 }
        guard points.count >= 5, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }
        let scale = max(maxX - minX, maxY - minY)
        guard scale >= 0.06 else { return nil }
        var segments: [(DrawingPoint, DrawingPoint, Double)] = []
        for stroke in strokes where stroke.count > 1 {
            for i in 1..<stroke.count {
                let length = distance(stroke[i-1], stroke[i])
                if length > 0 { segments.append((stroke[i-1], stroke[i], length)) }
            }
        }
        let total = segments.reduce(0) { $0 + $1.2 }
        guard total >= 0.1, !segments.isEmpty else { return nil }
        var result: [DrawingPoint] = []
        var index = 0, offset = 0.0
        for sample in 0..<64 {
            let target = total * Double(sample) / 63
            while index < segments.count - 1 && offset + segments[index].2 < target {
                offset += segments[index].2; index += 1
            }
            let (a, b, length) = segments[index]
            let t = min(1, max(0, (target - offset) / length))
            result.append(.init(x: (a.x + (b.x-a.x)*t-minX)/scale,
                                y: (a.y + (b.y-a.y)*t-minY)/scale))
        }
        // Center the sampled ink rather than anchoring to an extreme point.
        // Normalize handwriting proportions, but limit expansion of narrow marks
        // so a slightly wobbly "1" does not become a full-width shape.
        let centerX = result.reduce(0) { $0 + $1.x } / Double(result.count)
        let centerY = result.reduce(0) { $0 + $1.y } / Double(result.count)
        let width = max((maxX - minX) / scale, 0.5)
        let height = max((maxY - minY) / scale, 0.5)
        return result.map { .init(x: ($0.x - centerX) / width,
                                  y: ($0.y - centerY) / height) }
    }
    public static func isValid(_ strokes: [[DrawingPoint]]) -> Bool { normalized(strokes) != nil }
    public static func match(_ strokes: [[DrawingPoint]], symbols: [WorkspaceSymbol]) -> String? {
        guard let input = normalized(strokes) else { return nil }
        func directed(_ a: [DrawingPoint], _ b: [DrawingPoint]) -> Double {
            a.reduce(0) { sum, point in sum + b.map { distance(point, $0) }.min()! } / Double(a.count)
        }
        var scores: [String: Double] = [:]
        for symbol in symbols {
            guard let template = normalized(symbol.strokes) else { continue }
            let score = (directed(input, template) + directed(template, input)) / 2
            scores[symbol.workspace] = min(scores[symbol.workspace] ?? .infinity, score)
        }
        let ranked = scores.sorted { $0.value < $1.value }
        // Require a 25% lead over other workspaces; identical/near-tied
        // drawings remain ambiguous even when both scores are very small.
        guard let best = ranked.first, best.value < 0.09,
              ranked.count == 1 || best.value < ranked[1].value * 0.75 else { return nil }
        return best.key
    }
}
