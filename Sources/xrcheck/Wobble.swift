import Foundation
import simd
import XRCore

/// Loads a recorded IMU stream (xrcheck replay format), calibrated.
func loadIMU(csv: String, calibrationPath: String) -> (t: [Double], gyro: [SIMD3<Float>], accel: [SIMD3<Float>])? {
    guard let text = try? String(contentsOfFile: csv, encoding: .utf8),
          let calData = FileManager.default.contents(atPath: calibrationPath),
          let cal = GlassesCalibration.parse(json: calData) else { return nil }
    var t: [Double] = [], gy: [SIMD3<Float>] = [], ac: [SIMD3<Float>] = []
    var t0: UInt64 = 0
    for line in text.split(separator: "\n").dropFirst() {
        let f = line.split(separator: ",")
        guard f.count == 7, let ns = UInt64(f[0]) else { continue }
        let v = f[1...].compactMap { Float($0) }
        guard v.count == 6 else { continue }
        if t0 == 0 { t0 = ns }
        guard ns >= t0, t.last.map({ Double(ns - t0) / 1e9 > $0 }) ?? true else { continue }
        let raw = XRealProtocol.RawIMUSample(timestampNs: ns, gyro: SIMD3(v[0], v[1], v[2]), accel: SIMD3(v[3], v[4], v[5]), temperatureC: 30)
        let (g, a) = cal.correct(raw)
        t.append(Double(ns - t0) / 1e9); gy.append(g); ac.append(a)
    }
    return (t, gy, ac)
}

/// How much the gravity (tilt) correction itself moves the view. The gyro alone tracks the head
/// almost perfectly over a second or two; any extra rotation the filter adds on top within that
/// time is the accelerometer being fooled by body motion (leaning, shifting, walking), and shows
/// up as the screens tilting or bobbing although the head didn't rotate.
func wobble(csv: String, calibrationPath: String) {
    guard let d = loadIMU(csv: csv, calibrationPath: calibrationPath) else { print("can't read inputs"); return }
    print(String(format: "%d samples (%.1f s)", d.t.count, d.t.last ?? 0))
    var variants: [(String, OrientationFilter.Settings)] = []
    let base = OrientationFilter.Settings()
    var old = base; old.motionGateLow = 0; old.motionGateHigh = 0; old.presentStillRate = 1e4
    variants.append(("old", old))
    var gatedOnly = base; gatedOnly.presentStillRate = 1e4
    variants.append(("gate only", gatedOnly))
    var presOnly = base; presOnly.motionGateLow = 0; presOnly.motionGateHigh = 0
    variants.append(("presentation only", presOnly))
    variants.append(("gated", base))
    var slower = base; slower.presentMotionRate = 0.8
    variants.append(("gated, motion rate 0.8", slower))
    for (name, s) in variants {
        var f = OrientationFilter(settings: s)
        var inj05: [Float] = [], inj02: [Float] = []
        var gyroOnly = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), windowStart = 0.0
        var gyroOnly2 = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), windowStart2 = 0.0
        var tiltTrace: [Float] = []   // pitch/roll relative to the gyro-only path, per 10 ms
        var still: [Float] = [], slow: [Float] = [], fast: [Float] = []   // 0.2 s windows by head speed
        var turned: Float = 0
        var apart: [Float] = []   // presented vs estimate
        for i in d.t.indices {
            let dt = i > 0 ? Float(d.t[i] - d.t[i - 1]) : 0.001
            f.update(gyro: d.gyro[i], accel: d.accel[i], dt: dt)
            guard f.initialized, d.t[i] > 3 else { continue }
            // Gyro-only path from the filter's state at the window start, same bias correction.
            let w = f.angularVelocity, a = simd_length(w) * min(max(dt, 0), 0.02)
            if a > 1e-9 { gyroOnly = (gyroOnly * simd_quatf(angle: a, axis: w / simd_length(w))).normalized
                          gyroOnly2 = (gyroOnly2 * simd_quatf(angle: a, axis: w / simd_length(w))).normalized }
            turned += a
            if ProcessInfo.processInfo.environment["XR_TRACE"] != nil, name == "gated", i % 2000 == 0 {
                let tb = f.tiltBias * 180 / .pi, lb = f.learnedBias * 180 / .pi
                print(String(format: "   t %5.1f level err %.2f° trust %.2f still %d tiltBias (%.3f %.3f %.3f) bias (%.3f %.3f %.3f) °/s", d.t[i], deg(f.tiltError), f.gravityTrust, f.isStill ? 1 : 0, tb.x, tb.y, tb.z, lb.x, lb.y, lb.z))
            }
            if d.t[i] - windowStart >= 0.5 {
                if windowStart > 0 { inj05.append(deg((gyroOnly.inverse * f.presented).angle)) }
                gyroOnly = f.presented; windowStart = d.t[i]
            }
            if d.t[i] - windowStart2 >= 0.2 {
                if windowStart2 > 0 {
                    let inj = deg((gyroOnly2.inverse * f.presented).angle)
                    apart.append(deg((f.presented.inverse * f.orientation).angle))
                    inj02.append(inj)
                    let speed = deg(turned) / Float(d.t[i] - windowStart2)
                    if speed < 3 { still.append(inj) } else if speed < 20 { slow.append(inj) } else { fast.append(inj) }
                }
                turned = 0
                gyroOnly2 = f.presented; windowStart2 = d.t[i]
            }
            _ = tiltTrace
        }
        func stats(_ a: [Float]) -> String {
            let s = a.sorted()
            let rms = sqrt(a.map { $0 * $0 }.reduce(0, +) / Float(max(a.count, 1)))
            return String(format: "rms %.4f° p95 %.4f° max %.4f°", rms, s.isEmpty ? 0 : s[Int(Float(s.count) * 0.95)], s.last ?? 0)
        }
        print(String(format: "%-22@ added in 0.2 s: %@ | in 0.5 s: %@ | level within %.2f°", name as NSString,
                     stats(inj02) as NSString, stats(inj05) as NSString, deg(f.tiltError)))
        print(String(format: "%-22@   drawn vs estimate: %@", "" as NSString, stats(apart) as NSString))
        print(String(format: "%-22@   per 0.2 s while still (<3°/s, %d): %@ | moving 3-20°/s (%d): %@ | turning (%d): %@", "" as NSString,
                     still.count, stats(still) as NSString, slow.count, stats(slow) as NSString, fast.count, stats(fast) as NSString))
    }
}

