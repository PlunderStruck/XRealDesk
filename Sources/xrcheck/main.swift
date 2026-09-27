import Foundation
import simd
import XRCore

// Self-checks for XRCore. `swift run xrcheck` runs the unit checks;
// `swift run xrcheck live [seconds]` streams real head tracking from connected glasses.

setvbuf(stdout, nil, _IOLBF, 0)   // line by line: a crash must never swallow the output before it
var failures = 0
func check(_ cond: Bool, _ msg: String, file: StaticString = #file, line: UInt = #line) {
    if cond { print("  ok   \(msg)") } else { failures += 1; print("  FAIL \(msg)  (line \(line))") }
}
func near(_ a: Float, _ b: Float, _ tol: Float) -> Bool { abs(a - b) <= tol }
func deg(_ r: Float) -> Float { r * 180 / .pi }

func unitChecks() {
    print("protocol")
    let start = XRealProtocol.imuCommand(.startIMUStream, data: [1])
    check(start.count == 64 && start[0] == 0xAA && start[5] == 4 && start[6] == 0 && start[7] == 0x19 && start[8] == 1,
          "IMU start command layout")
    let crc = XRealProtocol.crc32([4, 0, 0x19, 1])
    check(start[1...4].elementsEqual([UInt8(crc & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8((crc >> 16) & 0xFF), UInt8(crc >> 24)]),
          "IMU command CRC32 over length..data")
    check(XRealProtocol.crc32(Array("123456789".utf8)) == 0xCBF4_3926, "CRC32 matches standard check value")
    let mcu = XRealProtocol.mcuCommand(.readDisplayMode)
    check(mcu[0] == 0xFD && mcu[5] == 17 && mcu[15] == 0x07 && mcu[16] == 0, "MCU command layout")

    // Synthesize a data packet: gyro x = 1000 * (m=1 / d=100) = 10 dps; accel z = 2048 * (1/2048) = 1 g.
    var pkt = [UInt8](repeating: 0, count: 64)
    pkt[0] = 1; pkt[1] = 2
    pkt[4] = 0x40; pkt[5] = 0x42; pkt[6] = 0x0F // timestamp 1_000_000
    pkt[12] = 1; pkt[14] = 100
    pkt[18] = 0xE8; pkt[19] = 0x03              // 1000
    pkt[21] = 0x18; pkt[22] = 0xFC; pkt[23] = 0xFF // -1000 (24-bit sign)
    pkt[27] = 1; pkt[29] = 0x00; pkt[30] = 0x08  // divisor 2048
    pkt[39] = 0x00; pkt[40] = 0x08               // accel z = 2048
    let s = pkt.withUnsafeBufferPointer { XRealProtocol.parseIMUSample($0) }
    check(s != nil && s!.timestampNs == 1_000_000, "IMU sample timestamp")
    check(s != nil && near(s!.gyro.x, 10, 1e-4) && near(s!.gyro.y, -10, 1e-4), "IMU gyro 24-bit signed scaling")
    check(s != nil && near(s!.accel.z, 1, 1e-5), "IMU accel scaling")
    check(pkt.withUnsafeBufferPointer { XRealProtocol.parseIMUSample($0) } != nil, "parses signature 01 02")
    var reply = pkt; reply[0] = 0xAA
    check(reply.withUnsafeBufferPointer { XRealProtocol.parseIMUSample($0) } == nil, "ignores command replies")

    print("calibration")
    let calPath = CommandLine.arguments.dropFirst().first { $0.hasSuffix(".json") }
    if let calPath, let data = FileManager.default.contents(atPath: calPath), let cal = GlassesCalibration.parse(json: data) {
        check(cal.isFactory, "factory calibration parsed")
        check(near(cal.fovDegrees.x, 39.3, 1.5) && near(cal.fovDegrees.y, 22.4, 1.5),
              String(format: "Air 2 Pro FOV %.1f° × %.1f°", cal.fovDegrees.x, cal.fovDegrees.y))
        // Factory gyro_bias (pre frame) ≈ (0, 0.00236, 0.0079) rad/s → head = (0, -0.00236, -0.0079)
        check(near(cal.gyroBias.y, -0.00236, 1e-4) && near(cal.gyroBias.z, -0.0079, 1e-4), "gyro bias mapped into head frame")
    } else {
        print("  skip (pass a calibration .json to check parsing)")
    }
    if let calPath, let data = FileManager.default.contents(atPath: calPath), let cal = GlassesCalibration.parse(json: data) {
        check(cal.eyes.count == 2, "per-eye stereo calibration parsed")
        if cal.eyes.count == 2 {
            let ipd = simd_length(cal.eyes[1].offset - cal.eyes[0].offset) * 1000
            check(abs(ipd - 63.3) < 1, String(format: "eye separation %.1f mm", ipd))
            check(cal.eyes[0].offset.x < 0 && cal.eyes[1].offset.x > 0, "left eye is on the left")
            if let conv = cal.convergenceDistance {
                check((2...6).contains(conv), String(format: "displays converge at %.2f m (factory toe-in)", conv))
            } else { check(false, "displays converge in front of you") }
            let tilt = SpatialMath.degrees(cal.eyes[0].rotation.angle)
            check(tilt < 3, String(format: "left display rotation small (%.2f°)", tilt))
            if ProcessInfo.processInfo.environment["XR_EYES"] != nil {
                let mid = simd_slerp(cal.eyes[0].rotation, cal.eyes[1].rotation, 0.5)
                for (i, e) in cal.eyes.enumerated() {
                    let r = mid.inverse * e.rotation
                    let f = r.act(SIMD3<Float>(0, 0, -1)), up = r.act(SIMD3<Float>(0, 1, 0))
                    print(String(format: "  eye %d: offset (%.1f, %.1f, %.1f) mm, yaw %.3f° pitch %.3f° roll %.3f°, focal (%.1f, %.1f) center (%.1f, %.1f), abs rot %.2f°",
                                 i, e.offset.x * 1000, e.offset.y * 1000, e.offset.z * 1000,
                                 SpatialMath.degrees(atan2(-f.x, -f.z)), SpatialMath.degrees(asin(f.y)), SpatialMath.degrees(atan2(-up.x, up.y)),
                                 e.focal.x, e.focal.y, e.center.x, e.center.y, SpatialMath.degrees(e.rotation.angle)))
                }
                for (i, e) in cal.eyes.enumerated() {
                    guard let g = e.distortion else { continue }
                    for (u, v) in [(960, 540), (200, 540), (1720, 540), (960, 100), (960, 980)] as [(Float, Float)] {
                        let m = g.sample(u, v)
                        print(String(format: "  eye %d lens map: display (%4.0f, %4.0f) → ideal (%7.1f, %7.1f)  shift (%+6.1f, %+6.1f)",
                                     i, u, v, m.x, m.y, m.x - u, m.y - v))
                    }
                }
                print(String(format: "  average: focal (%.1f, %.1f) center (%.1f, %.1f)", cal.focalX, cal.focalY, cal.centerX, cal.centerY))
            }
            // Side-by-side 3D: a point straight ahead lands where each eye's display should show it.
            func imageX(_ eye: Int, _ d: Float) -> Float {
                let p = cal.eyeView(eye) * SIMD4<Float>(0, 0, -d, 1)
                return cal.focalX * (p.x / -p.z) + cal.centerX
            }
            func disparity(_ d: Float) -> Float {   // + = crossed (nearer than the displays' convergence)
                imageX(0, d) - imageX(1, d)
            }
            if let conv = cal.convergenceDistance {
                check(abs(disparity(conv)) < 0.5, String(format: "3D: no disparity at the convergence distance (%.2f px)", disparity(conv)))
                let ipd = simd_length(cal.eyes[1].offset - cal.eyes[0].offset)
                let expected = cal.eyes[0].focal.x * ipd * (1 / 1.5 - 1 / conv)
                check(disparity(1.5) > 0 && abs(disparity(1.5) - expected) < 2,
                      String(format: "3D: screens at 1.5 m get %.1f px of depth disparity (expected %.1f)", disparity(1.5), expected))
                check(disparity(100) < 0, "3D: far away points sit behind the convergence plane")
            }
        }
        if let g = cal.distortion {
            check(g.us.count == 32 && g.vs.count == 18, "lens distortion grid 32×18 parsed")
            let c = g.sample(960, 540)
            check(simd_length(c - SIMD2(960, 540)) < 3, String(format: "centre nearly undistorted (%.1f, %.1f)", c.x, c.y))
            let tl = g.sample(0, 0)
            check(tl.x < -10 && tl.y < -10, String(format: "top-left corner shifted outward (%.1f, %.1f)", tl.x, tl.y))
            // Bilinear sample reproduces grid points exactly.
            let gp = g.sample(g.us[5], g.vs[7])
            check(simd_length(gp - g.xy[7 * 32 + 5]) < 1e-3, "grid points reproduced exactly")
            let m = g.uniformMap(width: 1920, height: 1080, step: 8)
            check(m.w == 241 && m.h == 136 && simd_length(m.values[0] - tl) < 1e-3, "uniform lookup map 241×136")
        } else {
            check(false, "lens distortion grid present")
        }
    }
    check(GlassesCalibration.headFromRaw(SIMD3(0, 0, 1)) == SIMD3(0, 1, 0), "raw +Z (up) → head +Y")
    check(GlassesCalibration.headFromRaw(SIMD3(-1, 0, 0)) == SIMD3(1, 0, 0), "raw -X → head right")

    print("orientation filter")
    do {
        var f = OrientationFilter()
        f.update(gyro: .zero, accel: SIMD3(0, 1, 0), dt: 0.001)
        check(f.initialized, "initializes from gravity")
        // Yaw left at 90°/s for 1 s (rotation about +Y).
        for _ in 0..<1000 { f.update(gyro: SIMD3(0, .pi / 2, 0), accel: SIMD3(0, 1, 0), dt: 0.001) }
        let yp = SpatialMath.yawPitch(of: f.orientation)
        check(near(deg(yp.yaw), 90, 1.0), String(format: "integrates +Y rate as yaw-left (%.2f°)", deg(yp.yaw)))
        check(near(deg(yp.pitch), 0, 0.5), "no pitch leak during yaw")
    }
    do {
        // Start level, but the head is really pitched up 20°: gravity in head frame tilts toward -Z... converge.
        var f = OrientationFilter()
        f.update(gyro: .zero, accel: SIMD3(0, 1, 0), dt: 0.001)
        let truth = SpatialMath.rotationX(SpatialMath.radians(20))
        let upInHead = truth.inverse.act(SIMD3(0, 1, 0))
        for _ in 0..<3000 { f.update(gyro: .zero, accel: upInHead, dt: 0.001) }
        let yp = SpatialMath.yawPitch(of: f.orientation)
        check(near(deg(yp.pitch), 20, 0.5), String(format: "gravity correction converges to pitch (%.2f°)", deg(yp.pitch)))
    }
    do {
        // Constant gyro bias while still should be learned and stop yaw drift.
        var f = OrientationFilter()
        let bias = SIMD3<Float>(0.001, 0.005, -0.002)   // ~0.31 °/s: a realistic residual after factory calibration
        f.update(gyro: bias, accel: SIMD3(0, 1, 0), dt: 0.001)
        for _ in 0..<15000 { f.update(gyro: bias, accel: SIMD3(0, 1, 0), dt: 0.001) }
        let y0 = SpatialMath.yawPitch(of: f.orientation).yaw
        for _ in 0..<10000 { f.update(gyro: bias, accel: SIMD3(0, 1, 0), dt: 0.001) }
        let drift = deg(SpatialMath.yawPitch(of: f.orientation).yaw - y0)
        check(simd_length(f.learnedBias - bias) < 0.001, "learns constant gyro bias while still")
        check(abs(drift) < 0.3, String(format: "yaw drift after learning %.3f°/10s", drift))
    }
    do {
        var f = OrientationFilter()
        f.update(gyro: .zero, accel: SIMD3(0, 1, 0), dt: 0.001)
        for _ in 0..<500 { f.update(gyro: SIMD3(0, 1, 0), accel: SIMD3(0, 1, 0), dt: 0.001) }
        let p = f.predicted(by: 0.02)
        let dy = deg(SpatialMath.yawPitch(of: p).yaw - SpatialMath.yawPitch(of: f.orientation).yaw)
        check(near(dy, deg(0.02), 0.05), "prediction extrapolates along angular velocity")
    }

    print("tracking accuracy (realistic head motion + sensor noise)")
    do {
        // Deterministic noise: ICM-42688-class gyro, ~0.6 °/s per-sample noise at 1 kHz.
        var rng = SplitMix(seed: 42)
        func noisy(_ v: SIMD3<Float>) -> SIMD3<Float> { v + SIMD3(rng.gauss(), rng.gauss(), rng.gauss()) * SpatialMath.radians(0.6) }
        func accelNoise() -> SIMD3<Float> { SIMD3(0, 1, 0) + SIMD3(rng.gauss(), rng.gauss(), rng.gauss()) * 0.004 }
        func yawDeg(_ f: OrientationFilter) -> Float { deg(SpatialMath.yawPitch(of: f.orientation).yaw) }
        func settled() -> OrientationFilter {
            var f = OrientationFilter()
            f.update(gyro: .zero, accel: SIMD3(0, 1, 0), dt: 0.001)
            for _ in 0..<3000 { f.update(gyro: noisy(.zero), accel: accelNoise(), dt: 0.001) }
            return f
        }
        // 1. Slow deliberate pan: 1.5 °/s for 20 s must integrate to 30°.
        var f = settled()
        var y0 = yawDeg(f)
        for _ in 0..<20000 { f.update(gyro: noisy(SIMD3(0, SpatialMath.radians(1.5), 0)), accel: accelNoise(), dt: 0.001) }
        check(abs(yawDeg(f) - y0 - 30) < 1, String(format: "slow 1.5°/s pan tracked: %.2f° of 30°", yawDeg(f) - y0))
        // 2. Reading-style micro-moves: 1 s still, then 0.3 s at 5 °/s (1.5°), ×20 = 30°.
        f = settled(); y0 = yawDeg(f)
        for _ in 0..<20 {
            for _ in 0..<1000 { f.update(gyro: noisy(.zero), accel: accelNoise(), dt: 0.001) }
            for _ in 0..<300 { f.update(gyro: noisy(SIMD3(0, SpatialMath.radians(5), 0)), accel: accelNoise(), dt: 0.001) }
        }
        check(abs(yawDeg(f) - y0 - 30) < 0.5, String(format: "start-stop micro-moves tracked: %.2f° of 30° (no dead moments)", yawDeg(f) - y0))
        // 3. Unknown gyro bias of 0.4 °/s while mostly still on the head: drift must be learned away.
        let bias = SIMD3<Float>(0, SpatialMath.radians(0.4), 0)
        f = OrientationFilter()
        f.update(gyro: .zero, accel: SIMD3(0, 1, 0), dt: 0.001)
        for _ in 0..<30000 { f.update(gyro: noisy(bias), accel: accelNoise(), dt: 0.001) }   // 30 s to learn
        y0 = yawDeg(f)
        for _ in 0..<60000 { f.update(gyro: noisy(bias), accel: accelNoise(), dt: 0.001) }   // then 60 s
        check(abs(yawDeg(f) - y0) < 0.5, String(format: "0.4°/s bias learned: drift %.2f° per minute", yawDeg(f) - y0))
        // 5. Tilt must stay level while you keep moving: a 0.2 °/s gyro error on the roll axis,
        //    with continuous head motion (no steady periods to learn from), for 2 minutes.
        do {
            let rollBias = SIMD3<Float>(0, 0, SpatialMath.radians(0.2))
            var g = OrientationFilter()
            g.update(gyro: .zero, accel: SIMD3(0, 1, 0), dt: 0.001)
            var truth = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            var t: Float = 0
            for _ in 0..<120_000 {
                t += 0.001
                // Looking around: yaw ±30° and pitch ±10° sweeps at different rates.
                let w = SIMD3<Float>(SpatialMath.radians(10) * 2 * .pi * 0.23 * cos(2 * .pi * 0.23 * t),
                                     SpatialMath.radians(30) * 2 * .pi * 0.11 * cos(2 * .pi * 0.11 * t), 0)
                truth = (truth * simd_quatf(angle: simd_length(w) * 0.001, axis: simd_length(w) > 0 ? simd_normalize(w) : SIMD3(0, 1, 0))).normalized
                let upInHead = truth.inverse.act(SIMD3(0, 1, 0))
                g.update(gyro: noisy(w + rollBias), accel: upInHead + (accelNoise() - SIMD3(0, 1, 0)), dt: 0.001)
            }
            // Tilt error = angle between true and estimated "up" in the head frame.
            let estUp = g.orientation.inverse.act(SIMD3(0, 1, 0))
            let trueUp = truth.inverse.act(SIMD3(0, 1, 0))
            let tiltErr = deg(acos(min(1, simd_dot(simd_normalize(estUp), simd_normalize(trueUp)))))
            check(tiltErr < 0.3, String(format: "tilt stays level with a 0.2°/s roll-axis gyro error while moving: %.2f° off after 2 min", tiltErr))
        }
        // 4. A larger error (1 °/s, e.g. after a big temperature change) is recovered by the
        //    long-steady path once the headset has been perfectly steady for a while.
        let big = SIMD3<Float>(0, SpatialMath.radians(1.0), 0)
        f = OrientationFilter()
        f.update(gyro: .zero, accel: SIMD3(0, 1, 0), dt: 0.001)
        for _ in 0..<40000 { f.update(gyro: noisy(big), accel: accelNoise(), dt: 0.001) }
        y0 = yawDeg(f)
        for _ in 0..<60000 { f.update(gyro: noisy(big), accel: accelNoise(), dt: 0.001) }
        check(abs(yawDeg(f) - y0) < 0.5, String(format: "1°/s error recovered after steady period: drift %.2f° per minute", yawDeg(f) - y0))
    }

    print("prediction cap sees tiny head motion")
    do {
        // Head tremor is a few hundredths of a degree; the cap must measure it smoothly (Float
        // 2·acos(real) snapped between 0 and ~0.04°, flickering prediction on and off: shake).
        var worst: Float = 0
        for k in 1...200 {
            let a = SpatialMath.radians(Float(k) * 0.0005)   // 0.0005° … 0.1°
            let q = simd_quatf(angle: a, axis: simd_normalize(SIMD3<Float>(0.3, 1, 0.2)))
            worst = max(worst, abs(GlassesHIDService.Pose.rotationAngle(q) - a) / a)
        }
        check(worst < 0.01, String(format: "rotation angle exact to %.2f%% from 0.0005° to 0.1°", worst * 100))
    }

    for model in [HeadPredictor.Model.blended, .hybrid] {
    print("learned head prediction (\(model))")
    do {
        typealias Pose = GlassesHIDService.Pose
        func pose(_ hp: HeadPredictor, rate: SIMD3<Float>) -> Pose {
            var p = Pose(orientation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), angularVelocity: rate, hostTime: 0,
                         isStill: false, warmedUp: true)
            p.learned = true; p.features = hp.features; p.learnedModel = model
            return p
        }
        // A steady turn is predicted to carry on at the same speed.
        var hp = HeadPredictor()
        let turn = SIMD3<Float>(0, SpatialMath.radians(60), 0)
        for _ in 0..<600 { hp.add(gyro: turn, accel: SIMD3(0, 1, 0)) }
        let ahead = SpatialMath.degrees(Pose.rotationAngle(pose(hp, rate: turn).predicted(to: 0.04)))
        check(abs(ahead - 2.4) < 0.25, String(format: "steady 60°/s turn: %.2f° ahead over 40 ms (2.40° expected)", ahead))
        // Still head, then a knock on the frame (16 g for 2 ms): the screens mustn't be flung.
        hp = HeadPredictor()
        for _ in 0..<600 { hp.add(gyro: .zero, accel: SIMD3(0, 1, 0)) }
        for _ in 0..<2 { hp.add(gyro: .zero, accel: SIMD3(16, 1, 0)) }
        let knock = SpatialMath.degrees(Pose.rotationAngle(pose(hp, rate: .zero).predicted(to: 0.04)))
        check(knock <= 0.1 + 1e-4, String(format: "knock on a still head: screens move %.3f° (≤ 0.1°)", knock))
        // A corrupt sample restarts the history instead of poisoning it.
        hp.add(gyro: SIMD3(.nan, 0, 0), accel: SIMD3(0, 1, 0))
        check(hp.features == nil, "non-finite sample clears the history")
        for _ in 0..<600 { hp.add(gyro: .zero, accel: SIMD3(0, 1, 0)) }
        let still = SpatialMath.degrees(Pose.rotationAngle(pose(hp, rate: .zero).predicted(to: 0.04)))
        check(still < 1e-3, String(format: "recovers: still head predicted still (%.4f°)", still))
    }
    }

    print("screens hold still through body motion")
    do {
        var rng = SplitMix(seed: 7)
        func gyroNoise() -> SIMD3<Float> { SIMD3(rng.gauss(), rng.gauss(), rng.gauss()) * SpatialMath.radians(0.6) }
        func accelNoise() -> SIMD3<Float> { SIMD3(rng.gauss(), rng.gauss(), rng.gauss()) * 0.004 }
        func settled(_ s: OrientationFilter.Settings = .init()) -> OrientationFilter {
            var f = OrientationFilter(settings: s)
            f.update(gyro: .zero, accel: SIMD3(0, 1, 0), dt: 0.001)
            for _ in 0..<5000 { f.update(gyro: gyroNoise(), accel: SIMD3(0, 1, 0) + accelNoise(), dt: 0.001) }
            return f
        }
        var estWorst: Float = 0
        // Leaning forward and back, shifting in the chair: the head is carried around without
        // rotating. 0.1 g pushes for 0.3 s each way, repeated, along each horizontal axis.
        func push(_ f: inout OrientationFilter) -> Float {
            // Measured against the gyro alone (what the head really did, noise included), so this
            // is only what the tilt correction added.
            var gyroOnly = f.presented
            var worst: Float = 0
            estWorst = 0
            for axis in [SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 0, 1), simd_normalize(SIMD3<Float>(1, 0, 1))] {
                for _ in 0..<3 {
                    for phase in [Float(1), -1, 0] {
                        for _ in 0..<300 {
                            f.update(gyro: gyroNoise(), accel: SIMD3(0, 1, 0) + axis * 0.1 * phase + accelNoise(), dt: 0.001)
                            let w = f.angularVelocity, a = simd_length(w) * 0.001
                            if a > 1e-9 { gyroOnly = gyroOnly * simd_quatf(angle: a, axis: w / simd_length(w)) }
                            worst = max(worst, deg((gyroOnly.inverse * f.presented).angle))
                            estWorst = max(estWorst, deg((gyroOnly.inverse * f.orientation).angle))
                        }
                    }
                }
            }
            if ProcessInfo.processInfo.environment["XR_TRACE"] != nil { print(String(format: "    estimate moved %.3f°, drawn %.3f°", estWorst, worst)) }
            return worst
        }
        var old = OrientationFilter.Settings(); old.motionGateLow = 0; old.motionGateHigh = 0; old.presentStillRate = 1e4
        var before = settled(old), after = settled()
        let moved0 = push(&before), moved1 = push(&after)
        check(moved1 < 0.02 && moved1 < moved0 / 10,
              String(format: "screens stay put while the body is pushed around: %.3f° (without the gate and presentation: %.3f°)", moved1, moved0))
        // Real head motion still comes through exactly.
        var f = settled()
        let y0 = deg(SpatialMath.yawPitch(of: f.presented).yaw)
        for _ in 0..<1000 { f.update(gyro: SIMD3(0, .pi / 2, 0) + gyroNoise(), accel: SIMD3(0, 1, 0) + accelNoise(), dt: 0.001) }
        let turned = deg(SpatialMath.yawPitch(of: f.presented).yaw) - y0
        check(near(turned, 90, 0.5), String(format: "a real 90° turn is drawn as %.2f°", turned))
        // A genuine tilt error: the estimate corrects it; the screens take it on almost only while
        // the head turns, and end up level.
        f = settled()
        let tilted = SpatialMath.rotationX(SpatialMath.radians(1.0)).inverse.act(SIMD3<Float>(0, 1, 0))   // gravity now says 1° pitch
        var stillCreep: Float = 0
        var p0 = f.presented
        for _ in 0..<5000 {
            f.update(gyro: gyroNoise(), accel: tilted + accelNoise(), dt: 0.001)
            let w = f.angularVelocity, a = simd_length(w) * 0.001
            if a > 1e-9 { p0 = p0 * simd_quatf(angle: a, axis: w / simd_length(w)) }   // gyro alone
        }
        stillCreep = deg((p0.inverse * f.presented).angle) / 5
        if ProcessInfo.processInfo.environment["XR_TRACE"] != nil {
            print(String(format: "    estimate %.3f° from drawn after 5 s", deg((f.presented.inverse * f.orientation).angle)))
        }
        check(stillCreep < 0.04, String(format: "while still, a 1° tilt fix creeps in at %.3f°/s (invisible)", stillCreep))
        var tt: Float = 0
        for _ in 0..<20000 {   // looking left and right, ±30°
            tt += 0.001
            let w = SIMD3<Float>(0, SpatialMath.radians(30) * 2 * .pi * 0.25 * cos(2 * .pi * 0.25 * tt), 0)
            f.update(gyro: w + gyroNoise(), accel: tilted + accelNoise(), dt: 0.001)
        }
        let apart = deg((f.presented.inverse * f.orientation).angle)
        check(apart < 0.2, String(format: "after 20 s of looking around, the screens have taken on the fix (%.2f° left)", apart))
        // A big error (a knock) is fixed quickly even when perfectly still.
        f = settled()
        let knocked = SpatialMath.rotationX(SpatialMath.radians(6)).inverse.act(SIMD3<Float>(0, 1, 0))
        for _ in 0..<12000 { f.update(gyro: gyroNoise(), accel: knocked + accelNoise(), dt: 0.001) }
        p0 = f.presented
        let left = deg((f.presented.inverse * f.orientation).angle)
        check(left < 2, String(format: "a 6° error is mostly fixed within 12 s even without moving (%.2f° left)", left))
        _ = p0
    }

    print("prediction")
    do {
        let q = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        let fast = SIMD3<Float>(0, SpatialMath.radians(100), 0)
        // A real turn: the head has been moving (3.1° over the last 31 ms) → full prediction.
        let turn = GlassesHIDService.Pose(orientation: q, angularVelocity: fast, hostTime: 0, isStill: false, warmedUp: true,
                                          recentRotation: SpatialMath.radians(3.1))
        check(near(deg(turn.predicted(to: 0.03).angle), 3.0, 0.01), "turning at 100°/s: full prediction (3° over 30 ms)")
        // A typing jolt: gyro spikes to 100°/s but the head only moved 0.05° → capped, no overshoot.
        let jolt = GlassesHIDService.Pose(orientation: q, angularVelocity: fast, hostTime: 0, isStill: false, warmedUp: true,
                                          recentRotation: SpatialMath.radians(0.05))
        check(deg(jolt.predicted(to: 0.031).angle) <= 0.0751, String(format: "typing jolt capped: predicts %.3f° instead of 3.1°", deg(jolt.predicted(to: 0.031).angle)))
        // Head still: nothing moved → nothing predicted.
        let still = GlassesHIDService.Pose(orientation: q, angularVelocity: SIMD3(0, SpatialMath.radians(0.8), 0), hostTime: 0,
                                           isStill: true, warmedUp: true, recentRotation: 0)
        check(still.predicted(to: 0.03).angle < 1e-6, "no prediction when the head hasn't moved")
        check(near(deg(turn.predicted(to: 1.0).angle), 8.0, 0.01), "prediction horizon capped at 80 ms (covers 60 Hz 3D)")
    }

    print("layout")
    do {
        let l = ScreenLayout(count: 3, rows: 1, widthDegrees: 30, aspect: 16 / 9, gapDegrees: 2, curve: 1)
        check(l.panels.count == 3, "3 panels")
        let expectedYaw = deg((l.panels[1].size.x + 1.5 * SpatialMath.radians(2)) / 1.5)   // arc length / radius
        check(near(deg(l.panels[0].yaw), expectedYaw, 0.01) && near(deg(l.panels[2].yaw), -expectedYaw, 0.01),
              String(format: "full curve: left panel at +%.1f° (left)", deg(l.panels[0].yaw)))
        let center = l.hit(direction: SIMD3(0, 0, -1))
        check(center?.index == 1 && near(center!.uv.x, 0.5, 1e-3) && near(center!.uv.y, 0.5, 1e-3), "gaze straight hits middle centre")
        let left = l.hit(direction: SpatialMath.rotationY(l.panels[0].yaw).act(SIMD3(0, 0, -1)))
        check(left?.index == 0 && near(left!.uv.x, 0.5, 0.02), "gaze at left panel yaw hits its centre")
        let up = l.hit(direction: SpatialMath.orientation(yaw: 0, pitch: SpatialMath.radians(5)).act(SIMD3(0, 0, -1)))
        check(up != nil && up!.uv.y < 0.5, "looking up maps to upper half (v < 0.5)")
        // Every point along a fully curved row is at the same distance from the viewer.
        let e = l.untiltedPoint(arc: l.panels[0].arcCenter - l.panels[0].size.x / 2, height: 0)
        check(near(simd_length(e), 1.5, 1e-3), "curve 1 wraps at constant distance")
        let flat = ScreenLayout(count: 3, rows: 1, widthDegrees: 30, aspect: 16 / 9, gapDegrees: 2, curve: 0)
        check(near(flat.panels[2].center.z, -1.5, 1e-5) && flat.panels[2].center.x > 0, "curve 0 is a flat wall")
        let fr = flat.hit(direction: simd_normalize(flat.panels[2].center))
        check(fr?.index == 2 && near(fr!.uv.x, 0.5, 1e-3), "flat hit test")
        let mid = ScreenLayout(count: 3, rows: 1, widthDegrees: 30, aspect: 16 / 9, gapDegrees: 2, curve: 0.5)
        let mr = mid.hit(direction: simd_normalize(mid.panels[0].center))
        check(mr?.index == 0 && near(mr!.uv.x, 0.5, 1e-3) && near(mr!.uv.y, 0.5, 1e-3), "partial-curve hit test round-trips")
        let w = l.panels[1].size.x
        check(near(deg(2 * atan(w / 2 / 1.5)), 30, 0.01), "angular width honoured")
        let grid = ScreenLayout(count: 5, rows: 2, widthDegrees: 30, aspect: 16 / 9, gapDegrees: 2, curve: 0)
        check(grid.panels.count == 5 && grid.panels[0].center.y < grid.panels[4].center.y, "two-row grid: bottom row first")
        let tilted = ScreenLayout(count: 1, rows: 1, widthDegrees: 30, aspect: 16 / 9, gapDegrees: 2, curve: 0.5, tiltDegrees: -10)
        check(near(deg(tilted.panels[0].pitch), -10, 0.01), "tilt lowers the layout")
        let th = tilted.hit(direction: tilted.panels[0].center)
        check(th?.index == 0 && near(th!.uv.y, 0.5, 1e-3), "tilted hit test")
    }

    print("smart follow")
    do {
        let layout = ScreenLayout(count: 3, rows: 1, widthDegrees: 33, aspect: 16 / 9, gapDegrees: 1.5, curve: 0.55)
        let r = SpatialMath.radians
        // Slow look to the left screen (30°/s over 1.1 s): layout must not move.
        var sf = SmartFollow()
        var a = SIMD2<Float>(0, 0)
        for i in 0...132 { a = sf.update(head: SIMD2(r(Float(i) * 0.25), 0), anchor: a, layout: layout, dt: 1.0 / 120) }
        check(abs(deg(a.x)) < 0.01, String(format: "slow 33° look keeps screens anchored (moved %.3f°)", deg(a.x)))
        // Normal quick glance (~120°/s) should still be anchored at default sensitivity.
        sf = SmartFollow(); a = .zero
        for i in 0...30 { a = sf.update(head: SIMD2(r(Float(i)), 0), anchor: a, layout: layout, dt: 1.0 / 120) }
        check(abs(deg(a.x)) < 0.5, String(format: "120°/s glance stays anchored (moved %.2f°)", deg(a.x)))
        // Flicks do nothing unless enabled.
        sf = SmartFollow(); a = .zero
        for i in 0...6 { a = sf.update(head: SIMD2(r(Float(i) * 5), 0), anchor: a, layout: layout, dt: 1.0 / 120) }
        check(abs(deg(a.x)) < 0.01, "flick is ignored when flick-to-reposition is off")
        // Fast flick (600°/s for 50 ms = 30°): layout comes along almost fully.
        sf = SmartFollow(); sf.flickEnabled = true; a = .zero
        for i in 0...6 { a = sf.update(head: SIMD2(r(Float(i) * 5), 0), anchor: a, layout: layout, dt: 1.0 / 120) }
        check(deg(a.x) > 25, String(format: "600°/s flick carries the screens (moved %.1f° of 30°)", deg(a.x)))
        // Flick direction: flick right (negative yaw) moves the layout right.
        sf = SmartFollow(); sf.flickEnabled = true; a = .zero
        for i in 0...6 { a = sf.update(head: SIMD2(-r(Float(i) * 5), 0), anchor: a, layout: layout, dt: 1.0 / 120) }
        check(deg(a.x) < -25, "flick right carries screens right")
        // Vertical flick.
        sf = SmartFollow(); sf.flickEnabled = true; a = .zero
        for i in 0...6 { a = sf.update(head: SIMD2(0, r(Float(i) * 4)), anchor: a, layout: layout, dt: 1.0 / 120) }
        check(deg(a.y) > 18, String(format: "fast upward flick carries screens up (%.1f°)", deg(a.y)))
        // Looking past the group edge: layout glides after you until its edge is where you look.
        sf = SmartFollow(); a = .zero
        let ext = SmartFollow.extents(layout)!
        let farLeft = ext.maxYaw + r(25)
        for _ in 0..<240 { a = sf.update(head: SIMD2(farLeft, 0), anchor: a, layout: layout, dt: 1.0 / 120) }
        check(abs((farLeft - a.x) - (ext.maxYaw + r(2))) < r(0.3),
              String(format: "past the left edge it follows until the edge is 2° from gaze (anchor %.1f°)", deg(a.x)))
        // It glides (not a jump): after one frame it has moved only a little.
        sf = SmartFollow(); a = .zero
        a = sf.update(head: SIMD2(farLeft, 0), anchor: a, layout: layout, dt: 1.0 / 120)
        check(deg(a.x) > 0 && deg(a.x) < 2, String(format: "following is smooth (%.2f° after one frame)", deg(a.x)))
        // Same above the top edge.
        sf = SmartFollow(); a = .zero
        let up = ext.maxPitch + r(15)
        for _ in 0..<240 { a = sf.update(head: SIMD2(0, up), anchor: a, layout: layout, dt: 1.0 / 120) }
        check(abs((up - a.y) - (ext.maxPitch + r(2))) < r(0.3), "past the top edge it follows up")
        // Anywhere inside the group edge is free look.
        sf = SmartFollow(); a = .zero
        for i in 0...200 {
            let t = Float(i) / 200
            a = sf.update(head: SIMD2((ext.minYaw + (ext.maxYaw - ext.minYaw) * t) * 0.98, 0), anchor: a, layout: layout, dt: 1.0 / 120)
        }
        check(a == .zero, "sweeping across the whole group never moves it")
        // Within the layout, holding still never moves it.
        sf = SmartFollow(); a = .zero
        for _ in 0..<240 { a = sf.update(head: SIMD2(r(30), r(5)), anchor: a, layout: layout, dt: 1.0 / 120) }
        check(a == .zero, "holding your gaze on a side screen never moves the layout")
        var hi = SmartFollow(); hi.sensitivity = 1
        var lo = SmartFollow(); lo.sensitivity = 0
        check(hi.flickRange.start < lo.flickRange.start, "sensitivity lowers the flick threshold")
    }

    print("projection")
    do {
        let proj = SpatialMath.projection(focal: SIMD2(2700, 2700), center: SIMD2(960, 540),
                                          calibrated: SIMD2(1920, 1080), viewport: SIMD2(1920, 1080))
        let p = proj * SIMD4<Float>(0, 0, -2, 1)
        check(near(p.x / p.w, 0, 1e-5) && near(p.y / p.w, 0, 1e-5), "principal point projects to centre")
        // A point 960 px right of centre at focal distance lands on the right edge.
        let e = proj * SIMD4<Float>(960.0 / 2700, 0, -1, 1)
        check(near(e.x / e.w, 1, 1e-4), "focal length maps to screen edge")
        let z = p.z / p.w
        check(z > 0 && z < 1, "depth in Metal clip range")
    }

}

