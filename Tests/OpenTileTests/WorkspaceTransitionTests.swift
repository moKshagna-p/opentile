import AppKit
import ScreenCaptureKit
import Testing
@testable import OpenTile

@Suite(.serialized)
struct WorkspaceTransitionTests {
    @MainActor private func surface() -> WorkspaceTransition.Surface {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: CGRect(x: -10_000, y: -10_000, width: 10, height: 10),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        view.wantsLayer = true
        let layer = view.layer!
        layer.addSublayer(CALayer())
        panel.contentView = view
        return WorkspaceTransition.Surface(panel: panel, layer: layer, displayID: 0, configuration: SCStreamConfiguration())
    }

    @MainActor private func preservingWorkspaceStack(_ body: () async throws -> Void) async rethrows {
        let saved = UserDefaults.standard.object(forKey: "workspaceStack")
        defer { UserDefaults.standard.set(saved, forKey: "workspaceStack") }
        try await body()
    }

    @Test @MainActor func stalledOutgoingCaptureStillSwitchesAndNeverShowsALateOverlay() async throws {
        try await preservingWorkspaceStack {
            let surface = surface()
            defer { surface.panel.close() }
            var finish: CheckedContinuation<Void, Never>?
            var completed = false
            var captures = 0
            let cleanup = Task { @MainActor in
                try await Task.sleep(for: .seconds(2))
                finish?.resume()
                finish = nil
            }
            defer { cleanup.cancel() }
            let transition = WorkspaceTransition(prepare: {
                captures += 1
                await withCheckedContinuation { finish = $0 }
                completed = true
                return [surface]
            }, captureIncoming: { _ in
                Issue.record("A timed-out outgoing capture must skip destination capture")
                return []
            })
            var switches = 0
            let animated = try await transition.perform(from: "test-source", to: "test-destination") {
                switches += 1
                #expect(!completed)
                #expect(!surface.panel.isVisible)
                return "test-destination"
            }
            #expect(!animated && switches == 1)
            let nextAnimated = try await transition.perform(from: "test-destination", to: "test-next") {
                switches += 1
                return "test-next"
            }
            #expect(!nextAnimated && switches == 2 && captures == 1)
            finish?.resume()
            while !completed { await Task.yield() }
            #expect(!surface.panel.isVisible, "A late snapshot must never cover a newer workspace")
        }
    }

    @Test @MainActor func slowEngineDropsOverlayAndSkipsDestinationCapture() async throws {
        try await preservingWorkspaceStack {
            let surface = surface()
            defer { surface.panel.close() }
            let transition = WorkspaceTransition(prepare: { [surface] }, captureIncoming: { _ in
                Issue.record("A slow engine switch must not add another capture and animation")
                return []
            })
            let animated = try await transition.perform(from: "test-source", to: "test-destination") {
                #expect(surface.panel.isVisible)
                try await Task.sleep(for: .seconds(0.65))
                #expect(!surface.panel.isVisible, "The overlay watchdog must run while the engine is stalled")
                return "test-destination"
            }
            #expect(!animated)
            #expect(!surface.panel.isVisible)
        }
    }

    @Test @MainActor func stalledIncomingCaptureReleasesSwitchAndRemovesOverlay() async throws {
        try await preservingWorkspaceStack {
            let surface = surface()
            defer { surface.panel.close() }
            var finish: CheckedContinuation<Void, Never>?
            var completed = false
            let cleanup = Task { @MainActor in
                try await Task.sleep(for: .seconds(2))
                finish?.resume()
                finish = nil
            }
            defer { cleanup.cancel() }
            let transition = WorkspaceTransition(prepare: { [surface] }, captureIncoming: { _ in
                await withCheckedContinuation { finish = $0 }
                completed = true
                return [image(width: 1)]
            })
            let animated = try await transition.perform(from: "test-source", to: "test-destination") { "test-destination" }
            #expect(!animated && !completed)
            #expect(!surface.panel.isVisible)
            finish?.resume()
            while !completed { await Task.yield() }
            #expect(!surface.panel.isVisible)
        }
    }

    @Test @MainActor func quickSwitchKeepsAnimationAndCleansUpPanels() async throws {
        try await preservingWorkspaceStack {
            let surface = surface()
            defer { surface.panel.close() }
            var incomingCaptures = 0
            let transition = WorkspaceTransition(prepare: { [surface] }, captureIncoming: { surfaces in
                incomingCaptures += 1
                #expect(surfaces.first?.panel === surface.panel)
                #expect(surface.panel.isVisible)
                return [image(width: 1)]
            })
            let animated = try await transition.perform(from: "test-source", to: "test-destination") { "test-destination" }
            #expect(animated && incomingCaptures == 1)
            #expect(!surface.panel.isVisible)
        }
    }

