import Foundation
import Testing
@testable import OpenTileCore

struct WorkspaceStackTests {
    @Test
    func testFirstVisitsEnterFromBelowAndRevisitsPreserveOrder() {
        var stack = WorkspaceStack()
        #expect((stack.direction(from: "Codex", to: "Music")) == (1))
        #expect((stack.direction(from: "Music", to: "WhatsApp")) == (1))
        #expect((stack.direction(from: "WhatsApp", to: "Codex")) == (-1))
        #expect((stack.direction(from: "Codex", to: "WhatsApp")) == (1))
        #expect((stack.workspaces) == (["Codex", "Music", "WhatsApp"]))
        #expect((stack.direction(from: "WhatsApp", to: "WhatsApp")) == (0))
    }

    @Test
    func testRestoredOrderAndExternallyVisitedWorkspace() {
        var stack = WorkspaceStack(workspaces: ["Codex", "", "Music", "Codex", "WhatsApp"])
        #expect((stack.workspaces) == (["Codex", "Music", "WhatsApp"]))
        #expect((stack.direction(from: "Browser", to: "Music")) == (-1))
        #expect((stack.workspaces) == (["Codex", "Music", "WhatsApp", "Browser"]))
    }
}
