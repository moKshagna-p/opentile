import Foundation
import Testing
import Common
@testable import AppBundle
@testable import OpenTile

@Suite(.serialized)
struct EmbeddedEngineTests {
    @Test
    func testForkHasIndependentSocketIdentity() {
        #expect((aeroSpaceAppId) == ("com.mokshagna.opentile"))
        #expect((aeroSpaceAppName) == ("OpenTile"))
        #expect(socketPath.hasPrefix("/tmp/com.mokshagna.opentile-"))
    }

    @Test
    func testDefaultConfigurationResourceParses() async throws {
        try await MainActor.run {
            let text = try String(contentsOf: defaultConfigUrl, encoding: .utf8)
            let result = parseConfig(text)
            #expect(result.errors.isEmpty, "\(result.errors)")
            #expect(!(result.config.modes.isEmpty))
        }
    }

    @Test
    func testLegacyApplicationAssignmentParses() async throws {
        await MainActor.run {
            let result = parseConfig("""
                [mode.main.binding]
                alt-m = 'workspace M'
                [[on-window-detected]]
                if.app-id = 'com.apple.Music'
                run = 'move-node-to-workspace M'
                """)
            #expect(result.errors.isEmpty, "\(result.errors)")
            #expect((result.config.onWindowDetected.count) == (1))
        }
    }

    @Test
    func testWorkspaceBrowserIncludesEmptyWorkspace() async {
        await MainActor.run {
            let name = "OpenTile-test-empty"
            _ = Workspace.get(byName: name)
            let summary = openTileWorkspaces().first { $0.name == name }
            #expect(summary != nil)
            #expect((summary?.windowCount) == (0))
            #expect((summary?.applications) == ([]))
        }
    }

    @Test
    func testTransportOnlyUsesSiblingCLI() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("OpenTile")
        #expect(AeroSpace.locate(executableURL: app) == nil)
        let cli = directory.appendingPathComponent("aerospace")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: cli)
        #expect(AeroSpace.locate(executableURL: app) == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        #expect((AeroSpace.locate(executableURL: app)?.executable) == (cli))
    }
}
