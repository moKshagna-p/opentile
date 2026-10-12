import Foundation

/// Separates the user's saved choice from temporary runtime stops.
final class GestureActivation {
    private let defaults: UserDefaults
    private(set) var isEnabled = false
    var shouldRestore: Bool { defaults.bool(forKey: "gesturesEnabled") }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    @discardableResult
    func enable(start: () -> Bool) -> Bool {
        guard !isEnabled else { return true }
        guard start() else { return false }
        isEnabled = true
        defaults.set(true, forKey: "gesturesEnabled")
        return true
    }

    func disable(rememberPause: Bool = false) {
        isEnabled = false
        if rememberPause { defaults.set(false, forKey: "gesturesEnabled") }
    }
}
