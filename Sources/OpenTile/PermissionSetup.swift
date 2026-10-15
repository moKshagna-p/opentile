import AppKit
import ApplicationServices

/// Stores only whether setup was presented. macOS remains the source of truth for grants.
@MainActor
final class PermissionSetup {
    private let defaults: UserDefaults
    private let accessibilityGranted: () -> Bool
    private let captureGranted: () -> Bool
    private let requestAccessibility: () -> Void
    private let requestCapture: () -> Void
    private static let presentedKey = "hasPresentedPermissionSetup"

    init(defaults: UserDefaults = .standard,
         accessibilityGranted: @escaping () -> Bool = { AXIsProcessTrusted() },
         captureGranted: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
         requestAccessibility: @escaping () -> Void = {
             let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
             _ = AXIsProcessTrustedWithOptions(options)
         },
         requestCapture: @escaping () -> Void = { _ = CGRequestScreenCaptureAccess() }) {
        self.defaults = defaults
        self.accessibilityGranted = accessibilityGranted
        self.captureGranted = captureGranted
        self.requestAccessibility = requestAccessibility
        self.requestCapture = requestCapture
    }

    var shouldShowOnLaunch: Bool {
        !defaults.bool(forKey: Self.presentedKey) && !accessibilityGranted()
    }

    func markPresented() { defaults.set(true, forKey: Self.presentedKey) }

    func requestAccessibilityPermission() {
        if !accessibilityGranted() { requestAccessibility() }
    }

    func requestAnimationPermission() {
        if !captureGranted() { requestCapture() }
    }

    func show() {
        let alert = NSAlert()
        alert.messageText = "Set up OpenTile permissions"
        alert.informativeText = "Accessibility: \(accessibilityGranted() ? "Allowed" : "Not allowed") — required to move and resize windows.\n\nScreen Recording: \(captureGranted() ? "Allowed" : "Not allowed") — optional, for workspace animations using temporary snapshots kept in memory. Workspace switching works without it. Choose Enable Animations only if you want this permission.\n\nmacOS may ask you to reopen OpenTile. You can revisit Permission Setup from the menu at any time."
        alert.addButton(withTitle: accessibilityGranted() ? "Done" : "Allow Accessibility")
        let offerAnimations = !captureGranted()
        if offerAnimations { alert.addButton(withTitle: "Enable Animations…") }
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        markPresented()
        let response = alert.runModal()
        if response == .alertFirstButtonReturn { requestAccessibilityPermission() }
        if offerAnimations && response == .alertSecondButtonReturn { requestAnimationPermission() }
    }
}
