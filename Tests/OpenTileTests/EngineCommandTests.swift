import Foundation
import Testing
@testable import AppBundle
@testable import OpenTile

@Suite(.serialized)
@MainActor struct EngineCommandTests {
    @Test func returnsOutputAndArguments() async throws {
        let output = try await AeroSpace.command(["workspace", "A"]) { $0.joined(separator: " ") }
        #expect(output == "workspace A")
    }

    @Test func propagatesEngineErrors() async {
        do {
            _ = try await AeroSpace.command(["workspace", "A"]) { _ in throw OpenTileCommandFailure(message: "bad") }
            Issue.record("Engine failure must propagate")
        } catch { #expect(error.localizedDescription == "bad") }
    }

    @Test func stalledEngineReleasesCallerAndCancelsWork() async {
        var finish: CheckedContinuation<Void, Never>?
        var cancelled = false
        // Release even a broken implementation so the regression fails rather than hangs.
        let cleanup = Task { @MainActor in
            try await Task.sleep(for: .seconds(2))
            finish?.resume()
            finish = nil
        }
        defer { cleanup.cancel() }
        let started = ContinuousClock.now
        do {
            _ = try await AeroSpace.command(["workspace", "A"], timeout: .milliseconds(50)) { _ in
                await withTaskCancellationHandler {
                    await withCheckedContinuation { finish = $0 }
                } onCancel: { Task { @MainActor in cancelled = true } }
                return "late"
            }
            Issue.record("A stalled engine must time out")
        } catch { #expect(error.localizedDescription.contains("timed out")) }
        #expect(ContinuousClock.now - started < .seconds(1))
        while !cancelled { await Task.yield() }
        finish?.resume()
        finish = nil
    }

    @Test func invalidCommandFailsWithoutASession() async {
        do {
            _ = try await runOpenTileCommand(["not-a-command"])
            Issue.record("Unknown commands must fail")
        } catch { #expect(error is OpenTileCommandFailure) }
    }

    @Test func disabledEngineRejectsCommands() async {
        TrayMenuModel.shared.isEnabled = false
        defer { TrayMenuModel.shared.isEnabled = true }
        do {
            _ = try await runOpenTileCommand(["workspace", "A"])
            Issue.record("A disabled engine must not run commands")
        } catch { #expect(error.localizedDescription.contains("disabled")) }
    }
}
