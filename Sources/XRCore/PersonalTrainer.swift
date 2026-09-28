import Foundation
import Accelerate
import simd

/// Trains a personal head predictor from the wearer's own guided session(s), on the Mac, and says
/// whether it beats the shipped one.
///
/// 1. Rebuilds what the predictor sees at every 1 kHz sample of the recorded sessions (the same
///    filter and features as live), and the targets: where the head turned out to be 10…80 ms later.
/// 2. Splits time into 10 s blocks: three for training, one held back for testing.
/// 3. Refits the still-head linear fit (ridge towards the shipped one) and fine-tunes the whole
///    neural net from the shipped weights (Adam, L2 towards the shipped weights, early stopping).
/// 4. Scores both models on the held-back blocks by the jitter the eye would see (error averaged over
///    ~10 ms, slow drift removed), still and moving separately.
public enum PersonalTrainer {
    public struct Result: Sendable {
        public var model: HeadPredictor.Personal
        /// Eye-visible jitter (glasses px rms) on held-back data: shipped vs personal.
        public var shipped: (still: Float, moving: Float, panning: Float)
        public var personal: (still: Float, moving: Float, panning: Float)
        public var minutes: Double
        /// Clearly better while moving and not worse while still.
        public var isBetter: Bool {
            personal.moving < shipped.moving * 0.97 && personal.still <= shipped.still * 1.01
        }
    }

    public struct Options: Sendable {
        public var epochs = 30
        public var batch = 256
        public var learningRate: Float = 3e-4
        /// Pull towards the shipped net's weights (keeps a short session from wandering off).
        public var anchor: Float = 1e-4
        /// Start the net from random weights instead of the shipped ones (tests only).
        public var fromScratch = false
        public var seed: UInt64 = 1
        public init() {}
    }

    static let pxPerDeg: Float = 1920 / 46
    static let evalMs = 37
    static let stillMU = 30.0

    // MARK: Data

    struct Dataset {
        var x: [Float] = []            // n × 39
        var y: [Float] = []            // n × 24 (degrees, 3 per horizon)
        var speed: [Float] = []
        var t: [Double] = []
        var train: [Bool] = []
        var count: Int { speed.count }
    }