/// Is there a constant accelerometer offset (head frame)? Compares the measured "up" with the
/// filter's estimate during steady moments, and how that depends on where the head points.
func accelBias(csv: String, calibrationPath: String) {
    guard let d = loadIMU(csv: csv, calibrationPath: calibrationPath) else { print("can't read inputs"); return }
    var s = OrientationFilter.Settings(); s.motionGateLow = 0; s.motionGateHigh = 0
    s.presentStillRate = 1e4
    var f = OrientationFilter(settings: s)
    var sum = SIMD3<Float>(repeating: 0), n: Float = 0
    var byYaw: [Int: (SIMD3<Float>, Float)] = [:]
    var aNormSum: Float = 0
    for i in d.t.indices {
        let dt = i > 0 ? Float(d.t[i] - d.t[i - 1]) : 0.001
        f.update(gyro: d.gyro[i], accel: d.accel[i], dt: dt)
        guard f.initialized, d.t[i] > 5, f.isStill else { continue }
        let m = simd_normalize(d.accel[i]), e = f.orientation.inverse.act(SIMD3(0, 1, 0))
        sum += m - e; n += 1; aNormSum += simd_length(d.accel[i])
        let yaw = Int((deg(SpatialMath.yawPitch(of: f.orientation).yaw) / 15).rounded()) * 15
        let (v, c) = byYaw[yaw] ?? (.zero, 0)
        byYaw[yaw] = (v + (m - e), c + 1)
    }
    guard n > 0 else { print("no steady moments"); return }
    let mean = sum / n
    print(String(format: "steady samples %d, |a| %.4f g, mean (measured − estimated up) head frame: (%.4f, %.4f, %.4f) = %.2f°",
                 Int(n), aNormSum / n, mean.x, mean.y, mean.z, deg(asin(min(1, simd_length(mean))))))
    for k in byYaw.keys.sorted() {
        let (v, c) = byYaw[k]!; let m = v / c
        print(String(format: "  yaw %4d°: %6d samples, (%.4f, %.4f, %.4f)", k, Int(c), m.x, m.y, m.z))
    }
}

/// Writes what the app's predictor sees at every sample (for fitting it offline): time, the filter's
/// bias-corrected rate (head frame, rad/s), calibrated accelerometer (head frame, g) and the
/// presented orientation (the screens' truth).
func dumpCalibrated(csv: String, calibrationPath: String, out: String) {
    guard let d = loadIMU(csv: csv, calibrationPath: calibrationPath) else { print("can't read inputs"); return }
    var f = OrientationFilter()
    var lines = ["t,wx,wy,wz,ax,ay,az,qx,qy,qz,qw"]
    lines.reserveCapacity(d.t.count + 1)
    for i in d.t.indices {
        f.update(gyro: d.gyro[i], accel: d.accel[i], dt: i > 0 ? Float(d.t[i] - d.t[i - 1]) : 0.001)
        guard f.initialized else { continue }
        let w = f.angularVelocity, a = d.accel[i], q = f.presented.vector
        lines.append(String(format: "%.6f,%g,%g,%g,%g,%g,%g,%.9g,%.9g,%.9g,%.9g", d.t[i], w.x, w.y, w.z, a.x, a.y, a.z, q.x, q.y, q.z, q.w))
    }
    try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
    print("wrote \(lines.count - 1) samples to \(out)")
}
