import Foundation
import AppKit
import Testing
@testable import OpenTile

struct AppUpdaterTests {
    @Test
    func testUnpackagedExecutableDisablesUpdater() async {
        await MainActor.run {
            let updater = AppUpdater()
            let menu = NSMenu()
            menu.autoenablesItems = false
            updater.install(in: menu, statusButton: nil)
            #expect((menu.items.count) == (2))
            #expect((menu.items[0].title) == ("Updates require a packaged app"))
            #expect(menu.items.allSatisfy { !$0.isEnabled })
        }
    }

    @Test
    func testUpdateReminderAndSessionReset() async {
        await MainActor.run {
            let updater = AppUpdater()
            let menu = NSMenu()
            updater.install(in: menu, statusButton: nil)
            #expect(updater.supportsGentleScheduledUpdateReminders)
            updater.showAvailableUpdate(version: "0.3.0")
            #expect((menu.items[0].title) == ("Update Available… (0.3.0)"))
            updater.standardUserDriverWillFinishUpdateSession()
            #expect((menu.items[0].title) == ("Check for Updates…"))
        }
    }

    @Test
    func testUpdateSessionRestoresStatusIcon() async {
        await MainActor.run {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            defer { NSStatusBar.system.removeStatusItem(item) }
            let original = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "OpenTile")
            item.button?.image = original
            let updater = AppUpdater()
            updater.install(in: NSMenu(), statusButton: item.button)
            updater.showAvailableUpdate(version: "0.3.0")
            #expect(item.button?.image !== original)
            updater.showAvailableUpdate(version: "0.3.1")
            updater.standardUserDriverWillFinishUpdateSession()
            #expect(item.button?.image === original)
        }
    }
}
