import Foundation
import OpenTileCore

/// Owned and used on the main thread, alongside the gesture recognizer.
final class GesturePolling {
    private(set) var timer: Timer?

    func start(_ tick: @escaping () -> Void) {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in tick() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit { timer?.invalidate() }
}

/// Dispatches independently of gesture polling. Main-thread callers set busy
/// while any layout operation is in flight, and ready after application setup.
final class WorkspaceRequestQueue {
    var isReady = false { didSet { schedule() } }
    var isBusy = false { didSet { schedule() } }
    private var requests: [WorkspaceRequest] = []
    private var scheduled = false
    private let perform: (WorkspaceRequest) -> Void

    init(perform: @escaping (WorkspaceRequest) -> Void) {
        self.perform = perform
    }

    func append(_ request: WorkspaceRequest) {
        requests.append(request)
        schedule()
    }

    private func schedule() {
        guard isReady, !isBusy, !requests.isEmpty, !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            guard self.isReady, !self.isBusy, !self.requests.isEmpty else { return }
            self.perform(self.requests.removeFirst())
            self.schedule()
        }
    }
}
