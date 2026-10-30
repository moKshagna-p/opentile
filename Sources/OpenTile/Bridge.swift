import Foundation
import CoreGraphics
import OpenTileC
import OpenTileCore

/// The callback only copies values. AppKit and gesture processing stay on the main thread.
final class TouchBridge {
    struct Frame { let contacts: [Contact]; let time: Double; let optionHeld: Bool }
    private static let lock = NSLock()
    private static var frames: [Frame] = []
    private static var accepting = false
    private static var engaged = false
    private static var gate = TouchFrameGate()
    private static var onFrames: (() -> Void)?
    private static let modifierMask: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
    private var device: MTDeviceRef?

    func start(onFrames: @escaping () -> Void) -> Bool {
        guard device == nil else { return true }
        guard let device = MTDeviceCreateDefault() else { return false }
        self.device = device
        Self.lock.lock()
        Self.frames = []
        Self.accepting = true
        Self.engaged = false
        Self.gate = TouchFrameGate()
        Self.onFrames = onFrames
        Self.lock.unlock()
        MTRegisterContactFrameCallback(device, { _, touches, count, time, _ in
            guard count >= 0, count <= 16, count == 0 || touches != nil else { return 0 }
            var contacts: [Contact] = []
            if let touches {
                for i in 0..<Int(count) where (1...4).contains(touches[i].state) {
                    let t = touches[i]
                    contacts.append(Contact(id: Int(t.identifier), x: Double(t.x), y: Double(t.y)))
                }
            }
            TouchBridge.lock.lock()
            let admitted = TouchBridge.accepting && TouchBridge.gate.admits(count: contacts.count, time: time, engaged: TouchBridge.engaged) {
                !CGEventSource.flagsState(.combinedSessionState).intersection(TouchBridge.modifierMask).isEmpty
            }
            if admitted {
                if TouchBridge.frames.isEmpty {
                    DispatchQueue.main.async {
                        TouchBridge.lock.lock()
                        let notify = TouchBridge.onFrames
                        TouchBridge.lock.unlock()
                        notify?()
                    }
                }
                // Overflow is a cancellation, never an accidental drop.
                if TouchBridge.frames.count >= 256 {
                    TouchBridge.frames = [.init(contacts: [], time: .nan, optionHeld: false)]
                }
                TouchBridge.frames.append(.init(contacts: contacts, time: time, optionHeld: CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate)))
            }
            TouchBridge.lock.unlock()
            return 0
        })
        MTDeviceStart(device, 0)
        return true
    }

    /// Set by the main thread while a gesture or drawing needs every frame.
    func setEngaged(_ engaged: Bool) {
        Self.lock.lock()
        Self.engaged = engaged
        Self.lock.unlock()
    }

    func drain() -> [Frame] {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let result = Self.frames
        Self.frames.removeAll(keepingCapacity: true)
        return result
    }

    func stop() {
        Self.lock.lock()
        Self.accepting = false
        Self.onFrames = nil
        Self.frames = []
        Self.lock.unlock()
        if let device { MTDeviceStop(device); MTDeviceRelease(device) }
        device = nil
    }
    deinit { stop() }
}
