import Foundation
import os

/// Diagnostic stages only: a native request returning does not establish OS focus.
struct FocusTrace: Sendable {
    @TaskLocal static var current: FocusTrace?
    private static let enabled = ProcessInfo.processInfo.environment["OPENTILE_TRACE_FOCUS"] == "1"
    private let id: OSSignpostID

    static func make(enabled: Bool = enabled) -> FocusTrace? {
        enabled ? FocusTrace(id: signposter.makeSignpostID()) : nil
    }

    func emit(_ stage: StaticString, window: UInt32 = 0, pid: Int32 = 0) {
        signposter.emitEvent("FocusStage", id: id,
            "focus_trace=1 id=\(id.rawValue) stage=\(stage.description, privacy: .public) ns=\(DispatchTime.now().uptimeNanoseconds) pid=\(pid) window=\(window)")
    }
}
