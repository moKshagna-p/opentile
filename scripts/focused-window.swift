// Read-only JSON-lines observer. Compile once; stdin lines request one AX query.
import Foundation
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
func windowID(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

func focusedWindow(trusted: Bool = AXIsProcessTrusted()) -> [String: Any] {
    guard trusted else { return ["error": "accessibility_permission_required"] }
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system, 0.25)
    var application: CFTypeRef?
    guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &application) == .success,
          let application, CFGetTypeID(application) == AXUIElementGetTypeID() else {
        return ["error": "focused_application_unavailable"]
    }
    let app = unsafeBitCast(application, to: AXUIElement.self)
    var pid: pid_t = 0
    guard AXUIElementGetPid(app, &pid) == .success, pid > 0 else { return ["error": "pid_unavailable"] }
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value)
    guard result == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
        return ["error": "focused_window_unavailable", "ax_error": result.rawValue]
    }
    let window = unsafeBitCast(value, to: AXUIElement.self)
    var id: CGWindowID = 0
    guard windowID(window, &id) == .success, id != 0 else { return ["error": "window_id_unavailable"] }
    var rechecked: CFTypeRef?
    guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &rechecked) == .success,
          let rechecked, CFEqual(application, rechecked) else {
        return ["error": "frontmost_application_changed_during_query"]
    }
    return ["pid": pid, "window_id": id]
}

if CommandLine.arguments.dropFirst() == ["--self-test"] {
    // Validate the wire format without querying or requesting Accessibility access.
    let denied = focusedWindow(trusted: false)
    let encoded = try JSONSerialization.data(withJSONObject: denied)
    let decoded = try JSONSerialization.jsonObject(with: encoded) as! [String: String]
    precondition(decoded == ["error": "accessibility_permission_required"])
} else {
    while readLine() != nil {
        autoreleasepool {
            let result = focusedWindow()
            let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            FileHandle.standardOutput.write(data + Data([10]))
        }
    }
}
