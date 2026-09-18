import Foundation

/// A small chain of damped springs. The hair tip follows its root with a delay.
public struct CompanionRig {
    public private(set) var hair = CompanionSpring()
    public private(set) var tip = CompanionSpring()
    public private(set) var bow = CompanionSpring()
    public private(set) var sash = CompanionSpring()
    public private(set) var blink = 0.0
    public private(set) var breath = 0.0
    public init() {}

    public mutating func step(delta: Double, time: Double, drive: Double, intensity: Double) {
        guard delta.isFinite, delta > 0, time.isFinite, drive.isFinite, intensity.isFinite else {
            reset(); return
        }
        let strength = max(0, min(1.8, intensity))
        if strength == 0 {
            hair.reset(); tip.reset(); bow.reset(); sash.reset()
        } else {
            let input = max(-0.3, min(0.3, drive * strength))
            hair.step(delta: delta, target: input)
            tip.step(delta: delta, target: hair.position)
            bow.step(delta: delta, target: -input * 0.65)
            sash.step(delta: delta, target: tip.position * 0.7)
        }
        breath = sin(time * 1.8) * 0.002
        // Smooth 220 ms blink, once per cycle; no random state in the renderer.
        let phase = max(0, time).truncatingRemainder(dividingBy: 4.6)
        blink = phase < 0.22 ? pow(sin(phase / 0.22 * .pi), 2) : 0
    }

    public mutating func reset() {
        hair.reset(); tip.reset(); bow.reset(); sash.reset()
        blink = 0; breath = 0
    }
}
