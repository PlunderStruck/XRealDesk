import Foundation
import simd

/// Everything we need from the factory calibration blob stored on the glasses, already
/// converted into the head frame used by the rest of the app.
///
/// Head frame (right-handed, same as the render world): +X right, +Y up, +Z backward (you look down -Z).
///
/// Raw sensor axes on the Air family: +X left, +Y backward, +Z up (verified: a level, still
/// headset reads accel ≈ (0, 0, +1 g)). So head = (-raw.x, raw.z, raw.y).
///
/// The factory JSON stores biases in the driver's "pre" frame, which is (-raw.x, -raw.z, -raw.y);
/// head = diag(1, -1, -1) · pre.
public struct GlassesCalibration: Sendable {
    /// Gyro bias in the head frame, rad/s.
    public var gyroBias: SIMD3<Float> = .zero
    /// Accelerometer bias in the head frame, g.
    public var accelBias: SIMD3<Float> = .zero
    /// Rotation that aligns the gyro to the accelerometer, head frame.
    public var gyroAlignment: simd_float3x3 = matrix_identity_float3x3

    /// Display intrinsics (pixels) for the rendered 1920x1080 image; averaged over both eyes.
    public var focalX: Float = 2697
    public var focalY: Float = 2711
    public var centerX: Float = 960
    public var centerY: Float = 540
    public var resolution = SIMD2<Float>(1920, 1080)

    public var isFactory = false

    /// Factory lens-distortion map (average of both eyes), if present.
    public var distortion: DistortionGrid?

    /// Per-eye calibration for stereo rendering: [left, right].
    public var eyes: [Eye] = []

    public struct Eye: Sendable {
        public var focal: SIMD2<Float>
        public var center: SIMD2<Float>
        /// Eye position relative to the midpoint between the eyes, head frame (metres).
        public var offset: SIMD3<Float>
        /// Display orientation in the head frame (includes the factory toe-in).
        public var rotation: simd_quatf
        public var distortion: DistortionGrid?
    }

    /// Distance (m) at which the two displays' optical axes converge (from the factory toe-in).
    public var convergenceDistance: Float? {
        guard eyes.count == 2 else { return nil }
        let ipd = simd_length(eyes[1].offset - eyes[0].offset)
        let fl = eyes[0].rotation.act(SIMD3(0, 0, -1)), fr = eyes[1].rotation.act(SIMD3(0, 0, -1))
        let toeIn = atan2(fl.x, -fl.z) - atan2(fr.x, -fr.z)   // how much the left looks right of the right
        guard toeIn > 1e-4 else { return nil }
        return ipd / (2 * tan(toeIn / 2))
    }

    /// Head frame → eye `i`'s display frame (0 = left, 1 = right) for side-by-side 3D.
    ///
    /// Deliberately symmetric: each eye sits half the factory eye separation off centre and its
    /// display is turned inward to meet at the factory convergence distance. Both eyes otherwise
    /// use the same (average) intrinsics and lens map as 2D. The per-eye extrinsics in the blob
    /// did not match its own left/right naming on a real Air 2 Pro (the left half of the picture
    /// reaches the left eye, verified by eye test, yet the "left" values only looked right
    /// swapped), and using them produced a warp on every head turn.
    public func eyeView(_ i: Int) -> simd_float4x4 {
        let side: Float = i == 0 ? -1 : 1
        let ipd = eyes.count == 2 ? simd_length(eyes[1].offset - eyes[0].offset) : 0.063
        let toeIn = atan(ipd / 2 / (convergenceDistance ?? 3.6))
        return simd_float4x4(SpatialMath.rotationY(side * toeIn).inverse)
            * SpatialMath.translation(SIMD3(-side * ipd / 2, 0, 0))
    }

    public init() {}

