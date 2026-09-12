import Foundation
import Testing
import OpenTileCore
@testable import OpenTile

@MainActor
private func drainMainQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}

@Test @MainActor func gesturePollingStopsAndCanResumeWithoutDuplicateTimers() {
    let polling = GesturePolling()
    #expect(polling.timer == nil)
    var ticks = 0
    polling.start { ticks += 1 }
    let first = polling.timer!
    polling.start { ticks += 100 }
    #expect(polling.timer === first)
    first.fire()
    #expect(ticks == 1)
    polling.stop()
    #expect(!first.isValid)
    #expect(polling.timer == nil)
    first.fire()
    #expect(ticks == 1)
    polling.start { ticks += 1 }
    #expect(polling.timer !== first)
    #expect(polling.timer?.isValid == true)
    polling.stop()
}

@Test @MainActor func workspaceQueueWaitsForStartupAndLayoutCompletionWithoutPolling() async {
    var received: [WorkspaceRequest] = []
    var queue: WorkspaceRequestQueue!
    queue = WorkspaceRequestQueue { request in
        received.append(request)
        queue.isBusy = true
    }
    defer { queue = nil }
    queue.append(.workspace("1"))
    queue.append(.backAndForth)
    await drainMainQueue()
    #expect(received.isEmpty)
    queue.isReady = true
    await drainMainQueue()
    #expect(received == [.workspace("1")])
    await drainMainQueue()
    #expect(received.count == 1)
    queue.isBusy = false
    await drainMainQueue()
    #expect(received == [.workspace("1"), .backAndForth])
}

@Test @MainActor func workspaceQueueRechecksBusyAndContinuesAfterUnstartedRequest() async {
    var received: [WorkspaceRequest] = []
    let queue = WorkspaceRequestQueue { received.append($0) }
    queue.isReady = true
    queue.append(.workspace("1"))
    queue.isBusy = true
    await drainMainQueue()
    #expect(received.isEmpty)
    queue.append(.workspace("2"))
    queue.isBusy = false
    await drainMainQueue()
    await drainMainQueue()
    #expect(received == [.workspace("1"), .workspace("2")])
}

@Test @MainActor func gesturePollingSettlesAndSurvivesRepeatedWakePauseCycles() {
    let polling = GesturePolling()
    var ticks = 0
    for _ in 0..<2_000 {
        polling.start { ticks += 1 }
        let timer = polling.timer!
        polling.start { ticks += 100 }
        timer.fire()
        polling.settle(idleFor: 0.45, drawingActive: false)
        #expect(timer.isValid) // Missing-frame cancellation must get its tick.
        polling.settle(idleFor: 2, drawingActive: true)
        #expect(timer.isValid) // Drawing must still time out without new frames.
        polling.settle(idleFor: 0.51, drawingActive: false)
        #expect(polling.timer == nil)
        #expect(!timer.isValid)
        polling.stop()
        timer.fire()
    }
    #expect(ticks == 2_000)
}

@Test @MainActor func workspaceQueueSustainedFIFO() async {
    var received: [WorkspaceRequest] = []
    let queue = WorkspaceRequestQueue { received.append($0) }
    let requests = (0..<1_000).map { WorkspaceRequest.workspace(String($0)) }
    requests.forEach(queue.append)
    queue.isReady = true
    for _ in requests { await drainMainQueue() }
    #expect(received == requests)
    await drainMainQueue()
    #expect(received.count == requests.count)
}