    @Test @MainActor func cancellationDuringOutgoingCaptureDoesNotSwitchOrShowLatePanels() async {
        await preservingWorkspaceStack {
            let surface = surface()
            defer { surface.panel.close() }
            var finish: CheckedContinuation<Void, Never>?
            var completed = false
            let transition = WorkspaceTransition(prepare: {
                await withCheckedContinuation { finish = $0 }
                completed = true
                return [surface]
            }, captureIncoming: { _ in
                Issue.record("Cancelled transitions must not capture the destination")
                return []
            })
            let task = Task { @MainActor in
                try await transition.perform(from: "test-source", to: "test-destination") {
                    Issue.record("Cancelled transitions must not switch workspaces")
                    return "test-destination"
                }
            }
            while finish == nil { await Task.yield() }
            let cleanup = Task { @MainActor in
                try await Task.sleep(for: .seconds(2))
                finish?.resume()
                finish = nil
            }
            defer { cleanup.cancel() }
            task.cancel()
            do {
                _ = try await task.value
                Issue.record("Cancellation must propagate")
            } catch { #expect(error is CancellationError) }
            #expect(!completed && !surface.panel.isVisible)
            finish?.resume()
            finish = nil
            while !completed { await Task.yield() }
            #expect(!surface.panel.isVisible)
        }
    }

    @Test @MainActor func failedSwitchRemovesOverlayWithoutCapturingDestination() async {
        enum Failure: Error { case engine }
        await preservingWorkspaceStack {
            let surface = surface()
            defer { surface.panel.close() }
            let transition = WorkspaceTransition(prepare: { [surface] }, captureIncoming: { _ in
                Issue.record("A failed switch must not capture its destination")
                return []
            })
            do {
                _ = try await transition.perform(from: "test-source", to: "test-destination") { throw Failure.engine }
                Issue.record("Engine failure must propagate")
            } catch { #expect(error is Failure) }
            #expect(!surface.panel.isVisible)
        }
    }

    @Test @MainActor func captureBudgetReturnsFastResultsAndRecoversAfterFailure() async {
        enum Failure: Error { case capture }
        let capture = WorkspaceCapture()
        let first = await capture.run(timeout: 1) { 42 }
        #expect(first == 42)
        let failed: Int? = await capture.run(timeout: 1) { throw Failure.capture }
        #expect(failed == nil)
        let next = await capture.run(timeout: 1) { 43 }
        #expect(next == 43)
    }

    @Test @MainActor func stalledCaptureReleasesCallerWithoutStartingMoreCaptures() async {
        let capture = WorkspaceCapture()
        var finish: CheckedContinuation<Int, Never>?
        var completed = false
        // Release even a broken implementation so the regression fails rather than hangs.
        let cleanup = Task { @MainActor in
            try await Task.sleep(for: .seconds(1))
            finish?.resume(returning: 42)
            finish = nil
        }
        defer { cleanup.cancel() }
        let result = await capture.run(timeout: 0.01) {
            let value = await withCheckedContinuation { finish = $0 }
            completed = true
            return value
        }
        #expect(result == nil)
        #expect(!completed, "An unresponsive capture must not hold up switching")
        var startedAnother = false
        let skipped = await capture.run(timeout: 1) { startedAnother = true; return 99 }
        #expect(skipped == nil)
        #expect(!startedAnother, "Repeated switches must not accumulate stalled captures")
        finish?.resume(returning: 42)
        finish = nil
        while !completed { await Task.yield() }
        let recovered = await capture.run(timeout: 1) { 43 }
        #expect(recovered == 43, "A late result must be discarded and release the capture slot")
    }

    @Test @MainActor func cancelledCaptureBudgetReleasesCallerWhileCaptureIsStalled() async {
        let capture = WorkspaceCapture()
        var finish: CheckedContinuation<Int, Never>?
        var completed = false
        let task = Task { @MainActor in
            await capture.run(timeout: 10) {
                let value = await withCheckedContinuation { finish = $0 }
                completed = true
                return value
            }
        }
        while finish == nil { await Task.yield() }
        let cleanup = Task { @MainActor in
            try await Task.sleep(for: .seconds(1))
            finish?.resume(returning: 42)
            finish = nil
        }
        defer { cleanup.cancel() }
        task.cancel()
        let result = await task.value
        #expect(result == nil)
        #expect(!completed)
        finish?.resume(returning: 42)
        finish = nil
        while !completed { await Task.yield() }
        let recovered = await capture.run(timeout: 1) { 43 }
        #expect(recovered == 43)
    }

    @Test @MainActor func expiredBudgetDoesNotStartCapture() async {
        let capture = WorkspaceCapture()
        var started = false
        let result = await capture.run(timeout: 0) { started = true; return 42 }
        #expect(result == nil)
        #expect(!started)
    }

    @MainActor private func image(width: Int) -> CGImage {
        CGContext(data: nil, width: width, height: 1, bitsPerComponent: 8,
                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }

    @Test @MainActor func snapshotsOverlapAndRetainDisplayOrder() async throws {
        var secondFinished = false
        let first = image(width: 1)
        let second = image(width: 2)
        let images = try await WorkspaceTransition.captureSnapshots([
            {
                for _ in 0..<1_000 {
                    if secondFinished { break }
                    await Task.yield()
                }
                #expect(secondFinished, "Other displays should capture while the first is suspended")
                return first
            },
            {
                secondFinished = true
                return second
            }
        ])
        #expect(images.map(\.width) == [1, 2])
    }

    @Test @MainActor func failedSnapshotCancelsOtherDisplays() async {
        enum Failure: Error { case capture }
        var waiting = false
        var cancelled = false
        do {
            _ = try await WorkspaceTransition.captureSnapshots([
                {
                    waiting = true
                    do {
                        try await Task.sleep(nanoseconds: 10_000_000_000)
                    } catch {
                        cancelled = error is CancellationError
                        throw error
                    }
                    return image(width: 1)
                },
                {
                    while !waiting { await Task.yield() }
                    throw Failure.capture
                }
            ])
            Issue.record("Capture failure should propagate")
        } catch {
            #expect(error is Failure)
        }
        #expect(cancelled)
    }

    @Test @MainActor func noDisplaysNeedsNoCapture() async throws {
        let images = try await WorkspaceTransition.captureSnapshots([])
        #expect(images.isEmpty)
    }

    @Test @MainActor func cancelledCaptureDoesNotReturnSnapshots() async {
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await WorkspaceTransition.captureSnapshots([
                { image(width: 1) }
            ])
        }
        do {
            _ = try await task.value
            Issue.record("Cancellation should propagate")
        } catch {
            #expect(error is CancellationError)
        }
    }
}
