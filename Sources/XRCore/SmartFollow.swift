import Foundation
import simd

/// "Smart" anchoring: the layout stays fixed while you look anywhere inside its outer edge (so you
/// can look around every screen freely). Look past the edge of the group, on any side, and it
/// glides after you smoothly, keeping its edge where you're looking.
/// Optionally, a quick head flick carries the layout along (reposition by flicking).
///
/// Works on yaw/pitch of the head and of the layout anchor (radians; yaw + = left, pitch + = up).
public struct SmartFollow: Sendable {
    /// 0 = only very fast flicks move the screens, 1 = gentle flicks do.
    public var sensitivity: Float = 0.5
    public var flickEnabled = false
    /// Follow lag once you're past the edge (seconds; smaller = snappier).
    public var followLag: Float = 0.3
    /// How far (radians) you may look past the group's outer edge before it starts to follow.
    public var edgeMargin = SIMD2<Float>(SpatialMath.radians(2), SpatialMath.radians(2))

    private var lastHead: SIMD2<Float>?

    public init() {}

    public mutating func reset() { lastHead = nil }

    /// Head speed (rad/s) where a flick starts to carry the layout, and where it carries it fully.
    public var flickRange: (start: Float, full: Float) {
        let s = min(max(sensitivity, 0), 1)
        let start = SpatialMath.radians(260 + (90 - 260) * s)   // 260°/s … 90°/s
        return (start, start * 2)
    }

    /// - Returns: the new anchor (yaw, pitch).
    public mutating func update(head: SIMD2<Float>, anchor: SIMD2<Float>, layout: ScreenLayout, dt: Float) -> SIMD2<Float> {
        var a = anchor
        if flickEnabled, let last = lastHead, dt > 0 {
            let delta = SIMD2(SmartFollow.wrap(head.x - last.x), head.y - last.y)
            let speed = abs(delta) / dt
            let (start, full) = flickRange
            // Vertical flicks are naturally slower; scale their thresholds down a bit.
            let carryYaw = SmartFollow.smoothstep(start, full, speed.x)
            let carryPitch = SmartFollow.smoothstep(start * 0.8, full * 0.8, speed.y)
            a.x += delta.x * carryYaw
            a.y += delta.y * carryPitch
        }
        lastHead = head

        // Past the group's edge: glide after the gaze so the edge stays where you're looking.
        if let ext = SmartFollow.extents(layout), dt > 0 {
            let g = SIMD2(SmartFollow.wrap(head.x - a.x), head.y - a.y)
            let k = 1 - exp(-dt / max(followLag, 0.02))
            if g.x > ext.maxYaw + edgeMargin.x { a.x += (g.x - ext.maxYaw - edgeMargin.x) * k }
            if g.x < ext.minYaw - edgeMargin.x { a.x += (g.x - ext.minYaw + edgeMargin.x) * k }
            if g.y > ext.maxPitch + edgeMargin.y { a.y += (g.y - ext.maxPitch - edgeMargin.y) * k }
            if g.y < ext.minPitch - edgeMargin.y { a.y += (g.y - ext.minPitch + edgeMargin.y) * k }
        }
        a.x = SmartFollow.wrap(a.x)
        a.y = min(max(a.y, -1.3), 1.3)
        return a
    }

    /// Angular extents of the layout relative to its anchor.
    public static func extents(_ layout: ScreenLayout) -> (minYaw: Float, maxYaw: Float, minPitch: Float, maxPitch: Float)? {
        guard !layout.panels.isEmpty else { return nil }
        var e = (minYaw: Float.infinity, maxYaw: -Float.infinity, minPitch: Float.infinity, maxPitch: -Float.infinity)
        for p in layout.panels {
            let hw = atan(p.size.x / 2 / layout.distance), hh = atan(p.size.y / 2 / layout.distance)
            e.minYaw = min(e.minYaw, p.yaw - hw); e.maxYaw = max(e.maxYaw, p.yaw + hw)
            e.minPitch = min(e.minPitch, p.pitch - hh); e.maxPitch = max(e.maxPitch, p.pitch + hh)
        }
        return e
    }

    static func wrap(_ a: Float) -> Float {
        var x = a
        while x > .pi { x -= 2 * .pi }
        while x < -.pi { x += 2 * .pi }
        return x
    }

    static func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
