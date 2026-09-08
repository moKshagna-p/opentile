import XCTest
@testable import OpenTileCore

final class WorkspaceStackTests: XCTestCase {
    func testFirstVisitsEnterFromBelowAndRevisitsPreserveOrder() {
        var stack = WorkspaceStack()
        XCTAssertEqual(stack.direction(from: "Codex", to: "Music"), 1)
        XCTAssertEqual(stack.direction(from: "Music", to: "WhatsApp"), 1)
        XCTAssertEqual(stack.direction(from: "WhatsApp", to: "Codex"), -1)
        XCTAssertEqual(stack.direction(from: "Codex", to: "WhatsApp"), 1)
        XCTAssertEqual(stack.workspaces, ["Codex", "Music", "WhatsApp"])
        XCTAssertEqual(stack.direction(from: "WhatsApp", to: "WhatsApp"), 0)
    }

    func testRestoredOrderAndExternallyVisitedWorkspace() {
        var stack = WorkspaceStack(workspaces: ["Codex", "", "Music", "Codex", "WhatsApp"])
        XCTAssertEqual(stack.workspaces, ["Codex", "Music", "WhatsApp"])
        XCTAssertEqual(stack.direction(from: "Browser", to: "Music"), -1)
        XCTAssertEqual(stack.workspaces, ["Codex", "Music", "WhatsApp", "Browser"])
    }
}
