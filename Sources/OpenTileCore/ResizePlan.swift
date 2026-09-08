import Foundation
import CoreGraphics

/// A bounded relative resize on the tile's parent axis. AeroSpace sets final geometry.
public struct ResizePlan {
    public let amount: Int
    public let preview: CGRect
    public let horizontal: Bool

    public init(frame: CGRect, layout: String, change: Double) {
        horizontal = layout == "h_tiles"
        let size = horizontal ? frame.width : frame.height
        guard ["h_tiles", "v_tiles"].contains(layout), change.isFinite,
              size.isFinite, size > 0 else {
            amount = 0
            preview = frame
            return
        }
        // Limit each gesture to 40%; don't request a dimension below 160 points.
        let delta = max(min(0, 160 - size), max(-0.4, min(0.4, change)) * size)
        amount = Int(delta.rounded(.towardZero))
        preview = frame.insetBy(dx: horizontal ? -Double(amount) / 2 : 0,
                                dy: horizontal ? 0 : -Double(amount) / 2)
    }

    public func command(windowID: Int) -> [String]? {
        guard amount != 0 else { return nil }
        return ["resize", "--window-id", "\(windowID)", "smart", amount > 0 ? "+\(amount)" : "\(amount)"]
    }
}
