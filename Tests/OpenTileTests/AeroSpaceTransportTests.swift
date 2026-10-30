import Foundation
import Testing
import OpenTileCore
@testable import OpenTile

/// Records engine commands and answers `list-windows` from a mutable layout.
@MainActor private final class FakeEngine {
    var layouts: [Int: String]
    var failing: String?
    var commands: [[String]] = []

    init(_ layouts: [Int: String]) { self.layouts = layouts }

    var aerospace: AeroSpace {
        AeroSpace(execute: { [self] arguments in
            commands.append(arguments)
            if arguments.first == failing { throw AeroSpace.Failure(message: "\(arguments[0]) failed") }
            switch arguments.first {
            case "list-windows":
                let rows = layouts.keys.sorted().map {
                    "{\"window-id\":\($0),\"app-pid\":1,\"workspace\":\"A\",\"window-parent-container-layout\":\"\(layouts[$0]!)\"}"
                }
                return "[\(rows.joined(separator: ","))]"
            case "layout":
                layouts[Int(arguments[2])!] = arguments[3] == "floating" ? "floating" : "h_tiles"
                return ""
            default: return ""
            }
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

    @Test func insertRunsThePlanThroughTheEngine() async throws {
        let engine = FakeEngine([1: "h_tiles", 2: "h_tiles"])
        try await engine.aerospace.insert(source: tile(1), target: tile(2), edge: .left)
        #expect(engine.mutations == InsertionPlan(source: 1, target: 2, targetLayout: "h_tiles", edge: .left).commands)
    }

    @Test func failedInsertReturnsTheWindowToTiling() async {
        let engine = FakeEngine([1: "h_tiles", 2: "h_tiles"])
        engine.failing = "focus"
        do {
            try await engine.aerospace.insert(source: tile(1), target: tile(2), edge: .left)
            Issue.record("A failed insertion must throw")
        } catch {
            #expect(error.localizedDescription.hasPrefix("Insertion failed; the window was returned to tiling."))
        }
        #expect(engine.mutations.last == ["layout", "--window-id", "1", "tiling"])
        #expect(engine.layouts[1] == "h_tiles")
    }

    @Test func insertRejectsAChangedWorkspaceWithoutMutating() async {
        let engine = FakeEngine([1: "h_tiles"])
        await #expect(throws: AeroSpace.Failure.self) {
            try await engine.aerospace.insert(source: tile(1), target: tile(2), edge: .left)
        }
        #expect(engine.mutations.isEmpty)
    }
}
