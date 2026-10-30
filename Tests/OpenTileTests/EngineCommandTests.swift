import Foundation
import Testing
import Common
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

    @Test func alreadyCancelledCallerDoesNotStartCommand() async {
        var ran = false
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AeroSpace.command(["workspace", "A"]) { _ in
                ran = true
                return "unexpected"
            }
        }
        do {
            _ = try await task.value
            Issue.record("A cancelled caller must fail")
        } catch { #expect(error is CancellationError) }
        #expect(!ran)
    }

    @Test func cancellingCallerReleasesWaitAndCancelsCommand() async {
        var finish: CheckedContinuation<Void, Never>?
        var completed = false
        var cancelled = false
        let task = Task { @MainActor in
            try await AeroSpace.command(["workspace", "A"], timeout: .seconds(2)) { _ in
                await withCheckedContinuation { finish = $0 }
                cancelled = Task.isCancelled
                completed = true
                return "late"
            }
        }
        while finish == nil { await Task.yield() }
        let cleanup = Task { @MainActor in
            try await Task.sleep(for: .seconds(1))
            finish?.resume()
            finish = nil
        }
        defer { cleanup.cancel() }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancellation must propagate")
        } catch { #expect(error is CancellationError) }
        #expect(!completed, "Cancellation must release the caller before stalled work returns")
        finish?.resume()
        finish = nil
        while !completed { await Task.yield() }
        #expect(cancelled)
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

    @Test func failedReloadPreservesConfigErrors() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".toml")
        try "invalid = [".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        var args = ReloadConfigCmdArgs(rawArgs: [])
        args.dryRun = true
        args.noGui = true
        let reload = await reloadConfig_nonCancellable(args: args, forceConfigUrl: url)
        #expect(!reload.isOk && !reload.stdout.isEmpty)
        let result = CmdResult(stdout: [reload.stdout], stderr: [reload.stderr], exitCode: .fail)
        do {
            _ = try result.openTileOutput()
            Issue.record("An invalid config must fail with its diagnostics")
        } catch { #expect(error.localizedDescription.contains(reload.stdout)) }
    }

    @Test func commandOutputPreservesBothFailureStreamsAndHasFallback() throws {
        let success = CmdResult(stdout: ["first", "second"], stderr: ["warning"], exitCode: .init(rawValue: 0))
        #expect(try success.openTileOutput() == "first\nsecond")
        for (stdout, stderr) in [(["error"], ["warning"]), ([], ["error"]), ([], [])] {
            let result = CmdResult(stdout: stdout, stderr: stderr, exitCode: .fail)
            do {
                _ = try result.openTileOutput()
                Issue.record("Nonzero exit codes must throw")
            } catch {
                #expect(!error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                for line in stdout + stderr { #expect(error.localizedDescription.contains(line)) }
            }
        }
    }

    @Test func disabledEngineRejectsCommands() async {
        let wasEnabled = TrayMenuModel.shared.isEnabled
        TrayMenuModel.shared.isEnabled = false
        defer { TrayMenuModel.shared.isEnabled = wasEnabled }
        do {
            _ = try await runOpenTileCommand(["workspace", "A"])
            Issue.record("A disabled engine must not run commands")
        } catch { #expect(error.localizedDescription.contains("disabled")) }
    }
}
