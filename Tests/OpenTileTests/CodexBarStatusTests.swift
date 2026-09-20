import AppKit
import Testing
@testable import OpenTile

struct CodexBarStatusTests {
    @Test func onlyOccupiedOrFocusedWorkspacesAppear() {
        #expect(!WorkspaceBarLayout.showsWorkspace(windowCount: 0, isFocused: false))
        #expect(WorkspaceBarLayout.showsWorkspace(windowCount: 0, isFocused: true))
        #expect(WorkspaceBarLayout.showsWorkspace(windowCount: 3, isFocused: false))
    }

    @Test func layoutReservesWorkspaceSpaceAndCollapsesUsage() {
        let spacious = WorkspaceBarLayout(width: 700, contentWidth: 230)
        #expect(spacious.statusWidth == 130)
        #expect(spacious.workspaceWidth >= 230)
        let crowded = WorkspaceBarLayout(width: 400, contentWidth: 700)
        #expect(crowded.statusWidth == 32)
        #expect(crowded.workspaceWidth == 360)
        let tiny = WorkspaceBarLayout(width: 60, contentWidth: 100)
        #expect(tiny.statusWidth == 0)
        #expect(tiny.workspaceWidth == 60)
    }

    @Test func dashboardKeepsHealthyRowsAlongsideFailures() throws {
        let data = Data(#"{"schemaVersion":1,"host":{},"providers":[{"id":"codex","name":"Codex","enabled":true,"windows":[{"label":"Session","usedPercent":11,"remainingPercent":89,"resetAt":null}]},{"id":"claude","name":"Claude","enabled":true,"error":{"message":"offline"}},{"id":"hidden","name":"Hidden","enabled":false}]}"#.utf8)
        let snapshot = try CodexBarSnapshot.decode(data)
        #expect(!snapshot.showUsed)
        #expect(snapshot.visibleProviders.count == 2)
        #expect(snapshot.navbarProviders.map(\.id) == ["codex"])
        #expect(snapshot.visibleProviders[0].windows?[0].percent(showUsed: false) == 89)
        #expect(snapshot.visibleProviders[1].windows == nil)
    }

    @Test func usageRespectsFillPreferenceAndClampsValues() throws {
        let data = Data(#"{"schemaVersion":1,"host":{"usageBarsShowUsed":true},"providers":[{"id":"codex","name":"Codex","enabled":true,"windows":[{"label":"Session","usedPercent":130},{"label":"Weekly","remainingPercent":54},{"label":"Unknown"}]}]}"#.utf8)
        let snapshot = try CodexBarSnapshot.decode(data)
        let windows = try #require(snapshot.providers.first?.windows)
        #expect(snapshot.showUsed)
        #expect(windows[0].percent(showUsed: true) == 100)
        #expect(windows[0].percent(showUsed: false) == 0)
        #expect(windows[1].percent(showUsed: true) == 46)
        #expect(windows[2].percent(showUsed: false) == nil)
    }

    @Test func unsupportedSchemaIsRejected() {
        #expect(throws: (any Error).self) {
            try CodexBarSnapshot.decode(Data(#"{"schemaVersion":2,"host":{},"providers":[]}"#.utf8))
        }
    }
}
