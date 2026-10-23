import AppKit
import Testing
@testable import OpenTile

// Scheduling tests must not depend on the host's opportunistic cache eviction.
private final class RetainedThumbnails: NSCache<NSURL, NSImage> {
    private var images: [NSURL: NSImage] = [:]
    override func object(forKey key: NSURL) -> NSImage? { images[key] }
    override func setObject(_ obj: NSImage, forKey key: NSURL, cost: Int) { images[key] = obj }
    override func removeAllObjects() { images.removeAll() }
}

private final class ThumbnailDecoder: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let blocked: Set<URL>
    private var decoded: [URL] = []
    private var active = 0
    private var peak = 0

    init(blocked: Set<URL> = []) { self.blocked = blocked }

    func decode(_ url: URL) -> CGImage? {
        lock.withLock {
            decoded.append(url)
            active += 1
            peak = max(peak, active)
        }
        started.signal()
        if blocked.contains(url) {
            _ = release.wait(timeout: .now() + 10)
        }
        defer { lock.withLock { active -= 1 } }
        return CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
    }

    var calls: [URL] { lock.withLock { decoded } }
    var maxActive: Int { lock.withLock { peak } }
}

struct WallpaperThumbnailTests {
    private func urls(_ prefix: String, count: Int = 13) -> [URL] {
        (0..<count).map { URL(fileURLWithPath: "/\(prefix)-\($0).png") }
    }

    private func waitForWorkers(_ decoder: ThumbnailDecoder, count: Int = 2) async -> Bool {
        await Task.detached {
            (0..<count).allSatisfy { _ in decoder.started.wait(timeout: .now() + 5) == .success }
        }.value
    }

