import Foundation
import simd

public enum SpatialMath {
    public static func radians(_ deg: Float) -> Float { deg * .pi / 180 }
    public static func degrees(_ rad: Float) -> Float { rad * 180 / .pi }

    public static func rotationY(_ a: Float) -> simd_quatf { simd_quatf(angle: a, axis: SIMD3(0, 1, 0)) }
    public static func rotationX(_ a: Float) -> simd_quatf { simd_quatf(angle: a, axis: SIMD3(1, 0, 0)) }

    /// Yaw (left positive) and pitch (up positive) of where an orientation is looking.
    public static func yawPitch(of q: simd_quatf) -> (yaw: Float, pitch: Float) {
        let f = q.act(SIMD3(0, 0, -1))
        return (atan2(-f.x, -f.z), asin(max(-1, min(1, f.y))))
    }

    /// Orientation looking at yaw/pitch with no roll.
    public static func orientation(yaw: Float, pitch: Float) -> simd_quatf {
        rotationY(yaw) * rotationX(pitch)
    }

    public static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t.x, t.y, t.z, 1)
        return m
    }

    public static func scale(_ s: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(diagonal: SIMD4(s.x, s.y, s.z, 1))
    }

    /// Off-axis perspective projection built from pinhole intrinsics, Metal clip space (z in 0...1).
    /// `viewport` is the drawable size in pixels; intrinsics are rescaled if it differs from `calibrated`.
    public static func projection(focal: SIMD2<Float>, center: SIMD2<Float>, calibrated: SIMD2<Float>,
                                  viewport: SIMD2<Float>, near: Float = 0.05, far: Float = 100) -> simd_float4x4 {
        let s = viewport / calibrated
        let fx = focal.x * s.x, fy = focal.y * s.y
        let cx = center.x * s.x, cy = center.y * s.y
        let w = viewport.x, h = viewport.y
        // Frustum extents at the near plane (image y grows downward).
        let l = -cx / fx * near, r = (w - cx) / fx * near
        let t = cy / fy * near, b = -(h - cy) / fy * near
        return simd_float4x4(columns: (
            SIMD4(2 * near / (r - l), 0, 0, 0),
            SIMD4(0, 2 * near / (t - b), 0, 0),
            SIMD4((r + l) / (r - l), (t + b) / (t - b), far / (near - far), -1),
            SIMD4(0, 0, near * far / (near - far), 0)
        ))
    }
}

/// Where the virtual screens sit around the user, in the anchor frame (anchor looks down -Z).
///
/// Screens live on a vertical cylinder. `curve` 0 is a flat wall; 1 wraps the cylinder around the
/// viewer (every point on a row equidistant, like sitting inside a curved ultrawide). Each screen is
/// bent to the cylinder, not just placed on it, so it reads as a real curved monitor.
public struct ScreenLayout: Sendable, Equatable {
    public struct Panel: Sendable, Equatable {
        public var index: Int
        /// Horizontal position of the panel centre, as arc length along the cylinder.
        public var arcCenter: Float
        /// Vertical position of the panel centre (before the layout tilt).
        public var height: Float
        public var size: SIMD2<Float>
        /// 3D centre in the anchor frame (after tilt) and the direction to it.
        public var center: SIMD3<Float>
        public var yaw: Float
        public var pitch: Float
    }

    public var panels: [Panel] = []
    public var distance: Float = 1.5
    public var curve: Float = 0.6
    /// Whole-layout vertical offset (radians, + = up), e.g. to sit screens a bit below eye level.
    public var tilt: Float = 0

    public init() {}

    /// Cylinder radius (infinite when flat).
    public var radius: Float { curve < 1e-3 ? .infinity : distance / curve }

    /// Rotation applied to the whole layout (the tilt).
    public var tiltRotation: simd_quatf { SpatialMath.rotationX(tilt) }

    /// Visual rows/columns for a screen count; the bottom row is filled first.
    public static func grid(count: Int, rows: Int) -> [(row: Int, col: Int, colsInRow: Int)] {
        let rows = max(1, min(rows, count))
        let perRow = Int((Double(count) / Double(rows)).rounded(.up))
        var out: [(Int, Int, Int)] = []
        var remaining = count
        for r in 0..<rows {
            let n = min(perRow, remaining)
            for c in 0..<n { out.append((r, c, n)) }
            remaining -= n
        }
        return out
    }