final class MemoryBias: GlassesBiasStore, @unchecked Sendable {
    func loadBias(serial: String) -> SIMD3<Float>? { nil }
    func saveBias(_ bias: SIMD3<Float>, serial: String) {}
}

func live(seconds: Double) {
    let cache = FileManager.default.temporaryDirectory.appendingPathComponent("xrcheck-cache")
    let svc = GlassesHIDService(cacheDirectory: cache)
    svc.logger = { print("[hid] \($0)") }
    svc.onStateChange = { print("[state] \($0)") }
    svc.onButton = { print("[button] phys=\($0) virt=\($1) value=\($2)") }
    svc.start()
    let end = Date().addingTimeInterval(seconds)
    var baseYaw: Float?
    while Date() < end {
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        guard let p = svc.pose, p.warmedUp else { continue }
        let yp = SpatialMath.yawPitch(of: p.orientation)
        if baseYaw == nil { baseYaw = yp.yaw }
        let right = p.orientation.act(SIMD3(1, 0, 0))
        let roll = deg(asin(max(-1, min(1, right.y))))
        print(String(format: "yaw %+7.1f°  pitch %+6.1f°  roll %+6.1f°  %4.0f Hz  %@", deg(yp.yaw - baseYaw!),
                     deg(yp.pitch), roll, svc.sampleRate, p.isStill ? "still" : "moving"))
    }
}

