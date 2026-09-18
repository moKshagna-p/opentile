import Foundation

/// Deliberately small local command vocabulary. User text never becomes shell code.
public enum CompanionCommand: Equatable {
    case openApp(String)
    case help

    public init?(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["help", "?"].contains(text.lowercased()) { self = .help; return }
        guard let space = text.firstIndex(where: \.isWhitespace),
              ["open", "launch", "start"].contains(text[..<space].lowercased()) else { return nil }
        var name = text[space...].trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("\""), name.hasSuffix("\""), name.count > 1 { name.removeFirst(); name.removeLast() }
        guard !name.isEmpty, name.count <= 120,
              !name.contains(where: { "/\\:;|&`$\n\r".contains($0) }) else { return nil }
        self = .openApp(name)
    }
}

/// Bounded, damped secondary motion, driven by idle movement and drag impulses.
public struct CompanionSpring {
    public private(set) var position: Double = 0
    public private(set) var velocity: Double = 0
    public init() {}
    public mutating func impulse(_ value: Double) {
        guard value.isFinite else { return }
        velocity = max(-8, min(8, velocity + value))
    }
    public mutating func step(delta: Double, target: Double) {
        guard delta.isFinite, delta > 0, target.isFinite else { return }
        let dt = min(delta, 1.0 / 30)
        let target = max(-0.3, min(0.3, target))
        // Substeps keep the spring stable even at 30 fps.
        for _ in 0..<4 {
            velocity += ((target - position) * 100 - velocity * 12) * dt / 4
            position = max(-0.45, min(0.45, position + velocity * dt / 4))
        }
    }
    public mutating func reset() { position = 0; velocity = 0 }
}
