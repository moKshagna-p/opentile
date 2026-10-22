// Read-only JSON-lines observer. Compile once; stdin lines request one AX query.
import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
func windowID(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

func focusedWindow(trusted: Bool = AXIsProcessTrusted()) -> [String: Any] {
    guard trusted else { return ["error": "accessibility_permission_required"] }
    guard let pid = DispatchQueue.main.sync(execute: {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }) else { return ["error": "focused_application_unavailable"] }
    guard pid > 0 else { return ["error": "pid_unavailable"] }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.25)
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value)
    guard result == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
        return ["error": "focused_window_unavailable", "ax_error": result.rawValue]
    }
    let window = unsafeBitCast(value, to: AXUIElement.self)
    var id: CGWindowID = 0
    guard windowID(window, &id) == .success, id != 0 else { return ["error": "window_id_unavailable"] }
    guard DispatchQueue.main.sync(execute: {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }) == pid else {
        return ["error": "frontmost_application_changed_during_query"]
    }
    return ["pid": pid, "window_id": id]
}

// AppKit refreshes frontmost-app state on the main run loop; keep AX and stdin off it.
DispatchQueue.global().async {
    if CommandLine.arguments.dropFirst() == ["--self-test"] {
        let denied = focusedWindow(trusted: false)
        let encoded = try! JSONSerialization.data(withJSONObject: denied)
        let decoded = try! JSONSerialization.jsonObject(with: encoded) as! [String: String]
        precondition(decoded == ["error": "accessibility_permission_required"])
        precondition(DispatchQueue.main.sync { Thread.isMainThread })
    } else {
        while readLine() != nil {
            autoreleasepool {
                let result = focusedWindow()
                let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                FileHandle.standardOutput.write(data + Data([10]))
            }
        }
    }
    DispatchQueue.main.async { CFRunLoopStop(CFRunLoopGetMain()) }
}
CFRunLoopRun()
