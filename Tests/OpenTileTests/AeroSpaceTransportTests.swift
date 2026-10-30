import Foundation
import Testing
import OpenTileCore
@testable import OpenTile

/// Records engine commands and answers `list-windows` from a fixed layout.
@MainActor private final class FakeEngine {
    let layouts: [Int: String]
    var commands: [[String]] = []

    init(_ layouts: [Int: String]) { self.layouts = layouts }

    var aerospace: AeroSpace {
        AeroSpace(execute: { [self] arguments in
            commands.append(arguments)
            guard arguments.first == "list-windows" else { return "" }
            let rows = layouts.keys.sorted().map {
                "{\"window-id\":\($0),\"app-pid\":1,\"workspace\":\"A\",\"window-parent-container-layout\":\"\(layouts[$0]!)\"}"
            }
            return "[\(rows.joined(separator: ","))]"
        })
    }

    var mutations: [[String]] { commands.filter { $0.first != "list-windows" } }
}

private func tile(_ id: Int, _ layout: String = "h_tiles") -> Tile {
    Tile(id: id, pid: 1, workspace: "A", layout: layout)
}

@Suite(.serialized)
@MainActor struct AeroSpaceTransportTests {
    @Test func resizeRunsTheEngineCommandAfterValidation() async throws {
        let engine = FakeEngine([1: "h_tiles", 2: "h_tiles"])
        let plan = ResizePlan(frame: CGRect(x: 0, y: 0, width: 800, height: 600), layout: "h_tiles", change: 0.5)
        try await engine.aerospace.resize(source: tile(1), plan: plan)
        #expect(engine.mutations == [try #require(plan.command(windowID: 1))])
    }

    @Test func resizeRejectsAChangedLayoutWithoutMutating() async {
        let engine = FakeEngine([1: "v_tiles", 2: "v_tiles"])
        let plan = ResizePlan(frame: CGRect(x: 0, y: 0, width: 800, height: 600), layout: "h_tiles", change: 0.5)
        await #expect(throws: AeroSpace.Failure.self) { try await engine.aerospace.resize(source: tile(1), plan: plan) }
        #expect(engine.mutations.isEmpty)
    }
}