func sweepStabilizer() {
    let r = SpatialMath.radians
    let dt: Float = 1.0 / 120
    func yawOf(_ q: simd_quatf) -> Float { deg(SpatialMath.yawPitch(of: q).yaw) }
    func d2(_ ys: [Float]) -> (rms: Float, max: Float) {
        var sum: Float = 0, mx: Float = 0
        for i in 2..<ys.count { let d = abs(ys[i] - 2 * ys[i - 1] + ys[i - 2]); sum += d * d; mx = max(mx, d) }
        return (sqrt(sum / Float(ys.count - 2)), mx)
    }
    func wobble(_ st: inout ViewStabilizer, amp: Float, hz: Float) -> (Float, Float, Float, Float) {
        var i0: [Float] = [], o: [Float] = []
        for i in 0..<1200 {
            let t = Float(i) * dt
            let a = r(amp) * sin(2 * .pi * hz * t)
            let h = SpatialMath.rotationY(a)
            let out = st.update(head: h, angularSpeed: abs(r(amp) * 2 * .pi * hz * cos(2 * .pi * hz * t)), dt: dt)
            i0.append(yawOf(h)); o.append(yawOf(out))
        }
        let a = d2(i0), b = d2(o)
        return (a.rms, a.max, b.rms, b.max)
    }
    print("rate  eStart eWidth | typing(0.05@8) rms ratio | edge(0.1@6,L.08) max out/in | pan 3°/s lag")
    for rate in [10, 15, 20, 30, 40] as [Float] {
        for es in [0.3, 0.5] as [Float] {
            for ew in [1.0, 1.5, 2.5] as [Float] {
                var st = ViewStabilizer(); st.springRate = rate; st.engageStart = es; st.engageWidth = ew
                let ty = wobble(&st, amp: 0.05, hz: 8)
                var st2 = ViewStabilizer(); st2.leash = r(0.08); st2.springRate = rate; st2.engageStart = es; st2.engageWidth = ew
                let ed = wobble(&st2, amp: 0.1, hz: 6)
                var st3 = ViewStabilizer(); st3.springRate = rate; st3.engageStart = es; st3.engageWidth = ew
                var yaw: Float = 0; var out = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
                for _ in 0..<240 { yaw += r(3) * dt; out = st3.update(head: SpatialMath.rotationY(yaw), angularSpeed: r(3), dt: dt) }
                print(String(format: "%4.0f  %5.2f  %5.2f  |  %7.1f×  |  %5.2f  |  %.3f°", rate, es, ew, ty.0 / max(ty.2, 1e-7), ed.3 / ed.1, deg(yaw) - yawOf(out)))
            }
        }
    }
}

