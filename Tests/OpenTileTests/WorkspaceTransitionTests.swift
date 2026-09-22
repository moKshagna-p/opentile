import CoreGraphics
import Testing
@testable import OpenTile

struct WorkspaceTransitionTests {
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