    /// - Parameters:
    ///   - widthDegrees: angular width of each screen seen straight on
    ///   - aspect: width / height of each screen
    ///   - gapDegrees: gap between neighbours
    ///   - curve: 0 flat … 1 fully wrapped
    ///   - tiltDegrees: raise (+) or lower (−) the whole layout
    public init(count: Int, rows: Int, widthDegrees: Float, aspect: Float, gapDegrees: Float,
                curve: Float, tiltDegrees: Float = 0, distance: Float = 1.5) {
        // Anything a slider, a preset or a corrupted preference could hand us stays in a range that
        // gives real geometry (180° screens have infinite width, aspect 0 infinite height, …).
        func clamp(_ v: Float, _ lo: Float, _ hi: Float, _ fallback: Float) -> Float { v.isFinite ? min(max(v, lo), hi) : fallback }
        let d = clamp(distance, 0.2, 20, 1.5)
        self.distance = d
        self.tilt = SpatialMath.radians(clamp(tiltDegrees, -85, 85, 0))
        let w = 2 * d * tan(SpatialMath.radians(clamp(widthDegrees, 1, 150, 33)) / 2)
        let h = w / clamp(aspect, 0.2, 20, 16.0 / 9)
        let gap = d * SpatialMath.radians(clamp(gapDegrees, 0, 30, 1.5))
        let cells = ScreenLayout.grid(count: max(count, 0), rows: max(rows, 1))
        // A row that can't fit around you (e.g. 8 wide screens fully curved) would overlap itself
        // behind your back: open the curve just enough that the widest row spans at most ~340°.
        var c = clamp(curve, 0, 1, 0.6)
        let widestRow = Float(cells.map(\.colsInRow).max() ?? 0)
        let rowArc = widestRow * w + max(widestRow - 1, 0) * gap
        if c > 1e-3, rowArc > 0 { c = min(c, d * 2 * .pi * 0.94 / rowArc) }
        self.curve = c
        let rowCount = (cells.map(\.row).max() ?? 0) + 1
        for (i, cell) in cells.enumerated() {
            let colOffset = Float(cell.col) - Float(cell.colsInRow - 1) / 2   // left → right
            let rowOffset = Float(cell.row) - Float(rowCount - 1) / 2          // bottom → top
            let s0 = colOffset * (w + gap)
            let y0 = rowOffset * (h + gap)
            let c = point(arc: s0, height: y0)
            panels.append(Panel(index: i, arcCenter: s0, height: y0, size: SIMD2(w, h), center: c,
                                yaw: atan2(-c.x, -c.z), pitch: atan2(c.y, simd_length(SIMD2(c.x, c.z)))))
        }
    }

    /// Surface point for arc position `s` and height `y` (before tilt).
    public func untiltedPoint(arc s: Float, height y: Float) -> SIMD3<Float> {
        let r = radius
        guard r.isFinite else { return SIMD3(s, y, -distance) }
        let theta = s / r
        return SIMD3(r * sin(theta), y, (r - distance) - r * cos(theta))
    }

    /// Surface point in the anchor frame (tilt applied).
    public func point(arc s: Float, height y: Float) -> SIMD3<Float> {
        tiltRotation.act(untiltedPoint(arc: s, height: y))
    }

    /// Which panel a ray from the origin along `direction` (anchor frame) hits, with UV in 0...1
    /// (u left→right, v top→bottom).
    public func hit(direction: SIMD3<Float>, margin: Float = 0) -> (index: Int, uv: SIMD2<Float>)? {
        let d = tiltRotation.inverse.act(simd_normalize(direction))
        var s: Float, y: Float
        let r = radius
        if !r.isFinite {
            guard d.z < -1e-5 else { return nil }
            let t = -distance / d.z
            s = d.x * t; y = d.y * t
        } else {
            // Cylinder axis is vertical through (0, *, c); ray from origin.
            let c = r - distance
            let a = d.x * d.x + d.z * d.z
            guard a > 1e-8 else { return nil }
            let b = -2 * c * d.z
            let k = c * c - r * r
            let disc = b * b - 4 * a * k
            guard disc >= 0 else { return nil }
            let t = (-b + sqrt(disc)) / (2 * a)
            guard t > 0 else { return nil }
            let p = d * t
            s = r * atan2(p.x, c - p.z)
            y = p.y
        }
        for p in panels {
            let u = (s - p.arcCenter) / p.size.x + 0.5
            let v = 0.5 - (y - p.height) / p.size.y
            if u >= -margin, u <= 1 + margin, v >= -margin, v <= 1 + margin {
                return (p.index, SIMD2(min(max(u, 0), 1), min(max(v, 0), 1)))
            }
        }
        return nil
    }

    /// Panel whose centre is angularly closest to `direction`.
    public func nearest(direction: SIMD3<Float>) -> Int? {
        let d = simd_normalize(direction)
        return panels.max { simd_dot(simd_normalize($0.center), d) < simd_dot(simd_normalize($1.center), d) }?.index
    }
}
