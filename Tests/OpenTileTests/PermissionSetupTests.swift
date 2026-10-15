import Foundation
import Testing
@testable import OpenTile

struct PermissionSetupTests {
    @Test
    func testSetupPersistsAcrossLaunchesAndRequestsOnlyMissingGrants() async {
        await MainActor.run {
            let suite = "PermissionSetupTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            var accessibility = false
            var capture = false
            var accessibilityRequests = 0
            var captureRequests = 0
            @MainActor func makeSetup() -> PermissionSetup {
                PermissionSetup(defaults: defaults,
                    accessibilityGranted: { accessibility }, captureGranted: { capture },
                    requestAccessibility: { accessibilityRequests += 1 },
                    requestCapture: { captureRequests += 1 })
            }
            let setup = makeSetup()
            #expect(setup.shouldShowOnLaunch)
            setup.markPresented()
            #expect(!(makeSetup().shouldShowOnLaunch))
            #expect((accessibilityRequests) == (0))
            #expect((captureRequests) == (0))
            setup.requestAccessibilityPermission()
            #expect((accessibilityRequests) == (1))
            #expect((captureRequests) == (0))
            accessibility = true
            setup.requestAccessibilityPermission()
            #expect((accessibilityRequests) == (1))
            #expect((captureRequests) == (0))
            capture = true
            setup.requestAccessibilityPermission()
            #expect((accessibilityRequests) == (1))
            #expect((captureRequests) == (0))
            capture = false
            setup.requestAccessibilityPermission()
            #expect((captureRequests) == (0))
            setup.requestAnimationPermission()
            #expect(captureRequests == 1)
            capture = true
            setup.requestAnimationPermission()
            #expect(captureRequests == 1)
            #expect(!(makeSetup().shouldShowOnLaunch))
        }
    }

    @Test
    func testExistingGrantsSkipOnboarding() async {
        await MainActor.run {
            let suite = "PermissionSetupTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let setup = PermissionSetup(defaults: defaults,
                accessibilityGranted: { true }, captureGranted: { false },
                requestAccessibility: { Issue.record("Already granted") },
                requestCapture: { Issue.record("Already granted") })
            #expect(!(setup.shouldShowOnLaunch))
            setup.requestAccessibilityPermission()
        }
    }
}
