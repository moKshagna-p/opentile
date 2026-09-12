import Foundation
import Testing
@testable import OpenTileCore

struct WorkspaceRequestTests {
    @Test
    func testWorkspaceNamesAndCommandArguments() {
        let request = WorkspaceRequest(url: URL(string: "opentile://workspace?name=Study%20Room")!)
        #expect((request) == (.workspace("Study Room")))
        #expect((request?.arguments) == (["workspace", "Study Room"]))
    }

    @Test
    func testBackAndForth() {
        let request = WorkspaceRequest(url: URL(string: "opentile://workspace?action=back-and-forth")!)
        #expect((request) == (.backAndForth))
        #expect((request?.arguments) == (["workspace-back-and-forth"]))
    }

    @Test
    func testRejectsInvalidOrAmbiguousRequests() {
        for url in ["https://workspace?name=1", "opentile://other?name=1",
                    "opentile://workspace?name=", "opentile://workspace?name=--help",
                    "opentile://workspace?name=1&name=2", "opentile://workspace?name=1%0A",
                    "opentile://workspace/path?name=1", "opentile://workspace?action=unknown"] {
            #expect(WorkspaceRequest(url: URL(string: url)!) == nil, "\(url)")
        }
    }
}
