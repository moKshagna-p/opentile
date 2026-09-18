import Foundation

/// Deterministic joint targets; secondary hair motion is driven by changes in pose.
public struct CompanionBehavior {
    public private(set) var head = CompanionSpring()
    public private(set) var waist = CompanionSpring()
    public private(set) var lift = 0.0
    public private(set) var breath = 0.0
    private var reaction = 0.0
    public init() {}

    public mutating func greet() { reaction = 1 }

    public mutating func step(delta: Double, time: Double, attention: Double, drive: Double) {
        guard delta.isFinite, delta > 0, time.isFinite, attention.isFinite, drive.isFinite else {
            reset(); return
        }
        let dt = min(delta, 1.0 / 30)
        reaction = max(0, reaction - dt * 0.65)
        // Separate pauses, curious looks and a slow seated weight shift.
        let phase = max(0, time).truncatingRemainder(dividingBy: 19)
        let curious = phase > 5 && phase < 9 ? sin((phase - 5) / 4 * .pi) : 0
        let stretch = phase > 12 && phase < 16 ? sin((phase - 12) / 4 * .pi) : 0
        let gaze = max(-1, min(1, attention))
        waist.step(delta: dt, target: -gaze * 0.025 + stretch * 0.055 + max(-0.1, min(0.1, drive * 0.25)))
        head.step(delta: dt, target: -gaze * 0.09 + curious * 0.09 - stretch * 0.06 + sin(reaction * .pi * 3) * reaction * 0.045)
        lift = sin(reaction * .pi) * 0.10 + stretch * 0.035
        breath = sin(time * 1.7) * 0.008
    }

    public mutating func reset() {
        head.reset(); waist.reset(); lift = 0; breath = 0; reaction = 0
    }
}
