import XCTest
@testable import OpenTileCore

final class WorkspaceRequestTests: XCTestCase {
    func testWorkspaceNamesAndCommandArguments() {
        let request = WorkspaceRequest(url: URL(string: "opentile://workspace?name=Study%20Room")!)
        XCTAssertEqual(request, .workspace("Study Room"))
        XCTAssertEqual(request?.arguments, ["workspace", "Study Room"])
    }

    func testBackAndForth() {
        let request = WorkspaceRequest(url: URL(string: "opentile://workspace?action=back-and-forth")!)
        XCTAssertEqual(request, .backAndForth)
        XCTAssertEqual(request?.arguments, ["workspace-back-and-forth"])
    }

    func testRejectsInvalidOrAmbiguousRequests() {
        for url in ["https://workspace?name=1", "opentile://other?name=1",
                    "opentile://workspace?name=", "opentile://workspace?name=--help",
                    "opentile://workspace?name=1&name=2", "opentile://workspace?name=1%0A",
                    "opentile://workspace/path?name=1", "opentile://workspace?action=unknown"] {
            XCTAssertNil(WorkspaceRequest(url: URL(string: url)!), url)
        }
    }
}