/// Replays a recorded IMU stream through the tracking pipeline and measures world-lock error:
/// how far the rendered view is from where the head really is when the frame reaches the eye.
///  - swim    = RMS angle error (screens slightly off where they should be)
///  - shimmer = RMS frame-to-frame change of that error (what reads as jitter)
/// Only "working" frames count (true head speed < 10°/s: typing, reading, small moves).
func replay(csv: String, calibrationPath: String) {
    guard let text = try? String(contentsOfFile: csv, encoding: .utf8),
          let calData = FileManager.default.contents(atPath: calibrationPath),
          let cal = GlassesCalibration.parse(json: calData) else { print("can't read inputs"); return }
    var t: [Double] = [], gy: [SIMD3<Float>] = [], ac: [SIMD3<Float>] = []
    var t0: UInt64 = 0
    for line in text.split(separator: "\n").dropFirst() {
        let f = line.split(separator: ",")
        guard f.count == 7, let ns = UInt64(f[0]) else { continue }
        let v = f[1...].compactMap { Float($0) }
        guard v.count == 6 else { continue }
        if t0 == 0 { t0 = ns }
        guard ns >= t0, t.last.map({ Double(ns - t0) / 1e9 > $0 }) ?? true else { continue }   // skip out-of-order rows
        let raw = XRealProtocol.RawIMUSample(timestampNs: ns, gyro: SIMD3(v[0], v[1], v[2]), accel: SIMD3(v[3], v[4], v[5]), temperatureC: 30)
        let (g, a) = cal.correct(raw)
        t.append(Double(ns - t0) / 1e9); gy.append(g); ac.append(a)
    }
    print(String(format: "replaying %d samples (%.1f s)", t.count, t.last ?? 0))
    // Ground truth: the filter's own estimate at every sample (uses only past data).
    var f = OrientationFilter()
    var q: [simd_quatf] = [], w: [SIMD3<Float>] = []
    for i in t.indices {
        let dt = i > 0 ? Float(t[i] - t[i - 1]) : 0.001
        f.update(gyro: gy[i], accel: ac[i], dt: dt)
        q.append(f.presented); w.append(f.angularVelocity)
    }
    func sampleIndex(at time: Double) -> Int {   // latest sample at or before `time`
        var lo = 0, hi = t.count - 1
        while lo < hi { let mid = (lo + hi + 1) / 2; if t[mid] <= time { lo = mid } else { hi = mid - 1 } }
        return lo
    }
    struct Config {
        var name: String; var fadeStart: Float; var fadeFull: Float; var velTau: Double; var leash: Float
        /// Optional distance gate: prediction on when the head moved ≥ d0…d1 degrees over `window` s.
        var dispWindow: Double = 0; var d0: Float = 0; var d1: Float = 0
        /// Optional cap: never predict more rotation than `clamp` × what the head did over the
        /// same span just before (0 = no cap).
        var clamp: Float = 0
        /// Use the app's real GlassesHIDService.Pose.predicted() (verifies the shipped code).
        var appPose = false
        /// Deceleration-aware prediction: use this fraction of the measured slowdown (0 = off), and
        /// of the measured speed-up; the head is never predicted to stop and turn back.
        var decel: Float = 0; var accel: Float = 0
        /// Learned prediction (HeadPredictor) in the app's Pose.
        var learned = false
        var previousFit = false
        var hybrid = false
    }
    // What the learned predictor sees at every sample.
    var feats: [HeadPredictor.Features?] = []
    do {
        var hp = HeadPredictor()
        for i in t.indices { hp.add(gyro: w[i], accel: ac[i]); feats.append(hp.features) }
    }
    let configs: [Config] = [
        .init(name: "APP CODE (Pose.predicted)", fadeStart: 0, fadeFull: 0.001, velTau: 0.008, leash: 0.03, appPose: true),
        .init(name: "APP CODE, stability off", fadeStart: 0, fadeFull: 0.001, velTau: 0.008, leash: 0, appPose: true),
        .init(name: "LEARNED, stability off", fadeStart: 0, fadeFull: 0.001, velTau: 0.008, leash: 0, appPose: true, learned: true),
        .init(name: "HYBRID (linear still + net moving)", fadeStart: 0, fadeFull: 0.001, velTau: 0.008, leash: 0, appPose: true, learned: true, hybrid: true),
        .init(name: "LEARNED previous (first fit)", fadeStart: 0, fadeFull: 0.001, velTau: 0.008, leash: 0, appPose: true, learned: true, previousFit: true),
        .init(name: "APP CODE, stability 0.01", fadeStart: 0, fadeFull: 0.001, velTau: 0.008, leash: 0.01, appPose: true),
        .init(name: "SHIPPED: always, vel 8ms, cap 1.5x", fadeStart: 0, fadeFull: 0.001, velTau: 0.008, leash: 0.03, clamp: 1.5),
        .init(name: "old: fade 2-10, vel 4ms, stab .08", fadeStart: 2, fadeFull: 10, velTau: 0.004, leash: 0.08),
        .init(name: "speed 12-35 (previous)", fadeStart: 12, fadeFull: 35, velTau: 0.008, leash: 0.03),
        .init(name: "no prediction", fadeStart: 1e6, fadeFull: 2e6, velTau: 0.008, leash: 0.03),
        .init(name: "always, vel 8ms", fadeStart: 0, fadeFull: 0.001, velTau: 0.008, leash: 0.03),
        .init(name: "always, vel 16ms", fadeStart: 0, fadeFull: 0.001, velTau: 0.016, leash: 0.03),
        .init(name: "always, vel 24ms", fadeStart: 0, fadeFull: 0.001, velTau: 0.024, leash: 0.03),
        .init(name: "dist 40ms .10-.40", fadeStart: 1e6, fadeFull: 2e6, velTau: 0.008, leash: 0.03, dispWindow: 0.04, d0: 0.10, d1: 0.40),
        .init(name: "always, vel 8ms, cap 1.0x", fadeStart: 0, fadeFull: 0.001, velTau: 0.008, leash: 0.03, clamp: 1.0),
        .init(name: "always, vel 8ms, cap 1.5x", fadeStart: 0, fadeFull: 0.001, velTau: 0.008, leash: 0.03, clamp: 1.5),
        .init(name: "always, vel 12ms, cap 1.2x", fadeStart: 0, fadeFull: 0.001, velTau: 0.012, leash: 0.03, clamp: 1.2),
        .init(name: "decel 1.0, cap 1.5x", fadeStart: 0, fadeFull: 0.001, velTau: 0.008, leash: 0.03, clamp: 1.5, decel: 1.0),
        .init(name: "decel 0.7, cap 1.5x", fadeStart: 0, fadeFull: 0.001, velTau: 0.008, leash: 0.03, clamp: 1.5, decel: 0.7),
        .init(name: "decel 1.0 accel 0.3, cap 1.5x", fadeStart: 0, fadeFull: 0.001, velTau: 0.008, leash: 0.03, clamp: 1.5, decel: 1.0, accel: 0.3),
        .init(name: "decel 1.5, cap 1.5x", fadeStart: 0, fadeFull: 0.001, velTau: 0.008, leash: 0.03, clamp: 1.5, decel: 1.5),
        .init(name: "decel 1.0, no cap", fadeStart: 0, fadeFull: 0.001, velTau: 0.008, leash: 0.03, decel: 1.0),
    ]
    // Display timing: macOS shows a frame 3 refreshes after the display link asks for it, then the
    // app adds its tuned lead, plus half a frame beyond 120 Hz's (see Compositor). XR_FPS / XR_MAXAHEAD override.
    let env = ProcessInfo.processInfo.environment
    let fps = Double(env["XR_FPS"] ?? "") ?? 120
    let maxAhead = Double(env["XR_MAXAHEAD"] ?? "") ?? GlassesHIDService.Pose.maxAhead
    let accParts = (env["XR_ACC"] ?? "0.006,0.018").split(separator: ",").compactMap { Double($0) }
    let accTaus = (accParts.first ?? 0.006, accParts.last ?? 0.018)
    let frame = 1.0 / fps, ahead = 3 * frame + 0.014 + max(0, 0.5 / fps - 0.5 / 120)
    print(String(format: "display %.0f Hz, rendering %.1f ms ahead, prediction capped at %.0f ms", fps, ahead * 1000, maxAhead * 1000))
    print("                                     |   WORKING (<10°/s)                   |  TURNING (≥10°/s)")
    print("config                               | swim rms   p95    | shimmer rms  max | swim rms   p95")
    for c in configs {
        var vel = SIMD3<Float>(repeating: 0)
        var accFast = SIMD3<Float>(repeating: 0), accSlow = SIMD3<Float>(repeating: 0)   // for angular acceleration
        var appAccFast = SIMD3<Float>(repeating: 0), appAccSlow = SIMD3<Float>(repeating: 0)
        var velIdx = 0
        var st = ViewStabilizer(); st.leash = SpatialMath.radians(c.leash)
        var errs: [SIMD2<Float>] = []
        var working: [Bool] = []
        var speeds: [Float] = []   // true head speed, °/s
        var trueVel: [SIMD2<Float>] = []   // yaw/pitch rate of the truth, °/s
        var R = 1.0
        while R + ahead < (t.last ?? 0) - 0.1 {
            let i = sampleIndex(at: R - 0.0005)
            // App's prediction velocity: EMA over samples up to i.
            while velIdx <= i {
                let dt = velIdx > 0 ? t[velIdx] - t[velIdx - 1] : 0.001
                vel += (w[velIdx] - vel) * Float(min(1, dt / c.velTau))
                appAccFast += (w[velIdx] - appAccFast) * Float(min(1, dt / GlassesHIDService.Pose.accelerationTaus.fast))
                appAccSlow += (w[velIdx] - appAccSlow) * Float(min(1, dt / GlassesHIDService.Pose.accelerationTaus.slow))
                accFast += (w[velIdx] - accFast) * Float(min(1, dt / accTaus.0))
                accSlow += (w[velIdx] - accSlow) * Float(min(1, dt / accTaus.1))
                velIdx += 1
            }
            let horizon = Float(min(R + ahead - t[i], maxAhead))
            let speed = simd_length(vel)
            let x = min(max((speed - SpatialMath.radians(c.fadeStart)) / (SpatialMath.radians(c.fadeFull) - SpatialMath.radians(c.fadeStart)), 0), 1)
            var gain = x * x * (3 - 2 * x)
            if c.dispWindow > 0 {
                let past = q[sampleIndex(at: t[i] - c.dispWindow)]
                let moved = deg((past.inverse * q[i]).angle)
                let y = min(max((moved - c.d0) / (c.d1 - c.d0), 0), 1)
                gain = max(gain, y * y * (3 - 2 * y))
            }
            var pred = q[i]
            if c.appPose {
                let pastQ = q[sampleIndex(at: t[i] - GlassesHIDService.Pose.recentWindow)]
                let d = pastQ.inverse * q[i]
                let taus = GlassesHIDService.Pose.accelerationTaus
                let pose = GlassesHIDService.Pose(orientation: q[i], angularVelocity: vel, hostTime: t[i], isStill: false,
                                                  warmedUp: true, recentRotation: GlassesHIDService.Pose.rotationAngle(d),
                                                  angularAcceleration: (appAccFast - appAccSlow) / Float(taus.slow - taus.fast))
                var p2 = pose
                if c.learned { p2.learned = true; p2.features = feats[i]; p2.learnedModel = c.hybrid ? .hybrid : c.previousFit ? .previous : .blended }
                let rendered = st.update(head: p2.predicted(to: R + ahead, maxAhead: maxAhead), angularSpeed: speed, dt: Float(frame))
                let truth = q[sampleIndex(at: R + ahead)]
                let trueSpeed = simd_length(w[sampleIndex(at: R + ahead)])
                let (ry, rp) = SpatialMath.yawPitch(of: rendered), (ty, tp) = SpatialMath.yawPitch(of: truth)
                errs.append(SIMD2(deg(ry - ty), deg(rp - tp)))
                working.append(trueSpeed < SpatialMath.radians(10))
                speeds.append(deg(trueSpeed))
                let (py, pp) = SpatialMath.yawPitch(of: q[sampleIndex(at: R + ahead - frame)])
                trueVel.append(SIMD2(deg(ty - py), deg(tp - pp)) / Float(frame))
                R += frame
                continue
            }
            var predAngle = speed * horizon * gain
            if (c.decel > 0 || c.accel > 0) && speed > 1e-6 {
                let alongV = simd_dot((accFast - accSlow) / Float(accTaus.1 - accTaus.0), vel / speed)   // rad/s² along the motion
                let a = alongV < 0 ? alongV * c.decel : alongV * c.accel
                if a < 0 && speed / -a < horizon {
                    predAngle = speed * speed / (-2 * a) * gain   // comes to rest before the frame is seen
                } else {
                    predAngle = (speed * horizon + 0.5 * a * horizon * horizon) * gain
                }
            }
            if c.clamp > 0 {
                let past = q[sampleIndex(at: t[i] - Double(horizon))]
                predAngle = min(predAngle, c.clamp * (past.inverse * q[i]).angle)
            }
            if predAngle > 1e-7 { pred = (q[i] * simd_quatf(angle: predAngle, axis: vel / speed)).normalized }
            let rendered = st.update(head: pred, angularSpeed: speed, dt: Float(frame))
            let truth = q[sampleIndex(at: R + ahead)]
            let trueSpeed = simd_length(w[sampleIndex(at: R + ahead)])
            // Error as a small yaw/pitch vector in degrees.
            let (ry, rp) = SpatialMath.yawPitch(of: rendered), (ty, tp) = SpatialMath.yawPitch(of: truth)
            errs.append(SIMD2(deg(ry - ty), deg(rp - tp)))
            working.append(trueSpeed < SpatialMath.radians(10))
            speeds.append(deg(trueSpeed))
            let (py, pp) = SpatialMath.yawPitch(of: q[sampleIndex(at: R + ahead - frame)])
            trueVel.append(SIMD2(deg(ty - py), deg(tp - pp)) / Float(frame))
            R += frame
        }
        var swim: [Float] = [], shim: [Float] = [], turn: [Float] = []
        for k in 1..<max(errs.count, 1) {
            if working[k] && working[k - 1] {
                swim.append(simd_length(errs[k])); shim.append(simd_length(errs[k] - errs[k - 1]))
            } else if !working[k] {
                turn.append(simd_length(errs[k]))
            }
        }
        let rms: ([Float]) -> Float = { a in sqrt(a.map { $0 * $0 }.reduce(0, +) / Float(max(a.count, 1))) }
        // Shake: the part of the error faster than ~5 Hz (error minus its centred 100 ms average),
        // and wobble: 1–5 Hz (100 ms average minus 1 s average). Working frames only.
        var shake: [Float] = [], wob: [Float] = [], mShake: [Float] = [], mJit: [Float] = [], mErr: [Float] = []
        if errs.count > 130 {
            var pre = [SIMD2<Float>](repeating: .zero, count: errs.count + 1)
            for k in errs.indices { pre[k + 1] = pre[k] + errs[k] }
            func avg(_ k: Int, _ h: Int) -> SIMD2<Float> { (pre[k + h + 1] - pre[k - h]) / Float(2 * h + 1) }
            for k in 60..<(errs.count - 61) where working[k] {
                let a6 = avg(k, 6), a60 = avg(k, 60)
                shake.append(simd_length(errs[k] - a6)); wob.append(simd_length(a6 - a60))
            }
            // Medium movements (10–60°/s: glances, looking between screens).
            for k in 60..<(errs.count - 61) where speeds[k] >= 10 && speeds[k] < 60 {
                mShake.append(simd_length(errs[k] - avg(k, 6))); mErr.append(simd_length(errs[k]))
                mJit.append(simd_length(errs[k] - errs[k - 1]))
            }
        }
        let p95 = swim.isEmpty ? 0 : swim.sorted()[min(swim.count - 1, Int(Float(swim.count) * 0.95))]
        let tp95 = turn.isEmpty ? 0 : turn.sorted()[min(turn.count - 1, Int(Float(turn.count) * 0.95))]
        // Stop bounce: after a turn (≥ 30°/s) ends (< 5°/s), how far the view overshoots in the
        // direction of travel over the next 200 ms (positive = ran past where the head stopped).
        var bounces: [Float] = []
        var k = 1
        while k < trueVel.count {
            if simd_length(trueVel[k - 1]) >= 30 {
                let dir = simd_normalize(trueVel[k - 1])
                var j = k
                while j < trueVel.count && j < k + 36 && simd_length(trueVel[j]) >= 5 { j += 1 }   // stop within 0.3 s
                if j < trueVel.count && simd_length(trueVel[j]) < 5 {
                    var worst: Float = 0
                    for m in j..<min(errs.count, j + 24) { worst = max(worst, simd_dot(errs[m], dir)) }
                    bounces.append(worst)
                    k = j + 24; continue
                }
            }
            k += 1
        }
        let bounceAvg = bounces.isEmpty ? 0 : bounces.reduce(0, +) / Float(bounces.count)
        let bounceMax = bounces.max() ?? 0
        let sp = shim.sorted()
        let p99 = sp.isEmpty ? 0 : sp[min(sp.count - 1, Int(Float(sp.count) * 0.99))]
        let p999 = sp.isEmpty ? 0 : sp[min(sp.count - 1, Int(Float(sp.count) * 0.999))]
        print(String(format: "%-34@ | SHAKE %.4f° WOBBLE %.4f° | MEDIUM err %.4f° shake %.4f° jit %.4f° | work err %.4f° | jitter rms %.4f° p99 %.4f° | turns err %.4f° | stop bounce avg %.3f° max %.3f° (%d stops)", c.name as NSString,
                     rms(shake), rms(wob), rms(mErr), rms(mShake), rms(mJit), rms(swim), rms(shim), p99, rms(turn), bounceAvg, bounceMax, bounces.count))
        _ = p999
    }
    print("(1 px in the glasses ≈ 0.02°. Frames counted: head slower than 10°/s.)")
}