    /// Reads a raw recording (t_ns, gyro °/s, accel g per line) into what the predictor sees.
    static func load(csv url: URL, calibration: GlassesCalibration, into d: inout Dataset, timeOffset: Double, stride: Int) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        var ts: [Double] = [], qs: [simd_quatf] = [], fs: [HeadPredictor.Features?] = [], sp: [Float] = []
        var filter = OrientationFilter(), hp = HeadPredictor()
        var t0: UInt64 = 0, lastT = -1.0
        for line in text.split(separator: "\n").dropFirst() {
            let p = line.split(separator: ",")
            guard p.count == 7, let ns = UInt64(p[0]) else { continue }
            let v = p[1...].compactMap { Float($0) }
            guard v.count == 6 else { continue }
            if t0 == 0 { t0 = ns }
            guard ns >= t0 else { continue }
            let t = Double(ns - t0) / 1e9
            guard t > lastT else { continue }
            let raw = XRealProtocol.RawIMUSample(timestampNs: ns, gyro: SIMD3(v[0], v[1], v[2]), accel: SIMD3(v[3], v[4], v[5]), temperatureC: 30)
            let (g, a) = calibration.correct(raw)
            filter.update(gyro: g, accel: a, dt: lastT >= 0 ? Float(t - lastT) : 0.001)
            lastT = t
            guard filter.initialized else { continue }
            hp.add(gyro: filter.angularVelocity, accel: a)
            let f = hp.features
            ts.append(t); qs.append(filter.presented); fs.append(f)
            sp.append(f.map(HeadPredictor.speed) ?? 0)
        }
        let hs = HeadPredictor.horizonsMs.map { Int($0) }
        guard let maxH = hs.last, ts.count > maxH + 10 else { return false }
        let deg: Float = 180 / .pi
        var i = 0
        while i < ts.count - maxH {
            defer { i += stride }
            guard let f = fs[i] else { continue }
            var row: [Float] = []
            row.reserveCapacity(3 * hs.count)
            for h in hs {
                var dq = qs[i].inverse * qs[i + h]
                if dq.real < 0 { dq = simd_quatf(vector: -dq.vector) }
                let ang = dq.angle
                let r = ang > 1e-9 ? dq.axis * ang : SIMD3<Float>(repeating: 0)
                row += [r.x * deg, r.y * deg, r.z * deg]
            }
            for k in 0..<HeadPredictor.featureCount { d.x.append(f.values[k]) }
            d.y += row
            d.speed.append(sp[i]); d.t.append(timeOffset + ts[i])
            d.train.append(Int((ts[i] / 10).rounded(.down)) % 4 != 3)   // every 4th 10 s block is held back
        }
        return true
    }

    // MARK: Training

    /// Trains on the given session recordings (imu.csv files). Runs for seconds; call off the main thread.
    public static func train(sessions: [URL], calibration: GlassesCalibration, options: Options = Options(),
                             progress: ((Double) -> Void)? = nil) -> Result? {
        var d = Dataset()
        var offset = 0.0
        for url in sessions {
            if load(csv: url, calibration: calibration, into: &d, timeOffset: offset, stride: 2) { offset = (d.t.last ?? offset) + 100 }
        }
        guard d.count > 20_000 else { return nil }
        progress?(0.05)
        let still = fitStill(d)
        progress?(0.1)
        let net = fitNet(d, options: options) { progress?(0.1 + 0.85 * $0) }
        let personal = HeadPredictor.Personal(still: still, net: net)
        guard personal.isUsable else { return nil }
        let shippedScore = score(HeadPredictor.shipped, d)
        let personalScore = score(personal, d)
        progress?(1)
        let minutes = Double(d.count) * 0.002 / 60
        return Result(model: personal, shipped: shippedScore, personal: personalScore, minutes: minutes)
    }

    /// Still-head fit on the training blocks: (XᵀX + μ ΔXᵀΔX + κD) W = XᵀY + μ ΔXᵀΔY + κD W_shipped,
    /// all horizons at once (ΔX: samples 8 ms apart, the jitter penalty used for the shipped fit).
    static func fitStill(_ d: Dataset) -> [[SIMD3<Float>]] {
        let nf = HeadPredictor.featureCount, nh = HeadPredictor.horizonsMs.count, no = 3 * nh
        var xx = [Double](repeating: 0, count: nf * nf), xy = [Double](repeating: 0, count: nf * no)
        var n = 0.0
        let lag = 4   // samples are 2 ms apart: 8 ms
        for i in 0..<d.count where d.train[i] {
            let xi = i * nf, yi = i * no
            for a in 0..<nf {
                let va = Double(d.x[xi + a]); if va == 0 { continue }
                for b in a..<nf { xx[a * nf + b] += va * Double(d.x[xi + b]) }
                for o in 0..<no { xy[a * no + o] += va * Double(d.y[yi + o]) }
            }
            n += 1
            let j = i - lag
            if j >= 0, d.train[j], d.t[i] - d.t[j] < 0.02 {
                let xj = j * nf, yj = j * no
                for a in 0..<nf {
                    let va = Double(d.x[xi + a] - d.x[xj + a]); if va == 0 { continue }
                    for b in a..<nf { xx[a * nf + b] += stillMU * va * Double(d.x[xi + b] - d.x[xj + b]) }
                    for o in 0..<no { xy[a * no + o] += stillMU * va * Double(d.y[yi + o] - d.y[yj + o]) }
                }
            }
        }
        for a in 0..<nf { for b in 0..<a { xx[a * nf + b] = xx[b * nf + a] } }
        // Ridge towards the shipped fit, worth ~5 minutes of data (fades as sessions add up).
        let kappa = 150_000.0 / max(n, 1)
        let deg = 180.0 / Double.pi
        for a in 0..<nf {
            let dd = max(xx[a * nf + a], 1e-12) * kappa
            xx[a * nf + a] += dd
            for h in 0..<nh {
                let w = HeadPredictor.shipped.still[h][a]
                for c in 0..<3 { xy[a * no + 3 * h + c] += dd * Double(w[c]) * deg }
            }
        }
        guard let sol = solveSPD(xx, xy, n: nf, rhs: no) else { return HeadPredictor.shipped.still }
        let rad = Float.pi / 180
        return (0..<nh).map { h in (0..<nf).map { a in
            SIMD3(Float(sol[a * no + 3 * h]), Float(sol[a * no + 3 * h + 1]), Float(sol[a * no + 3 * h + 2])) * rad } }
    }

    static func solveSPD(_ a: [Double], _ b: [Double], n: Int, rhs: Int) -> [Double]? {
        var l = [Double](repeating: 0, count: n * n)
        for i in 0..<n { for j in 0...i {
            var s = a[i * n + j]
            for k in 0..<j { s -= l[i * n + k] * l[j * n + k] }
            if i == j { guard s > 1e-18 else { return nil }; l[i * n + i] = s.squareRoot() } else { l[i * n + j] = s / l[j * n + j] }
        } }
        var x = b
        for c in 0..<rhs {
            for i in 0..<n { var s = x[i * rhs + c]; for k in 0..<i { s -= l[i * n + k] * x[k * rhs + c] }; x[i * rhs + c] = s / l[i * n + i] }
            for i in stride(from: n - 1, through: 0, by: -1) { var s = x[i * rhs + c]; for k in (i + 1)..<n { s -= l[k * n + i] * x[k * rhs + c] }; x[i * rhs + c] = s / l[i * n + i] }
        }
        return x.allSatisfy(\.isFinite) ? x : nil
    }

    /// Fine-tunes the net on the training blocks (Adam, MSE in degrees), early-stopped on the held-back ones.
    static func fitNet(_ d: Dataset, options o: Options, progress: (Double) -> Void) -> HeadPredictor.Net {
        let base = HeadPredictor.shippedNet
        let s = base.sizes
        let (n0, n1, n2, n3) = (s[0], s[1], s[2], s[3])
        var rng = SplitMix(seed: o.seed)
        var net = base
        if o.fromScratch {
            func rand(_ c: Int, _ fanIn: Int) -> [Float] { (0..<c).map { _ in Float(rng.normal()) / Float(fanIn).squareRoot() } }
            net.w1 = rand(n0 * n1, n0); net.w2 = rand(n1 * n2, n1); net.w3 = rand(n2 * n3, n2)
            net.b1 = .init(repeating: 0, count: n1); net.b2 = .init(repeating: 0, count: n2); net.b3 = .init(repeating: 0, count: n3)
        }
        // Standardised inputs (the net's own normalisation, kept fixed).
        var xs = d.x
        for i in 0..<d.count { for k in 0..<n0 { xs[i * n0 + k] = (xs[i * n0 + k] - base.mean[k]) / max(base.scale[k], 1e-12) } }
        let trainIdx = (0..<d.count).filter { d.train[$0] }
        let testIdx = (0..<d.count).filter { !d.train[$0] }.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        guard trainIdx.count > 1000, testIdx.count > 200 else { return net }

        var params = [net.w1, net.b1, net.w2, net.b2, net.w3, net.b3]
        let anchor = o.fromScratch ? nil : [base.w1, base.b1, base.w2, base.b2, base.w3, base.b3]
        var m = params.map { [Float](repeating: 0, count: $0.count) }, v = m
        var step = 0
        let b1c: Float = 0.9, b2c: Float = 0.999
        var best = params, bestLoss = Float.infinity, sinceBest = 0

        let B = o.batch
        var xb = [Float](repeating: 0, count: B * n0), yb = [Float](repeating: 0, count: B * n3)
        var h1 = [Float](repeating: 0, count: B * n1), h2 = [Float](repeating: 0, count: B * n2), out = [Float](repeating: 0, count: B * n3)
        var dOut = out, dH2 = h2, dH1 = h1
        var grads = params.map { [Float](repeating: 0, count: $0.count) }

        func forward(_ rows: Int) {
            // h1 = tanh(x W1 + b1), h2 = tanh(h1 W2 + b2), out = h2 W3 + b3
            for r in 0..<rows { for j in 0..<n1 { h1[r * n1 + j] = params[1][j] } }
            cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(rows), Int32(n1), Int32(n0), 1, xb, Int32(n0), params[0], Int32(n1), 1, &h1, Int32(n1))
            var c1 = Int32(rows * n1); vvtanhf(&h1, h1, &c1)
            for r in 0..<rows { for j in 0..<n2 { h2[r * n2 + j] = params[3][j] } }
            cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(rows), Int32(n2), Int32(n1), 1, h1, Int32(n1), params[2], Int32(n2), 1, &h2, Int32(n2))
            var c2 = Int32(rows * n2); vvtanhf(&h2, h2, &c2)
            for r in 0..<rows { for j in 0..<n3 { out[r * n3 + j] = params[5][j] } }
            cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(rows), Int32(n3), Int32(n2), 1, h2, Int32(n2), params[4], Int32(n3), 1, &out, Int32(n3))
        }
        func fill(_ idx: ArraySlice<Int>) {
            for (r, i) in idx.enumerated() {
                for k in 0..<n0 { xb[r * n0 + k] = xs[i * n0 + k] }
                for k in 0..<n3 { yb[r * n3 + k] = d.y[i * n3 + k] }
            }
        }
        func testLoss() -> Float {
            var total: Float = 0, count = 0
            var i = 0
            while i < testIdx.count {
                let chunk = testIdx[i..<min(i + B, testIdx.count)]
                fill(chunk); forward(chunk.count)
                for k in 0..<(chunk.count * n3) { let e = out[k] - yb[k]; total += e * e }
                count += chunk.count; i += B
            }
            return total / Float(max(count, 1))
        }

        var order = trainIdx
        for epoch in 0..<o.epochs {
            for k in stride(from: order.count - 1, to: 0, by: -1) { order.swapAt(k, Int(rng.next() % UInt64(k + 1))) }
            var i = 0
            while i + B <= order.count {
                let rows = B
                fill(order[i..<(i + B)]); forward(rows)
                // Backward (loss = mean over batch of Σ (out − y)²).
                for k in 0..<(rows * n3) { dOut[k] = 2 * (out[k] - yb[k]) / Float(rows) }
                cblas_sgemm(CblasRowMajor, CblasTrans, CblasNoTrans, Int32(n2), Int32(n3), Int32(rows), 1, h2, Int32(n2), dOut, Int32(n3), 0, &grads[4], Int32(n3))
                for j in 0..<n3 { var s: Float = 0; for r in 0..<rows { s += dOut[r * n3 + j] }; grads[5][j] = s }
                cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(rows), Int32(n2), Int32(n3), 1, dOut, Int32(n3), params[4], Int32(n3), 0, &dH2, Int32(n2))
                for k in 0..<(rows * n2) { dH2[k] *= 1 - h2[k] * h2[k] }
                cblas_sgemm(CblasRowMajor, CblasTrans, CblasNoTrans, Int32(n1), Int32(n2), Int32(rows), 1, h1, Int32(n1), dH2, Int32(n2), 0, &grads[2], Int32(n2))
                for j in 0..<n2 { var s: Float = 0; for r in 0..<rows { s += dH2[r * n2 + j] }; grads[3][j] = s }
                cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(rows), Int32(n1), Int32(n2), 1, dH2, Int32(n2), params[2], Int32(n2), 0, &dH1, Int32(n1))
                for k in 0..<(rows * n1) { dH1[k] *= 1 - h1[k] * h1[k] }
                cblas_sgemm(CblasRowMajor, CblasTrans, CblasNoTrans, Int32(n0), Int32(n1), Int32(rows), 1, xb, Int32(n0), dH1, Int32(n1), 0, &grads[0], Int32(n1))
                for j in 0..<n1 { var s: Float = 0; for r in 0..<rows { s += dH1[r * n1 + j] }; grads[1][j] = s }
                // Adam, with a pull towards the shipped weights.
                step += 1
                let lrT = o.learningRate * (1 - pow(b2c, Float(step))).squareRoot() / (1 - pow(b1c, Float(step)))
                for p in 0..<params.count {
                    for k in 0..<params[p].count {
                        var g = grads[p][k]
                        if let a = anchor { g += o.anchor * (params[p][k] - a[p][k]) }
                        m[p][k] = b1c * m[p][k] + (1 - b1c) * g
                        v[p][k] = b2c * v[p][k] + (1 - b2c) * g * g
                        params[p][k] -= lrT * m[p][k] / (v[p][k].squareRoot() + 1e-8)
                    }
                }
                i += B
            }
            let loss = testLoss()
            if ProcessInfo.processInfo.environment["TRAIN_VERBOSE"] != nil { print(String(format: "    epoch %d: held-back loss %.4f", epoch + 1, loss)) }
            if loss < bestLoss * 0.999 { bestLoss = loss; best = params; sinceBest = 0 } else { sinceBest += 1 }
            progress(Double(epoch + 1) / Double(o.epochs))
            if sinceBest >= 4 { break }
        }
        net.w1 = best[0]; net.b1 = best[1]; net.w2 = best[2]; net.b2 = best[3]; net.w3 = best[4]; net.b3 = best[5]
        return net
    }

    // MARK: Scoring

    /// Eye-visible jitter (glasses px rms) on the held-back blocks: prediction error at the usual
    /// look-ahead, averaged over ~10 ms, minus its 100 ms average; still (<5°/s), moving, panning 20–60°/s.
    static func score(_ model: HeadPredictor.Personal, _ d: Dataset) -> (still: Float, moving: Float, panning: Float) {
        let hs = HeadPredictor.horizonsMs.map { Int($0) }
        guard let k = hs.firstIndex(where: { $0 >= evalMs }), k > 0 else { return (.infinity, .infinity, .infinity) }
        let a = Float(evalMs - hs[k - 1]) / Float(hs[k] - hs[k - 1])
        let no = 3 * hs.count
        var e: [SIMD2<Float>] = [], sp: [Float] = [], ts: [Double] = []
        for i in 0..<d.count where !d.train[i] {
            let y0 = SIMD2(d.y[i * no + 3 * (k - 1)], d.y[i * no + 3 * (k - 1) + 1])
            let y1 = SIMD2(d.y[i * no + 3 * k], d.y[i * no + 3 * k + 1])
            let target = y0 * (1 - a) + y1 * a
            var f = HeadPredictor.Features()
            for c in 0..<HeadPredictor.featureCount { f.values[c] = d.x[i * HeadPredictor.featureCount + c] }
            let r = HeadPredictor.hybridRotation(f, seconds: Double(evalMs) / 1000, model: model) * (180 / .pi)
            e.append(target - SIMD2(r.x, r.y)); sp.append(d.speed[i]); ts.append(d.t[i])
        }
        guard e.count > 500 else { return (.infinity, .infinity, .infinity) }
        // Samples are 2 ms apart: ~10 ms = 5, 100 ms = 51 (within contiguous stretches).
        func avg(_ v: [SIMD2<Float>], _ w: Int) -> [SIMD2<Float>] {
            var out = v
            for i in 0..<v.count {
                var s = SIMD2<Float>(repeating: 0), c: Float = 0
                for j in max(0, i - w / 2)...min(v.count - 1, i + w / 2) where abs(ts[j] - ts[i]) < 0.2 { s += v[j]; c += 1 }
                out[i] = s / max(c, 1)
            }
            return out
        }
        let seen = avg(e, 5), drift = avg(seen, 51)
        var acc = [Float](repeating: 0, count: 3), cnt = [Float](repeating: 0, count: 3)
        for i in 0..<e.count {
            let j = simd_length_squared(seen[i] - drift[i])
            if sp[i] < 5 { acc[0] += j; cnt[0] += 1 } else { acc[1] += j; cnt[1] += 1 }
            if sp[i] >= 20 && sp[i] < 60 { acc[2] += j; cnt[2] += 1 }
        }
        let r = (0..<3).map { (acc[$0] / max(cnt[$0], 1)).squareRoot() * pxPerDeg }
        return (r[0], r[1], r[2])
    }
}

/// Small deterministic RNG (shuffling, initialisation).
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func normal() -> Double {
        let u1 = Double(next() % 1_000_000 + 1) / 1_000_001, u2 = Double(next() % 1_000_000) / 1_000_000
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
