import XCTest
import Common
@testable import AppBundle
@testable import OpenTile

final class EmbeddedEngineTests: XCTestCase {
    func testForkHasIndependentSocketIdentity() {
        XCTAssertEqual(aeroSpaceAppId, "com.mokshagna.opentile")
        XCTAssertEqual(aeroSpaceAppName, "OpenTile")
        XCTAssertTrue(socketPath.hasPrefix("/tmp/com.mokshagna.opentile-"))
    }

    func testDefaultConfigurationResourceParses() async throws {
        try await MainActor.run {
            let text = try String(contentsOf: defaultConfigUrl, encoding: .utf8)
            let result = parseConfig(text)
            XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
            XCTAssertFalse(result.config.modes.isEmpty)
        }
    }

    func testLegacyApplicationAssignmentParses() async throws {
        await MainActor.run {
            let result = parseConfig("""
                [mode.main.binding]
                alt-m = 'workspace M'
                [[on-window-detected]]
                if.app-id = 'com.apple.Music'
                run = 'move-node-to-workspace M'
                """)
            XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
            XCTAssertEqual(result.config.onWindowDetected.count, 1)
        }
    }

    func testWorkspaceBrowserIncludesEmptyWorkspace() async {
        await MainActor.run {
            let name = "OpenTile-test-empty"
            _ = Workspace.get(byName: name)
            let summary = openTileWorkspaces().first { $0.name == name }
            XCTAssertNotNil(summary)
            XCTAssertEqual(summary?.windowCount, 0)
            XCTAssertEqual(summary?.applications, [])
        }
    }

    func testTransportOnlyUsesSiblingCLI() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("OpenTile")
        XCTAssertNil(AeroSpace.locate(executableURL: app))
        let cli = directory.appendingPathComponent("aerospace")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: cli)
        XCTAssertNil(AeroSpace.locate(executableURL: app))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        XCTAssertEqual(AeroSpace.locate(executableURL: app)?.executable, cli)
    }
}