    @MainActor private func finish(_ queue: OperationQueue) async {
        await Task.detached { queue.waitUntilAllOperationsAreFinished() }.value
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test @MainActor func browsingPrioritizesSelectedThumbnailAndDropsObsoleteQueue() async {
        let old = urls("old")
        let current = urls("current")
        let decoder = ThumbnailDecoder(blocked: Set(old.prefix(2)))
        let queue = OperationQueue()
        var renders = 0
        let thumbnails = WallpaperThumbnails(queue: queue, cache: RetainedThumbnails(), decode: decoder.decode) { renders += 1 }
        defer { decoder.release.signal(); decoder.release.signal(); thumbnails.reset() }
        thumbnails.update(visible: old, selected: old[0])
        #expect(await waitForWorkers(decoder))
        thumbnails.update(visible: current, selected: current[6])
        decoder.release.signal()
        #expect(await waitForWorkers(decoder, count: 1))
        decoder.release.signal()
        await finish(queue)

        let obsolete = decoder.calls.filter { old.contains($0) }.count
        let currentOrder = decoder.calls.filter { current.contains($0) }
        print("Thumbnail workload: obsolete decodes=\(obsolete), selected rank=\((currentOrder.firstIndex(of: current[6]) ?? -1) + 1), renders=\(renders), peak workers=\(decoder.maxActive)")
        #expect(obsolete == 2)
        #expect(currentOrder.first == current[6])
        #expect(currentOrder.count == current.count)
        #expect(renders == current.count)
        #expect(decoder.maxActive == 2)
        #expect(thumbnails.image(at: old[0]) != nil)
        #expect(current.allSatisfy { thumbnails.image(at: $0) != nil })
        thumbnails.update(visible: [old[0]], selected: old[0])
        await finish(queue)
        #expect(decoder.calls.filter { $0 == old[0] }.count == 1)
    }

    @Test @MainActor func selectionChangePromotesAnAlreadyQueuedThumbnail() async {
        let entries = urls("selection")
        let decoder = ThumbnailDecoder(blocked: Set(entries.prefix(2)))
        let queue = OperationQueue()
        let thumbnails = WallpaperThumbnails(queue: queue, cache: RetainedThumbnails(), decode: decoder.decode) {}
        defer { decoder.release.signal(); decoder.release.signal(); thumbnails.reset() }
        thumbnails.update(visible: entries, selected: entries[0])
        #expect(await waitForWorkers(decoder))
        thumbnails.update(visible: entries, selected: entries[8])
        decoder.release.signal()
        #expect(await waitForWorkers(decoder, count: 1))
        decoder.release.signal()
        await finish(queue)
        #expect(decoder.calls[2] == entries[8])
        #expect(decoder.calls.count == entries.count)
    }

    @Test @MainActor func cancelledThumbnailCanBeRequestedAgainWithoutDuplicateDecodes() async {
        let entries = urls("revisit")
        let decoder = ThumbnailDecoder(blocked: Set(entries.prefix(2)))
        let queue = OperationQueue()
        let thumbnails = WallpaperThumbnails(queue: queue, cache: RetainedThumbnails(), decode: decoder.decode) {}
        defer { decoder.release.signal(); decoder.release.signal(); thumbnails.reset() }
        thumbnails.update(visible: entries, selected: entries[0])
        #expect(await waitForWorkers(decoder))
        thumbnails.update(visible: [], selected: nil)
        thumbnails.update(visible: [entries[8]], selected: entries[8])
        thumbnails.update(visible: [entries[8]], selected: entries[8])
        decoder.release.signal()
        decoder.release.signal()
        await finish(queue)
        #expect(decoder.calls.filter { $0 == entries[8] }.count == 1)
        #expect(thumbnails.image(at: entries[8]) != nil)
        #expect(decoder.calls.count == 3)
    }

    @Test @MainActor func resetRejectsStaleCompletionAndAllowsSameURLAgain() async {
        let url = urls("reset", count: 1)[0]
        let decoder = ThumbnailDecoder(blocked: [url])
        let queue = OperationQueue()
        var renders = 0
        let thumbnails = WallpaperThumbnails(queue: queue, cache: RetainedThumbnails(), decode: decoder.decode) { renders += 1 }
        defer { decoder.release.signal(); decoder.release.signal(); thumbnails.reset() }
        thumbnails.update(visible: [url], selected: url)
        #expect(await waitForWorkers(decoder, count: 1))
        thumbnails.reset()
        thumbnails.update(visible: [url], selected: url)
        #expect(await waitForWorkers(decoder, count: 1))
        decoder.release.signal()
        decoder.release.signal()
        await finish(queue)
        #expect(decoder.calls.count == 2)
        #expect(renders == 1)
        #expect(thumbnails.image(at: url) != nil)
        thumbnails.reset()
        #expect(thumbnails.image(at: url) == nil)
    }

    @Test @MainActor func failedDecodeRetriesOnlyAfterReset() async {
        let url = urls("missing", count: 1)[0]
        let queue = OperationQueue()
        var renders = 0
        let thumbnails = WallpaperThumbnails(queue: queue, decode: { _ in nil }) { renders += 1 }
        thumbnails.update(visible: [url], selected: url)
        await finish(queue)
        thumbnails.update(visible: [url], selected: url)
        await finish(queue)
        #expect(renders == 1)
        #expect(thumbnails.image(at: url) == nil)
        thumbnails.reset()
        thumbnails.update(visible: [url], selected: url)
        await finish(queue)
        #expect(renders == 2)
    }

    @Test @MainActor func evictedThumbnailCanBeDecodedAgain() async {
        let url = urls("evicted", count: 1)[0]
        let decoder = ThumbnailDecoder()
        let queue = OperationQueue()
        let cache = RetainedThumbnails()
        let thumbnails = WallpaperThumbnails(queue: queue, cache: cache, decode: decoder.decode) {}
        defer { thumbnails.reset() }
        thumbnails.update(visible: [url], selected: url)
        await finish(queue)
        #expect(thumbnails.image(at: url) != nil)
        cache.removeAllObjects()
        #expect(thumbnails.image(at: url) == nil)
        thumbnails.update(visible: [url], selected: url)
        await finish(queue)
        #expect(decoder.calls == [url, url])
        #expect(thumbnails.image(at: url) != nil)
    }
}
