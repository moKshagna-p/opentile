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
            setup.requestMissingPermissions()
            #expect((accessibilityRequests) == (1))
            #expect((captureRequests) == (1))
            accessibility = true
            setup.requestMissingPermissions()
            #expect((accessibilityRequests) == (1))
            #expect((captureRequests) == (2))
            capture = true
            setup.requestMissingPermissions()
            #expect((accessibilityRequests) == (1))
            #expect((captureRequests) == (2))
            capture = false
            setup.requestMissingPermissions()
            #expect((captureRequests) == (3))
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
                accessibilityGranted: { true }, captureGranted: { true },
                requestAccessibility: { Issue.record("Already granted") },
                requestCapture: { Issue.record("Already granted") })
            #expect(!(setup.shouldShowOnLaunch))
            setup.requestMissingPermissions()
        }
    }
}
