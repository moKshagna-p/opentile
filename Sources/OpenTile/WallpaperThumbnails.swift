import AppKit

@MainActor final class WallpaperThumbnails {
    private let cache: NSCache<NSURL, NSImage>
    private let queue: OperationQueue
    private let decode: @Sendable (URL) -> CGImage?
    private let onChange: () -> Void
    private var pending: [URL: BlockOperation] = [:]
    private var failed = Set<URL>()
    private var visible = Set<URL>()

    init(queue: OperationQueue = OperationQueue(),
         cache: NSCache<NSURL, NSImage> = NSCache(),
         decode: @escaping @Sendable (URL) -> CGImage? = { try? WallpaperLibrary.image(at: $0, maxPixels: 1000) },
         onChange: @escaping () -> Void) {
        self.queue = queue
        self.cache = cache
        self.decode = decode
        self.onChange = onChange
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func image(at url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    func update(visible urls: [URL], selected: URL?) {
        visible = Set(urls)
        for (url, operation) in pending where !visible.contains(url) && !operation.isExecuting && !operation.isFinished {
            operation.cancel()
            pending.removeValue(forKey: url)
        }
        for (url, operation) in pending {
            operation.queuePriority = url == selected ? .veryHigh : .normal
        }
        for url in urls.sorted(by: { $0 == selected && $1 != selected }) {
            guard image(at: url) == nil, pending[url] == nil, !failed.contains(url) else { continue }
            let operation = BlockOperation()
            operation.queuePriority = url == selected ? .veryHigh : .normal
            let decode = decode
            operation.addExecutionBlock { [weak self, weak operation] in
                let image = decode(url)
                DispatchQueue.main.async {
                    guard let self, let operation, self.pending[url] === operation else { return }
                    self.pending.removeValue(forKey: url)
                    if let image {
                        self.cache.setObject(NSImage(cgImage: image, size: .zero), forKey: url as NSURL,
                                             cost: image.bytesPerRow * image.height)
                    } else { self.failed.insert(url) }
                    if self.visible.contains(url) { self.onChange() }
                }
            }
            pending[url] = operation
            queue.addOperation(operation)
        }
    }

    func reset() {
        queue.cancelAllOperations()
        pending.removeAll()
        failed.removeAll()
        visible.removeAll()
        cache.removeAllObjects()
    }
}
