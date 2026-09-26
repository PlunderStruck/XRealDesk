import CoreGraphics
import os

/// CGDisplayBounds asks WindowServer every time (~0.4 ms of its time each). The cursor code needs
/// the bounds 60×/s; they only change when displays are reconfigured, so cache them until then.
enum DisplayBoundsCache {
    private static let cache = OSAllocatedUnfairLock(initialState: [CGDirectDisplayID: CGRect]())
    private static let registered: Bool = {
        CGDisplayRegisterReconfigurationCallback({ _, _, _ in
            DisplayBoundsCache.cache.withLock { $0.removeAll() }
        }, nil)
        return true
    }()

    static func bounds(_ id: CGDirectDisplayID) -> CGRect {
        _ = registered
        if let b = cache.withLock({ $0[id] }) { return b }
        let b = CGDisplayBounds(id)
        cache.withLock { $0[id] = b }
        return b
    }
}