    /// A corrupted download (flaky cable, truncated blob) must never produce a picture or tracking
    /// that is wildly off: every value outside what real hardware can have falls back to the default.
    mutating func sanitize() {
        let d = GlassesCalibration()
        func ok(_ v: Float, _ range: ClosedRange<Float>) -> Bool { v.isFinite && range.contains(v) }
        if !(ok(resolution.x, 320...8192) && ok(resolution.y, 240...8192)) { resolution = d.resolution }
        if !(ok(focalX, resolution.x * 0.3...resolution.x * 10) && ok(focalY, resolution.y * 0.3...resolution.y * 20)) {
            focalX = d.focalX; focalY = d.focalY
        }
        if !(ok(centerX, 0...resolution.x) && ok(centerY, 0...resolution.y)) { centerX = resolution.x / 2; centerY = resolution.y / 2 }
        let finiteVec = { (v: SIMD3<Float>) in v.x.isFinite && v.y.isFinite && v.z.isFinite }
        if !finiteVec(gyroBias) || simd_length(gyroBias) > 0.2 { gyroBias = d.gyroBias }        // > ~11 °/s: not a bias
        if !finiteVec(accelBias) || simd_length(accelBias) > 0.2 { accelBias = d.accelBias }     // > 0.2 g
        let a = gyroAlignment
        let orthonormal = [a.columns.0, a.columns.1, a.columns.2].allSatisfy { finiteVec($0) && abs(simd_length($0) - 1) < 0.05 }
            && abs(simd_determinant(a) - 1) < 0.1
        if !orthonormal { gyroAlignment = d.gyroAlignment }
    }

    public static func headFromRaw(_ v: SIMD3<Float>) -> SIMD3<Float> { SIMD3(-v.x, v.z, v.y) }
    static func headFromPre(_ v: SIMD3<Float>) -> SIMD3<Float> { SIMD3(v.x, -v.y, -v.z) }

    /// Horizontal / vertical field of view in degrees implied by the intrinsics.
    public var fovDegrees: SIMD2<Float> {
        SIMD2(2 * atan(resolution.x / 2 / focalX), 2 * atan(resolution.y / 2 / focalY)) * (180 / .pi)
    }

    /// Parse the JSON blob downloaded from the IMU interface. Missing fields keep defaults.
    public static func parse(json data: Data) -> GlassesCalibration? {
        // The blob occasionally carries trailing NULs / garbage after the closing brace.
        var bytes = data
        if let end = bytes.lastIndex(of: UInt8(ascii: "}")) { bytes = bytes.prefix(through: end) }
        guard let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return nil }

        var cal = GlassesCalibration()
        cal.isFactory = true

        if let imu = (root["IMU"] as? [String: Any])?["device_1"] as? [String: Any] {
            if let b = vec3(imu["gyro_bias"]) { cal.gyroBias = headFromPre(b) }
            if let b = vec3(imu["accel_bias"]) { cal.accelBias = headFromPre(b) / 9.806 }
            if let q = quat(imu["accel_q_gyro"]) {
                // R expressed in pre frame; conjugate by D = diag(1,-1,-1) to express in head frame.
                let r = simd_float3x3(q)
                let d = simd_float3x3(diagonal: SIMD3(1, -1, -1))
                cal.gyroAlignment = d * r * d
            }
        }