let args = CommandLine.arguments
if args.count > 1, args[1] == "sweep" { sweepStabilizer(); exit(0) }
if args.count > 1, args[1] == "gpubench" { gpuBench(); exit(0) }
if args.count > 3, args[1] == "accelbias" {
    for csv in args[3...] { print("\n### \((csv as NSString).lastPathComponent)"); accelBias(csv: csv, calibrationPath: args[2]) }
    exit(0)
}
if args.count > 3, args[1] == "wobble" {
    for csv in args[3...] { print("\n### \((csv as NSString).lastPathComponent)"); wobble(csv: csv, calibrationPath: args[2]) }
    exit(0)
}
if args.count > 3, args[1] == "learn" { learnReplay(csvs: Array(args[3...]), calibrationPath: args[2]); exit(0) }
if args.count > 2, args[1] == "lensinfo" { lensInfo(calibrationPath: args[2]); exit(0) }
if args.count > 4, args[1] == "dumpcal" { dumpCalibrated(csv: args[3], calibrationPath: args[2], out: args[4]); exit(0) }
if args.count > 3, args[1] == "replay" {
    for csv in args[3...] { print("\n### \((csv as NSString).lastPathComponent)"); replay(csv: csv, calibrationPath: args[2]) }
    exit(0)
}
if args.count > 1, args[1] == "live" {
    live(seconds: Double(args.count > 2 ? args[2] : "20") ?? 20)
} else {
    unitChecks()
    robustnessChecks(calibrationJSON: args.count > 1 ? FileManager.default.contents(atPath: args[1]) : nil)
    arrangementChecks()
    shaderChecks()
    print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
    exit(failures == 0 ? 0 : 1)
}

/// Small deterministic RNG for repeatable noise in checks.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Float { Float(next() >> 40) / Float(1 << 24) }
    mutating func gauss() -> Float {
        let u1 = max(uniform(), 1e-7), u2 = uniform()
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}
