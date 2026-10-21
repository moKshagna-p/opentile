import Foundation
import Testing
import OpenTileCore
@testable import OpenTile

struct GesturePreviewBatchTests {
    private func frame(_ time: Double, radius: Double = 0.1, x: Double = 0.5,
                       resize: Bool = false) -> TouchBridge.Frame {
        .init(contacts: [.init(id: 1, x: x - radius, y: 0.5), .init(id: 2, x: x + radius, y: 0.5)],
              time: time, optionHeld: resize)
    }

    private func arm(_ time: Double = 0) -> [TouchBridge.Frame] {
        [frame(time, radius: 0.15), frame(time + 0.1), frame(time + 0.4)]
    }

    @Test(arguments: [false, true])
    func finalMoveIsHitTestedBeforeFullOrPartialRelease(partial: Bool) {
        var recognizer = GestureRecognizer()
        let moves = [frame(0.5, x: 0.55), frame(0.6, x: 0.65), frame(0.7, x: 0.75)]
        let lift = TouchBridge.Frame(contacts: partial ? Array(moves.last!.contacts.prefix(1)) : [], time: 0.8, optionHeld: false)
        let frames = arm() + moves + [lift, lift, .init(contacts: [], time: 0.9, optionHeld: false)]
        var received: [GestureEvent] = []
        var visited = 0
        var hitTests = 0
        var destination: DropAction?
        var committed: DropAction?
        let events = frames.lazy.compactMap { frame in
            visited += 1
            return recognizer.update(frame.contacts, time: frame.time, optionHeld: frame.optionHeld)
        }
        processGesturePreviewBatch(events) { event in
            received.append(event)
            if case .moved(let point) = event {
                hitTests += 1
                destination = DropAction.hitTest(point, in: CGRect(x: 0.7, y: 0.4, width: 0.1, height: 0.2))
            }
            if event == .released { committed = destination }
        }
        #expect(visited == frames.count)
        #expect(received == [.began(CGPoint(x: 0.5, y: 0.5)), .moved(CGPoint(x: 0.75, y: 0.5)), .released])
        #expect(hitTests == 1)
        #expect(committed == .swap)
    }