        if let display = root["display"] as? [String: Any] {
            let kl = floats(display["k_left_display"])
            let kr = floats(display["k_right_display"])
            let ks = [kl, kr].compactMap { $0 }.filter { $0.count == 9 }
            if !ks.isEmpty {
                let n = Float(ks.count)
                cal.focalX = ks.map { $0[0] }.reduce(0, +) / n
                cal.centerX = ks.map { $0[2] }.reduce(0, +) / n
                cal.focalY = ks.map { $0[4] }.reduce(0, +) / n
                cal.centerY = ks.map { $0[5] }.reduce(0, +) / n
            }
            if let res = floats(display["resolution"]), res.count == 2 {
                cal.resolution = SIMD2(res[0], res[1])
            }
        }
        cal.sanitize()
        var perEyeGrids: [DistortionGrid?] = [nil, nil]
        if let dd = root["display_distortion"] as? [String: Any] {
            perEyeGrids = ["left_display", "right_display"].map { DistortionGrid.parse(dd[$0]) }
            cal.distortion = DistortionGrid.average(perEyeGrids.compactMap { $0 })
        }
        if let display = root["display"] as? [String: Any] {
            // Factory values are in the IMU "pre" frame (x right, y down, z forward);
            // head frame = diag(1, -1, -1) · pre, i.e. a 180° rotation about x.
            let flip = simd_quatf(ix: 1, iy: 0, iz: 0, r: 0)
            var eyes: [Eye] = []
            var positions: [SIMD3<Float>] = []
            for (i, side) in ["left", "right"].enumerated() {
                guard let k = floats(display["k_\(side)_display"]), k.count == 9,
                      let p = vec3(display["target_p_\(side)_display"]),
                      let q = quat(display["target_q_\(side)_display"]) else { eyes = []; break }
                positions.append(headFromPre(p))
                eyes.append(Eye(focal: SIMD2(k[0], k[4]), center: SIMD2(k[2], k[5]), offset: .zero,
                                rotation: (flip * q * flip.inverse).normalized, distortion: perEyeGrids[i]))
            }
            if eyes.count == 2 {
                let mid = (positions[0] + positions[1]) / 2
                let ipd = simd_length(positions[1] - positions[0])
                if (0.045...0.085).contains(ipd) {   // sane human IPD, else don't trust stereo data
                    for i in 0..<2 { eyes[i].offset = positions[i] - mid }
                    cal.eyes = eyes
                }
            }
        }
        // Sanity: reject absurd intrinsics rather than render garbage.
        let fov = cal.fovDegrees
        if !(20...70).contains(fov.x) || !(10...50).contains(fov.y) {
            let d = GlassesCalibration()
            cal.focalX = d.focalX; cal.focalY = d.focalY; cal.centerX = d.centerX; cal.centerY = d.centerY
            cal.resolution = d.resolution
        }
        return cal
    }

    /// Apply calibration to a raw sample. Returns head-frame gyro (rad/s) and accel (g).
    public func correct(_ s: XRealProtocol.RawIMUSample) -> (gyro: SIMD3<Float>, accel: SIMD3<Float>) {
        let g = GlassesCalibration.headFromRaw(s.gyro) * (.pi / 180)
        let a = GlassesCalibration.headFromRaw(s.accel)
        return (gyroAlignment * (g - gyroBias), a - accelBias)
    }

    private static func floats(_ any: Any?) -> [Float]? {
        (any as? [Any])?.compactMap { ($0 as? NSNumber)?.floatValue }
    }
    private static func vec3(_ any: Any?) -> SIMD3<Float>? {
        guard let f = floats(any), f.count == 3 else { return nil }
        return SIMD3(f[0], f[1], f[2])
    }
    private static func quat(_ any: Any?) -> simd_quatf? {
        guard let f = floats(any), f.count == 4 else { return nil }
        let q = simd_quatf(ix: f[0], iy: f[1], iz: f[2], r: f[3])
        return q.length > 0.5 ? q.normalized : nil
    }
}

/// The glasses' factory display-distortion map: for points on a (non-uniform) grid of display
/// pixels, where in the ideal pinhole image that pixel should show. Rendering "ideal" then warping
/// through this map puts every pixel where the optics expect it, so content is correctly placed
/// (and world-locked) all the way to the edges, not just in the middle.
public struct DistortionGrid: Sendable {
    public let us: [Float]          // column positions (display px), ascending
    public let vs: [Float]          // row positions (display px), ascending
    public let xy: [SIMD2<Float>]   // ideal-image position per grid point, row-major

