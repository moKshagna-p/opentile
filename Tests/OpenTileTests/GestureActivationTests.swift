import Foundation
import Testing
@testable import OpenTile

struct GestureActivationTests {
    @Test func restoresSuccessfulEnableAfterReopeningForPhonePairing() {
        let name = "GestureActivationTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let first = GestureActivation(defaults: defaults)
        #expect(!first.shouldRestore)
        #expect(first.enable { true })
        let reopened = GestureActivation(defaults: defaults)
        #expect(reopened.shouldRestore)
        #expect(!reopened.isEnabled)
        var starts = 0
        #expect(reopened.enable { starts += 1; return true })
        #expect(reopened.enable { starts += 1; return true })
        #expect(reopened.isEnabled && starts == 1)
        reopened.disable(rememberPause: true)
        #expect(!reopened.isEnabled)
        #expect(!GestureActivation(defaults: defaults).shouldRestore)
    }

    @Test func permissionOrDeviceFailureDoesNotEnableOrForgetSavedChoice() {
        let name = "GestureActivationTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let first = GestureActivation(defaults: defaults)
        #expect(!first.enable { false })
        #expect(!first.isEnabled && !first.shouldRestore)
        #expect(first.enable { true })
        first.disable() // Sleep or permission revocation is not an explicit pause.
        #expect(!first.isEnabled && first.shouldRestore)
        let reopened = GestureActivation(defaults: defaults)
        #expect(!reopened.enable { false })
        #expect(!reopened.isEnabled && reopened.shouldRestore)
        #expect(reopened.enable { true })
        #expect(reopened.isEnabled)
    }
}
