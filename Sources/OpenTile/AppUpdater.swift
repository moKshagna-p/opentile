import AppKit
import Sparkle

/// Sparkle owns scheduling, signature verification, installation, and relaunching.
@MainActor
final class AppUpdater: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController!
    private var observations: [NSKeyValueObservation] = []
    private let checkItem = NSMenuItem(title: "Check for Updates…", action: nil, keyEquivalent: "")
    private let automaticItem = NSMenuItem(title: "Automatically Check for Updates", action: nil, keyEquivalent: "")
    private weak var statusButton: NSStatusBarButton?

    func install(in menu: NSMenu, statusButton: NSStatusBarButton?) {
        self.statusButton = statusButton
        menu.addItem(checkItem)
        menu.addItem(automaticItem)
        // A bare `swift run` executable has no updater metadata or app bundle.
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else {
            checkItem.title = "Updates require a packaged app"
            checkItem.isEnabled = false
            automaticItem.isEnabled = false
            return
        }
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
        checkItem.target = controller
        checkItem.action = #selector(SPUStandardUpdaterController.checkForUpdates(_:))
        automaticItem.target = self
        automaticItem.action = #selector(toggleAutomaticChecks)
        // OpenTile's menu disables automatic validation, so observe Sparkle explicitly.
        observations = [
            controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.checkItem.isEnabled = updater.canCheckForUpdates }
            },
            controller.updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.automaticItem.state = updater.automaticallyChecksForUpdates ? .on : .off }
            }
        ]
        do {
            try controller.updater.start()
        } catch {
            checkItem.title = "Updater unavailable"
            checkItem.toolTip = error.localizedDescription
            checkItem.isEnabled = false
            automaticItem.isEnabled = false
            NSLog("OpenTile updater could not start: %@", error.localizedDescription)
        }
    }

    @objc private func toggleAutomaticChecks() {
        controller.updater.automaticallyChecksForUpdates.toggle()
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        // Scheduled checks announce themselves in the menu without stealing focus.
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        showAvailableUpdate(version: update.displayVersionString)
    }

    func showAvailableUpdate(version: String) {
        checkItem.title = "Update Available… (\(version))"
        statusButton?.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "OpenTile update available")
        statusButton?.toolTip = "OpenTile \(version) is available"
    }

    func standardUserDriverWillFinishUpdateSession() {
        checkItem.title = "Check for Updates…"
        statusButton?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "OpenTile")
        statusButton?.toolTip = nil
    }
}