    @Test(arguments: [false, true])
    func batchedWorkloadPresentsOncePerBatch(resize: Bool) {
        var recognizer = GestureRecognizer()
        let initial = resize ? [frame(0, radius: 0.15, resize: true), frame(0.1, resize: true)] : arm()
        for frame in initial { _ = recognizer.update(frame.contacts, time: frame.time, optionHeld: frame.optionHeld) }
        var recognized = 0
        var presentations = 0
        var hitTests = 0
        for batch in 0..<60 {
            let frames = (0..<8).map { index in
                frame(1 + Double(batch * 8 + index) * 0.001, radius: resize ? 0.08 + Double(index) * 0.001 : 0.1,
                      x: 0.55 + Double(index) * 0.01, resize: resize)
            }
            let events = frames.lazy.compactMap { frame in
                let event = recognizer.update(frame.contacts, time: frame.time, optionHeld: frame.optionHeld)
                if event != nil { recognized += 1 }
                return event
            }
            processGesturePreviewBatch(events) { event in
                presentations += 1
                if case .moved(let point) = event {
                    hitTests += 1
                    _ = DropAction.hitTest(point, in: CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
                }
            }
        }
        #expect(recognized == 480)
        #expect(presentations == 60)
        #expect(hitTests == (resize ? 0 : 60))
        print("Gesture batch workload: resize=\(resize), recognized=\(recognized), presentations=\(presentations), hitTests=\(hitTests)")
    }

    @Test func multipleLifecyclesKeepBeginAndReleaseOrderAndFinalResize() {
        var recognizer = GestureRecognizer()
        let frames = arm() + [frame(0.5, x: 0.6), frame(0.6, x: 0.7), .init(contacts: [], time: 0.7, optionHeld: false),
                              frame(1, radius: 0.15, resize: true), frame(1.1, radius: 0.12, resize: true),
                              frame(1.2, radius: 0.11, resize: true), frame(1.3, radius: 0.09, resize: true),
                              .init(contacts: [], time: 1.4, optionHeld: true)]
        var order: [String] = []
        var latestResize = 0.0
        var committedResize = 0.0
        let events = frames.lazy.compactMap { recognizer.update($0.contacts, time: $0.time, optionHeld: $0.optionHeld) }
        processGesturePreviewBatch(events) { event in
            switch event {
            case .began: order.append("begin")
            case .moved: order.append("move")
            case .resizeBegan(let change): order.append("resizeBegin"); latestResize = change
            case .resized(let change): order.append("resize"); latestResize = change
            case .released: order.append("release"); committedResize = latestResize
            case .cancelled: order.append("cancel")
            }
        }
        #expect(order == ["begin", "move", "release", "resizeBegin", "resize", "release"])
        #expect(abs(committedResize - 0.4) < 0.000001)
    }

    @Test(arguments: ["extraFinger", "replacedFinger", "invalidPoint", "invalidTime", "backwardsTime"], [false, true])
    func cancellationDropsPendingPresentationAndAllowsANewLifecycle(reason: String, resize: Bool) {
        var recognizer = GestureRecognizer()
        var bad = frame(0.7)
        switch reason {
        case "extraFinger": bad = .init(contacts: bad.contacts + [.init(id: 3, x: 0.5, y: 0.5)], time: 0.7, optionHeld: false)
        case "replacedFinger": bad = .init(contacts: [bad.contacts[0], .init(id: 3, x: 0.6, y: 0.5)], time: 0.7, optionHeld: false)
        case "invalidPoint": bad = .init(contacts: [.init(id: 1, x: .nan, y: 0.5)], time: 0.7, optionHeld: false)
        case "invalidTime": bad = .init(contacts: bad.contacts, time: .nan, optionHeld: false)
        default: bad = frame(0.1)
        }
        let initial = resize ? [frame(0, radius: 0.15, resize: true), frame(0.4, resize: true)] : arm()
        let frames = initial + [frame(0.5, radius: 0.11, x: 0.6), frame(0.6, radius: 0.09, x: 0.7), bad, frame(0.8),
                              .init(contacts: [], time: 0.9, optionHeld: false)] + arm(2) + [frame(2.5, x: 0.8)]
        var received: [GestureEvent] = []
        var visited = 0
        let events = frames.lazy.compactMap { frame in
            visited += 1
            return recognizer.update(frame.contacts, time: frame.time, optionHeld: frame.optionHeld)
        }
        processGesturePreviewBatch(events) { event in
            received.append(event)
            // The app cancels the same recognizer here, before it reads the next frame.
            if event == .cancelled { _ = recognizer.cancel() }
        }
        #expect(visited == frames.count)
        if resize {
            guard case .resizeBegan(let change) = received.first else { Issue.record("Missing resize begin"); return }
            #expect(abs(change - 1.0 / 3) < 0.000001)
        } else {
            #expect(received.first == .began(CGPoint(x: 0.5, y: 0.5)))
        }
        #expect(Array(received.dropFirst()) == [.cancelled, .began(CGPoint(x: 0.5, y: 0.5)), .moved(CGPoint(x: 0.8, y: 0.5))])
    }

    @Test func lifecycleHandlerCanCancelBeforeTheNextFrameIsRecognized() {
        var recognizer = GestureRecognizer()
        let frames = arm() + [frame(0.5, x: 0.6), frame(0.6, x: 0.7)]
        var visited = 0
        var received: [GestureEvent] = []
        let events = frames.lazy.compactMap { frame in
            visited += 1
            return recognizer.update(frame.contacts, time: frame.time, optionHeld: frame.optionHeld)
        }
        processGesturePreviewBatch(events) { event in
            received.append(event)
            #expect(visited == 3)
            _ = recognizer.cancel()
        }
        #expect(visited == frames.count)
        #expect(received == [.began(CGPoint(x: 0.5, y: 0.5))])
    }

    @Test(arguments: [false, true], [nil, GestureEvent.released, .cancelled]) @MainActor
    func delayedSnapshotConsumerGetsLatestStateUnlessTerminated(resize: Bool, terminal: GestureEvent?) async {
        var recognizer = GestureRecognizer()
        var latest: GestureEvent?
        var presented: GestureEvent?
        var active = false
        var frames = resize
            ? [frame(0, radius: 0.15, resize: true), frame(0.1, radius: 0.12, resize: true),
               frame(0.2, radius: 0.11, resize: true), frame(0.3, radius: 0.09, resize: true)]
            : arm() + [frame(0.5, x: 0.6), frame(0.6, x: 0.75)]
        if let terminal {
            frames.append(terminal == .released ? .init(contacts: [], time: 0.7, optionHeld: resize)
                          : .init(contacts: [], time: .nan, optionHeld: resize))
        }
        // A delayed snapshot consumes the retained value on the main queue, as begin() does.
        processGesturePreviewBatch(frames.lazy.compactMap { recognizer.update($0.contacts, time: $0.time, optionHeld: $0.optionHeld) }) {
            switch $0 {
            case .began, .resizeBegan:
                active = true
                latest = $0
                DispatchQueue.main.async { if active { presented = latest } }
            case .moved, .resized: latest = $0
            case .released, .cancelled: active = false
            }
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        if terminal != nil {
            #expect(presented == nil)
            return
        }
        if resize {
            guard case .resized(let change) = presented else { Issue.record("Missing final resize"); return }
            #expect(abs(change - 0.4) < 0.000001)
        } else {
            #expect(presented == .moved(CGPoint(x: 0.75, y: 0.5)))
        }
        // An empty tick cannot replay pending work after the consumer clears its preview.
        latest = nil
        _ = recognizer.cancel()
        processGesturePreviewBatch([GestureEvent]()) { latest = $0 }
        #expect(latest == nil)
    }
}
