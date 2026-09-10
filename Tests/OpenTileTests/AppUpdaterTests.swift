import AppKit
import XCTest
@testable import OpenTile

final class AppUpdaterTests: XCTestCase {
    func testUnpackagedExecutableDisablesUpdater() async {
        await MainActor.run {
            let updater = AppUpdater()
            let menu = NSMenu()
            menu.autoenablesItems = false
            updater.install(in: menu, statusButton: nil)
            XCTAssertEqual(menu.items.count, 2)
            XCTAssertEqual(menu.items[0].title, "Updates require a packaged app")
            XCTAssertTrue(menu.items.allSatisfy { !$0.isEnabled })
        }
    }

    func testUpdateReminderAndSessionReset() async {
        await MainActor.run {
            let updater = AppUpdater()
            let menu = NSMenu()
            updater.install(in: menu, statusButton: nil)
            XCTAssertTrue(updater.supportsGentleScheduledUpdateReminders)
            updater.showAvailableUpdate(version: "0.3.0")
            XCTAssertEqual(menu.items[0].title, "Update Available… (0.3.0)")
            updater.standardUserDriverWillFinishUpdateSession()
            XCTAssertEqual(menu.items[0].title, "Check for Updates…")
        }
    }
}
