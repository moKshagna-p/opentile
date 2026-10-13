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
    func testWorkspaceOpenCommandsIgnoreAppLocation() {
        for name in ["1", "M", "Study%20Room"] {
            for target in [#"-a "/missing/OpenTile.app""#, "-b com.mokshagna.opentile"] {
                let script = " open -g \(target) \"opentile://workspace?name=\(name)\" "
                #expect(WorkspaceRequest(openCommand: script) == .workspace(name.removingPercentEncoding!))
            }
        }
        #expect(WorkspaceRequest(openCommand: #"open -g -a "/old/OpenTile.app" "opentile://workspace?action=back-and-forth""#) == .backAndForth)
    }

    @Test
    func testWorkspaceOpenCommandsDoNotInterceptOtherShellScripts() {
        for script in [
            #"open -g -a "/old/Other.app" "opentile://workspace?name=1""#,
            #"open -g -b another.app "opentile://workspace?name=1""#,
            #"open -g -b com.mokshagna.opentile "opentile://workspace?name=1"; echo done"#,
            #"open -g -a "/old/OpenTile.app" "opentile://workspace?name=$TARGET""#,
            #"open -g -a "/old/OpenTile.app" "opentile://workspace?name=--help""#,
            #"open -g -a "/old/OpenTile.app" "opentile://workspace?name=1&name=2""#
        ] { #expect(WorkspaceRequest(openCommand: script) == nil, "\(script)") }
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