    static func parse(_ any: Any?) -> DistortionGrid? {
        guard let d = any as? [String: Any], (d["type"] as? NSNumber)?.intValue == 1,
              let cols = (d["num_col"] as? NSNumber)?.intValue, let rows = (d["num_row"] as? NSNumber)?.intValue,
              (2...512).contains(cols), (2...512).contains(rows),   // before multiplying: corrupt sizes can overflow
              let raw = (d["data"] as? [Any])?.compactMap({ ($0 as? NSNumber)?.floatValue }),
              raw.count == cols * rows * 4, raw.allSatisfy({ $0.isFinite }) else { return nil }
        var us: [Float] = [], vs: [Float] = [], xy: [SIMD2<Float>] = []
        for r in 0..<rows {
            for c in 0..<cols {
                let i = (r * cols + c) * 4
                if r == 0 { us.append(raw[i]) }
                if c == 0 { vs.append(raw[i + 1]) }
                // Rectilinear grid check: every row shares the column positions and vice versa.
                guard abs(raw[i] - (r == 0 ? raw[i] : us[c])) < 0.01, abs(raw[i + 1] - vs[r]) < 0.01 else { return nil }
                xy.append(SIMD2(raw[i + 2], raw[i + 3]))
            }
        }
        guard zip(us, us.dropFirst()).allSatisfy({ $0 < $1 }), zip(vs, vs.dropFirst()).allSatisfy({ $0 < $1 }) else { return nil }
        // Sanity: displacement must be modest; anything wild means a format we don't understand.
        let maxShift = zip(xy.indices, xy).map { i, p in simd_length(p - SIMD2(us[i % cols], vs[i / cols])) }.max() ?? 0
        guard maxShift < 80 else { return nil }
        return DistortionGrid(us: us, vs: vs, xy: xy)
    }

    static func average(_ grids: [DistortionGrid]) -> DistortionGrid? {
        guard let first = grids.first else { return nil }
        let same = grids.allSatisfy { $0.us == first.us && $0.vs == first.vs }
        guard same else { return first }
        var xy = first.xy
        for g in grids.dropFirst() { for i in xy.indices { xy[i] += g.xy[i] } }
        return DistortionGrid(us: first.us, vs: first.vs, xy: xy.map { $0 / Float(grids.count) })
    }

    /// Ideal-image position for display pixel (u, v), bilinear within the grid (clamped at edges).
    public func sample(_ u: Float, _ v: Float) -> SIMD2<Float> {
        func locate(_ a: [Float], _ x: Float) -> (Int, Float) {
            if x <= a[0] { return (0, 0) }
            if x >= a[a.count - 1] { return (a.count - 2, 1) }
            var lo = 0, hi = a.count - 1
            while hi - lo > 1 { let m = (lo + hi) / 2; if a[m] <= x { lo = m } else { hi = m } }
            return (lo, (x - a[lo]) / (a[lo + 1] - a[lo]))
        }
        let (c, fx) = locate(us, u), (r, fy) = locate(vs, v)
        let cols = us.count
        let p00 = xy[r * cols + c], p10 = xy[r * cols + c + 1]
        let p01 = xy[(r + 1) * cols + c], p11 = xy[(r + 1) * cols + c + 1]
        return (p00 * (1 - fx) + p10 * fx) * (1 - fy) + (p01 * (1 - fx) + p11 * fx) * fy
    }

    /// Resample onto a uniform grid (for a GPU lookup texture). Point (i, j) is display pixel
    /// (i·step, j·step).
    public func uniformMap(width: Int, height: Int, step: Float) -> (w: Int, h: Int, values: [SIMD2<Float>]) {
        let w = Int((Float(width) / step).rounded(.up)) + 1, h = Int((Float(height) / step).rounded(.up)) + 1
        var out = [SIMD2<Float>](repeating: .zero, count: w * h)
        for j in 0..<h { for i in 0..<w { out[j * w + i] = sample(Float(i) * step, Float(j) * step) } }
        return (w, h, out)
    }
}
