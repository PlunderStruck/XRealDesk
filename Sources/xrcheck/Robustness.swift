import CoreGraphics
import Foundation
import simd
import XRCore

// Adversarial checks: feed every parser and every piece of math garbage, extremes and impossible
// sequences, and require that nothing crashes, nothing turns NaN, and tracking recovers.
// A deterministic generator keeps failures reproducible.

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func finite(_ q: simd_quatf) -> Bool { q.vector.x.isFinite && q.vector.y.isFinite && q.vector.z.isFinite && q.vector.w.isFinite }
private func finite(_ v: SIMD2<Float>) -> Bool { v.x.isFinite && v.y.isFinite }
private func finite(_ v: SIMD3<Float>) -> Bool { v.x.isFinite && v.y.isFinite && v.z.isFinite }

func robustnessChecks(calibrationJSON: Data?) {
    var rng = SplitMix64(state: 0xC0FFEE)

    print("robustness: USB reports")
    var imuParsed = 0, mcuParsed = 0, nonFinite = 0
    for _ in 0..<200_000 {
        let n = Int.random(in: 0...96, using: &rng)
        var bytes = (0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) }
        if n >= 2, Bool.random(using: &rng) { bytes[0] = 0x01; bytes[1] = 0x02 }         // IMU data signature
        if n >= 1, Int.random(in: 0..<4, using: &rng) == 0 { bytes[0] = 0xFD }           // MCU frame head
        if n >= 1, Int.random(in: 0..<4, using: &rng) == 0 { bytes[0] = 0xAA }           // IMU reply head
        if let s = bytes.withUnsafeBufferPointer({ XRealProtocol.parseIMUSample($0) }) {
            imuParsed += 1
            if !finite(s.gyro) || !finite(s.accel) || !s.temperatureC.isFinite { nonFinite += 1 }
        }
        if XRealProtocol.parseMCUReply(bytes) != nil { mcuParsed += 1 }
        _ = XRealProtocol.parseIMUReply(bytes)
    }
    check(true, "200k random/truncated reports parsed without crashing (\(imuParsed) IMU, \(mcuParsed) MCU accepted)")
    check(nonFinite == 0, "parsed IMU samples are always finite numbers (\(nonFinite) weren't)")

    print("robustness: calibration blob")
    var parsedOK = 0, badValues = 0
    let original = calibrationJSON.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
    for i in 0..<3_000 {
        var data: Data
        if let original, i % 3 != 0 {
            var obj = original
            mutate(&obj, rng: &rng, depth: 0)
            data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        } else if let calibrationJSON, i % 3 == 0, i % 2 == 0 {
            data = calibrationJSON.prefix(Int.random(in: 0...calibrationJSON.count, using: &rng))   // truncated download
        } else {
            data = Data((0..<Int.random(in: 0...400, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })
        }
        guard let cal = GlassesCalibration.parse(json: data) else { continue }
        parsedOK += 1
        var ok = cal.focalX.isFinite && cal.focalY.isFinite && cal.centerX.isFinite && cal.centerY.isFinite
            && cal.focalX > 0 && cal.focalY > 0 && finite(cal.resolution) && cal.resolution.x >= 1 && cal.resolution.y >= 1
        if let g = cal.distortion {
            for _ in 0..<20 {
                let p = g.sample(Float.random(in: -500...2500, using: &rng), Float.random(in: -500...1500, using: &rng))
                if !finite(p) { ok = false }
            }
        }
        for e in 0..<2 where !cal.eyeView(e).columns.3.x.isFinite { ok = false }
        if !ok { badValues += 1 }
    }
    check(true, "3000 corrupted / truncated / random calibration blobs handled without crashing (\(parsedOK) accepted)")
    check(badValues == 0, "accepted calibrations always have usable, finite values (\(badValues) didn't)")

    print("robustness: lens map sampling")
    if let cal = calibrationJSON.flatMap({ GlassesCalibration.parse(json: $0) }), let g = cal.distortion {
        let extremes: [Float] = [-.infinity, -1e30, -1, 0, 0.5, 960, 1919.999, 1920, 1e9, .infinity]
        var bad = 0
        for x in extremes { for y in extremes where !finite(g.sample(x, y)) && x.isFinite && y.isFinite { bad += 1 } }
        _ = g.sample(.nan, .nan)
        check(bad == 0, "lens map stays finite at any finite coordinate, including far outside the display")
        let m = g.uniformMap(width: 1920, height: 1080, step: 8)
        check(m.values.count == m.w * m.h && m.values.allSatisfy { finite($0) }, "uniform lens map is complete and finite")
    }

    print("robustness: sensor fusion under garbage")
    let level = SIMD3<Float>(0, -1, 0)    // head frame: gravity pulls down (accelerometer reads +1 g up… see calibration)
    _ = level
    func settle(_ f: inout OrientationFilter, seconds: Float, gyro: SIMD3<Float> = .zero) {
        for _ in 0..<Int(seconds * 1000) { f.update(gyro: gyro, accel: SIMD3(0, 1, 0), dt: 0.001) }
    }
    let poisons: [(String, SIMD3<Float>, SIMD3<Float>, Float)] = [
        ("NaN gyro", SIMD3(.nan, 0, 0), SIMD3(0, 1, 0), 0.001),
        ("infinite gyro", SIMD3(.infinity, 0, 0), SIMD3(0, 1, 0), 0.001),
        ("corrupt packet: 1e11 °/s", SIMD3(1e9, -1e9, 1e9), SIMD3(0, 1, 0), 0.001),
        ("NaN accel", .zero, SIMD3(.nan, .nan, .nan), 0.001),
        ("free fall (zero accel)", .zero, .zero, 0.001),
        ("huge accel", .zero, SIMD3(1e20, 0, 0), 0.001),
        ("zero dt", SIMD3(1, 0, 0), SIMD3(0, 1, 0), 0),
        ("negative dt (clock went back)", SIMD3(1, 0, 0), SIMD3(0, 1, 0), -5),
        ("10 s gap (sleep)", .zero, SIMD3(0, 1, 0), 10),
        ("NaN dt", SIMD3(0.1, 0, 0), SIMD3(0, 1, 0), .nan),
    ]
    for (name, g, a, dt) in poisons {
        var f = OrientationFilter()
        settle(&f, seconds: 2)
        for _ in 0..<50 { f.update(gyro: g, accel: a, dt: dt) }
        let during = finite(f.orientation) && finite(f.predicted(by: 0.03))
        settle(&f, seconds: 5)
        let (_, pitch) = SpatialMath.yawPitch(of: f.orientation)
        let recovered = finite(f.orientation) && abs(SpatialMath.degrees(pitch)) < 3
        check(during && recovered, "\(name): orientation stays finite and settles back to level (pitch \(String(format: "%.1f", SpatialMath.degrees(pitch)))°)")
    }

    print("robustness: prediction")
    let pose = GlassesHIDService.Pose(orientation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), angularVelocity: SIMD3(.nan, 0, 0),
                                      hostTime: 10, isStill: false, warmedUp: true, recentRotation: 1)
    check(finite(pose.predicted(to: 10.03)), "prediction with a NaN velocity stays finite")
    let fast = GlassesHIDService.Pose(orientation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), angularVelocity: SIMD3(0, 1e6, 0),
                                      hostTime: 10, isStill: false, warmedUp: true, recentRotation: .infinity)
    check(finite(fast.predicted(to: 11)) && finite(fast.predicted(to: -100)) && finite(fast.predicted(to: .infinity)),
          "prediction stays finite for absurd speeds and target times")

    print("robustness: stabilizer and smart follow")
    var st = ViewStabilizer()
    st.leash = SpatialMath.radians(0.03)
    let good = SpatialMath.orientation(yaw: 0.2, pitch: 0.1)
    for (h, speed, dt) in [(good, Float.nan, Float(0.008)), (good, 1, 0), (good, 1, -1), (good, 1, 100),
                           (simd_quatf(vector: SIMD4(.nan, .nan, .nan, .nan)), 1, 0.008)] {
        _ = st.update(head: h, angularSpeed: speed, dt: dt)
    }
    var out = good
    for _ in 0..<200 { out = st.update(head: good, angularSpeed: 0, dt: 0.008) }
    check(finite(out) && (out.inverse * good).angle < SpatialMath.radians(0.5),
          "stabilizer recovers from NaN / zero / negative / huge inputs")
    let layouts = [ScreenLayout(count: 1, rows: 1, widthDegrees: 33, aspect: 16.0 / 9, gapDegrees: 1.5, curve: 0.5),
                   ScreenLayout(count: 8, rows: 3, widthDegrees: 100, aspect: 16.0 / 9, gapDegrees: 10, curve: 1)]
    var smartOK = true
    for layout in layouts {
        var sf = SmartFollow()
        var anchor = SIMD2<Float>(0, 0)
        for (head, dt) in [(SIMD2<Float>(.pi, 0), Float(0.008)), (SIMD2(-.pi, 1.5), 0.008), (SIMD2(.nan, 0), 0.008),
                           (SIMD2(0.3, 0.1), 0), (SIMD2(0.3, 0.1), 50), (SIMD2(0.3, 0.1), -1)] {
            anchor = sf.update(head: head, anchor: anchor, layout: layout, dt: dt)
        }
        for _ in 0..<300 { anchor = sf.update(head: SIMD2(0.1, 0), anchor: anchor, layout: layout, dt: 0.008) }
        if !finite(anchor) { smartOK = false }
    }
    check(smartOK, "smart follow recovers from ±180° wrap, NaN heads and bad time steps")

    print("robustness: layouts")
    var layoutBad = 0, layoutCount = 0, roundTripBad = 0
    for count in [0, 1, 2, 3, 5, 8, 9] {
        for rows in [0, 1, 2, 3, 5] {
            for width: Float in [0, 1, 33, 100, 180, 360] {
                for curve: Float in [-1, 0, 0.001, 0.55, 1, 2] {
                    for aspect: Float in [0, 0.1, 16.0 / 9, 10] {
                        let l = ScreenLayout(count: count, rows: rows, widthDegrees: width, aspect: aspect, gapDegrees: 1.5,
                                             curve: curve, tiltDegrees: 15, distance: 1.5)
                        layoutCount += 1
                        let fine = l.panels.allSatisfy { finite($0.center) && $0.yaw.isFinite && $0.pitch.isFinite && finite($0.size) }
                        if !fine { layoutBad += 1; continue }
                        // Sane layouts: looking at a screen's centre must hit that screen.
                        if count >= 1, rows >= 1, (16...100).contains(width), aspect > 0.5, (0...1).contains(curve) {
                            for p in l.panels {
                                let dir = simd_normalize(p.center)
                                if l.hit(direction: dir, margin: 0)?.index != p.index {
                                    if roundTripBad < 6 { print("       miss: \(count) screens, \(rows) rows, \(width)°, curve \(curve), aspect \(aspect), screen \(p.index) center \(p.center) → \(String(describing: l.hit(direction: dir, margin: 0)))") }
                                    roundTripBad += 1
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    check(layoutBad == 0, "\(layoutCount) layouts (0-9 screens, 0-5 rows, 0-360°, curve -1…2, odd aspects) stay finite (\(layoutBad) didn't)")
    check(roundTripBad == 0, "looking at any screen's centre hits that screen, in every sane layout (\(roundTripBad) misses)")

    print("robustness: angles")
    var angleBad = 0
    for pitch in stride(from: Float(-90), through: 90, by: 1) {
        for yaw in stride(from: Float(-180), through: 180, by: 7.5) {
            let q = SpatialMath.orientation(yaw: SpatialMath.radians(yaw), pitch: SpatialMath.radians(pitch))
            let (y, p) = SpatialMath.yawPitch(of: q)
            if !y.isFinite || !p.isFinite { angleBad += 1; continue }
            if abs(pitch) < 89, abs(SpatialMath.degrees(p) - pitch) > 0.01 { angleBad += 1 }
        }
    }
    check(angleBad == 0, "yaw/pitch conversion is finite everywhere (incl. straight up/down) and round-trips")
}

/// Random structural damage to a JSON object: drop keys, wrong types, NaN-ish numbers, wrong sizes.
private func mutate(_ obj: inout [String: Any], rng: inout SplitMix64, depth: Int) {
    for key in Array(obj.keys) {
        let roll = Int.random(in: 0..<14, using: &rng)
        switch roll {
        case 0: obj.removeValue(forKey: key)
        case 1: obj[key] = "garbage"
        case 2: obj[key] = 0
        case 3: obj[key] = -1e30
        case 4: obj[key] = [] as [Any]
        case 5:
            if var arr = obj[key] as? [Any], !arr.isEmpty {
                arr.removeLast(Int.random(in: 1...arr.count, using: &rng))
                obj[key] = arr
            }
        case 6:
            if var arr = obj[key] as? [Any], !arr.isEmpty {
                arr[Int.random(in: 0..<arr.count, using: &rng)] = Bool.random(using: &rng) ? 1e38 : -0.0
                obj[key] = arr
            }
        case 7: obj[key] = 100_000
        default:
            if var sub = obj[key] as? [String: Any], depth < 4 {
                mutate(&sub, rng: &rng, depth: depth + 1)
                obj[key] = sub
            }
        }
    }
}

func arrangementChecks() {
    print("robustness: display arrangement")
    func touchLength(_ a: CGRect, _ b: CGRect) -> CGFloat {
        // Length of the shared edge (0 if they don't touch along an edge).
        if a.maxX == b.minX || b.maxX == a.minX { return max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY)) }
        if a.maxY == b.minY || b.maxY == a.minY { return max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX)) }
        return 0
    }
    var overlaps = 0, disconnected = 0, noCrossing = 0, cases = 0, unreachable = 0
    let homes = [CGRect(x: 0, y: 0, width: 1728, height: 1117), CGRect(x: 0, y: 0, width: 1512, height: 982),
                 CGRect(x: 0, y: 0, width: 2560, height: 1440)]
    let sizes = [CGSize(width: 1600, height: 900), CGSize(width: 1920, height: 1080), CGSize(width: 1280, height: 720),
                 CGSize(width: 3840, height: 1080), CGSize(width: 1920, height: 1200)]
    for home in homes { for size in sizes { for placement in [ScreenPlacement.above, .below, .left, .right] {
        for count in 1...8 { for rows in 1...3 {
            cases += 1
            let origins = Arrangement.gridOrigins(home: home, count: count, rows: rows, screenSize: size, placement: placement)
            let rects = origins.map { CGRect(origin: $0, size: size) }
            let all = [home] + rects
            // 1. Nothing overlaps (macOS would shove displays around).
            var bad = false
            for i in 0..<all.count { for j in (i + 1)..<all.count where all[i].intersection(all[j]).width > 0.5 && all[i].intersection(all[j]).height > 0.5 { bad = true } }
            if bad { overlaps += 1 }
            // 2. Everything is one connected arrangement.
            var seen: Set<Int> = [0], stack = [0]
            while let k = stack.popLast() {
                for j in all.indices where !seen.contains(j) && touchLength(all[k], all[j]) > 0 { seen.insert(j); stack.append(j) }
            }
            if seen.count != all.count {
                if disconnected < 4 { print("       disconnected: \(placement) \(count) screens \(rows) rows \(Int(size.width))x\(Int(size.height)) home \(Int(home.width))x\(Int(home.height)): \(rects.map { "(\(Int($0.minX)),\(Int($0.minY)))" }.joined(separator: " "))") }
                disconnected += 1
            }
            // 3. The mouse can cross from the laptop on the chosen side.
            let crossing = rects.contains { r in
                switch placement {
                case .above: return r.maxY == home.minY && touchLength(r, home) > 0
                case .below: return r.minY == home.maxY && touchLength(r, home) > 0
                case .left: return r.maxX == home.minX && touchLength(r, home) > 0
                case .right: return r.minX == home.maxX && touchLength(r, home) > 0
                case .custom: return true
                }
            }
            if !crossing { noCrossing += 1 }
            // 4. With up to 2 screens next to the laptop, each of them can be reached directly.
            let adjacent = rects.filter { r in
                switch placement {
                case .above: return r.maxY == home.minY
                case .below: return r.minY == home.maxY
                case .left: return r.maxX == home.minX
                case .right: return r.minX == home.maxX
                case .custom: return false
                }
            }
            // …when that's geometrically possible: screens centred on the laptop's edge can all touch it
            // only if together they're no longer than the edge plus a screen on each side.
            let along = (placement == .above || placement == .below) ? (size.width, home.width) : (size.height, home.height)
            let possible = CGFloat(adjacent.count) * along.0 < along.1 + 2 * along.0 - 2
            if adjacent.count <= 2, possible, adjacent.contains(where: { touchLength($0, home) == 0 }) {
                if unreachable < 4 { print("       unreachable: \(placement) \(count) screens \(rows) rows \(Int(size.width))x\(Int(size.height)) home \(Int(home.width))x\(Int(home.height)): \(rects.map { "(\(Int($0.minX)),\(Int($0.minY)))" }.joined(separator: " "))") }
                unreachable += 1
            }
        } }
    } } }
    check(overlaps == 0, "\(cases) arrangements (3 Macs, 5 sizes, 4 sides, 1-8 screens, 1-3 rows): no screens overlap (\(overlaps) did)")
    check(disconnected == 0, "every arrangement is one connected piece (\(disconnected) weren't)")
    check(noCrossing == 0, "the mouse can always cross from the Mac on the chosen side (\(noCrossing) couldn't)")
    check(unreachable == 0, "with one or two screens next to the Mac, the mouse reaches each of them directly (\(unreachable) failed)")
    let custom = Arrangement.gridOrigins(home: homes[0], count: 3, rows: 1, screenSize: sizes[0], placement: .custom,
                                         customOffsets: [1: CGPoint(x: 100, y: -900)])
    check(custom[1] == CGPoint(x: 100, y: -900) && custom.count == 3, "custom placement keeps your own positions")
    // Screens added after saving a custom layout must not land on top of saved ones.
    var customOverlaps = 0
    var rng = SplitMix64(state: 7)
    for _ in 0..<500 {
        let count = Int.random(in: 1...8, using: &rng)
        var offsets: [Int: CGPoint] = [:]
        var placed: [CGRect] = [homes[0]]
        for i in 0..<count where Bool.random(using: &rng) {
            // A saved layout macOS accepted: non-overlapping positions around the laptop.
            for _ in 0..<20 {
                let p = CGPoint(x: CGFloat(Int.random(in: -4...3, using: &rng)) * 1600, y: CGFloat(Int.random(in: -3...1, using: &rng)) * 900 - 900)
                let r = CGRect(origin: p, size: sizes[0])
                if !placed.contains(where: { $0.intersection(r).width > 0.5 && $0.intersection(r).height > 0.5 }) {
                    offsets[i] = p; placed.append(r); break
                }
            }
        }
        let rects = Arrangement.gridOrigins(home: homes[0], count: count, rows: 1, screenSize: sizes[0], placement: .custom,
                                            customOffsets: offsets).map { CGRect(origin: $0, size: sizes[0]) }
        let all = [homes[0]] + rects
        for i in 0..<all.count { for j in (i + 1)..<all.count where all[i].intersection(all[j]).width > 0.5 && all[i].intersection(all[j]).height > 0.5 {
            customOverlaps += 1 } }
    }
    check(customOverlaps == 0, "custom layouts with screens added later never overlap (\(customOverlaps) overlaps)")
    check(Arrangement.gridOrigins(home: homes[0], count: 0, rows: 0, screenSize: sizes[0], placement: .above).isEmpty,
          "zero screens: nothing to place (no crash)")
}
