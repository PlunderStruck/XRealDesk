import Foundation
import simd
import os

/// Keeps improving the head predictor from the wearer's own head motion, safely.
///
/// Both parts of the hybrid predictor that adapt are linear in what they're fitted on: the still-head
/// fit reads the 39 features directly, and the neural net's output layer reads its last hidden layer.
/// So each can be re-solved from running sums (feature × feature, feature × target) that are cheap to
/// update at 1 kHz. The target for a sample is simply where the head turned out to be h ms later.
///
/// Safety: time alternates between 20 s blocks that feed the sums and 20 s blocks that are only kept
/// for testing. A candidate fit is adopted only if, on those held-back minutes, the jitter the eye
/// would see (error averaged over a frame's hold, then over ~10 ms, slow drift removed) is lower
/// while moving and not worse while still. The shipped fit acts as a prior that fades as data grows,
/// so a few odd minutes can't pull the predictor far. State is saved per headset.
public final class OnlineLearner: @unchecked Sendable {
    public struct Status: Sendable {
        public var minutesLearned: Double = 0
        public var adoptions = 0
        public var lastScore: (current: Float, candidate: Float)?   // moving jitter, degrees
    }

    /// Wearer-specific: learning only runs while this is set (glasses worn, tracking).
    public var enabled: Bool {
        get { lock.withLock { $0.enabled } }
        set { lock.withLock { $0.enabled = newValue } }
    }
    public var status: Status { lock.withLock { $0.status } }
    public var log: ((String) -> Void)?
    /// Called (background queue) when an improvement is adopted: how much steadier while moving (0…1).
    public var onImproved: ((Float) -> Void)?

    static let horizons = HeadPredictor.horizonsMs.map { Int($0) }   // ms
    static let nf = HeadPredictor.featureCount
    static let stillMU = 30.0                       // jitter penalty of the still-head fit (as shipped)
    static let priorSamples = 300_000.0             // the shipped fit counts as ~5 min of data
    static let blockSeconds = 20.0
    static let solveEverySeconds = 60.0
    static let evalHorizonMs = 37                    // typical pose → middle of frame at 120 Hz

    private struct State {
        var enabled = false
        var status = Status()
    }
    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let solveQueue = DispatchQueue(label: "XRealDesk.OnlineLearner", qos: .utility)

    // --- Sensor-thread state (only touched in add()).
    private struct Sample {
        var t: Double
        var f: HeadPredictor.Features
        var q: simd_quatf
        var hidden: [Float]?
        var targets: [SIMD3<Float>?]
        var speed: Float
    }
    private var ring: [Sample] = []
    private var ringStart = 0
    private var samplesSinceSolve = 0
    private var trainingTime = 0.0
    private var lastT: Double?
    private var blockStart: Double?
    private var trainingBlock = true
    private var hiddenStride = 0

    // Sums (Double): still-head fit and net output layer.
    private var xx: [Double]                // nf × nf
    private var xy: [[Double]]              // per horizon: nf × 3
    private var dxx: [Double]               // jitter penalty: differences 8 ms apart
    private var dxy: [[Double]]
    private var hh: [Double]                // (nh+1) × (nh+1)
    private var hy: [Double]                // (nh+1) × nOut
    private var n = 0.0, nh = 0.0
    // Held-back test data (every 8 ms): features, hidden layer, target at the evaluation horizon, speed.
    private var testX: [HeadPredictor.Features] = []
    private var testH: [[Float]] = []
    private var testY: [SIMD3<Float>] = []
    private var testS: [Float] = []
    private var testT: [Double] = []
    private var testStride = 0

    private let nHidden: Int
    private let nOut: Int
    private var storeURL: URL?

    public init() {
        let nf = OnlineLearner.nf
        nHidden = HeadPredictor.netSizes.count == 4 ? HeadPredictor.netSizes[2] : 0
        nOut = HeadPredictor.netSizes.last ?? 0
        xx = [Double](repeating: 0, count: nf * nf)
        xy = Array(repeating: [Double](repeating: 0, count: nf * 3), count: OnlineLearner.horizons.count)
        dxx = xx; dxy = xy
        hh = [Double](repeating: 0, count: (nHidden + 1) * (nHidden + 1))
        hy = [Double](repeating: 0, count: (nHidden + 1) * nOut)
    }

    // MARK: Per headset persistence

    /// Loads (or starts) the learned state for a headset and applies its learned fit.
    public func attach(serial: String, directory: URL) {
        solveQueue.sync {
            let url = directory.appendingPathComponent("learned-\(serial).plist")
            storeURL = url
            guard let d = NSDictionary(contentsOf: url) as? [String: Any],
                  (d["version"] as? Int) == 1,
                  let still = d["still"] as? [Double], let w3 = d["netW3"] as? [Double], let b3 = d["netB3"] as? [Double],
                  let minutes = d["minutes"] as? Double, let adoptions = d["adoptions"] as? Int else {
                HeadPredictor.learned = HeadPredictor.shipped
                return
            }
            let nf = OnlineLearner.nf, nh = OnlineLearner.horizons.count
            guard still.count == nh * nf * 3 else { return }
            let s: [[SIMD3<Float>]] = (0..<nh).map { h in (0..<nf).map { i in
                let k = (h * nf + i) * 3; return SIMD3(Float(still[k]), Float(still[k + 1]), Float(still[k + 2])) } }
            let learned = HeadPredictor.Learned(still: s, netW3: w3.map(Float.init), netB3: b3.map(Float.init))
            if learned.isUsable {
                HeadPredictor.learned = learned
                lock.withLock { $0.status.minutesLearned = minutes; $0.status.adoptions = adoptions }
                log?(String(format: "Tracking has learned from %.0f min of your head motion (%d improvements)", minutes, adoptions))
            }
        }
    }

    /// Back to the shipped fit (the learned one and its data are forgotten).
    public func reset() {
        solveQueue.async { [self] in
            HeadPredictor.learned = HeadPredictor.shipped
            if let url = storeURL { try? FileManager.default.removeItem(at: url) }
            lock.withLock { $0.status = Status() }
            log?("Learned tracking reset to the shipped fit")
        }
        pendingReset = true
    }
    private var pendingReset = false

    private func save(_ l: HeadPredictor.Learned, minutes: Double, adoptions: Int) {
        guard let url = storeURL else { return }
        let still = l.still.flatMap { $0.flatMap { [Double($0.x), Double($0.y), Double($0.z)] } }
        let d: NSDictionary = ["version": 1, "still": still, "netW3": l.netW3.map(Double.init), "netB3": l.netB3.map(Double.init),
                               "minutes": minutes, "adoptions": adoptions]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        d.write(to: url, atomically: true)
    }

    // MARK: Samples (sensor thread, 1 kHz)

    /// - Parameters: sample time (s), the predictor's features, the head orientation (presented).
    public func add(t: Double, features: HeadPredictor.Features?, orientation q: simd_quatf) {
        if pendingReset { clearSums(); pendingReset = false }
        guard enabled, let f = features, t.isFinite else { lastT = nil; return }
        if let last = lastT, t - last > 0.1 { ring.removeAll(); ringStart = 0 }   // a gap: start over
        lastT = t
        if blockStart == nil { blockStart = t }
        if let b = blockStart, t - b >= OnlineLearner.blockSeconds { blockStart = t; trainingBlock.toggle() }

        hiddenStride = (hiddenStride + 1) % 4
        let hidden = hiddenStride == 0 ? HeadPredictor.netHidden(f) : nil
        var w = SIMD3<Float>(repeating: 0)
        let bw: [Float] = [2, 2, 4, 8, 16]
        for (k, x) in bw.enumerated() { w += SIMD3(f.values[3 * k], f.values[3 * k + 1], f.values[3 * k + 2]) * x }
        let speed = simd_length(w / 32) * 180 / .pi
        ring.append(Sample(t: t, f: f, q: q, hidden: hidden, targets: Array(repeating: nil, count: OnlineLearner.horizons.count), speed: speed))
        if trainingBlock { addFeatureSums(f) }

        // Samples whose future has now arrived get their targets.
        let maxH = OnlineLearner.horizons.last ?? 80
        let now = ring.count - 1
        for (hi, h) in OnlineLearner.horizons.enumerated() {
            let j = now - h
            guard j >= ringStart else { continue }
            var d = ring[j].q.inverse * q
            if d.real < 0 { d = simd_quatf(vector: -d.vector) }
            let angle = d.angle
            let y = angle > 1e-9 ? d.axis * angle : SIMD3<Float>(repeating: 0)
            ring[j].targets[hi] = y
            if trainingBlock { addTargetSums(sample: j, horizonIndex: hi, y: y) }
        }
        // The oldest sample now has every target: its net and test contributions are complete.
        let done = now - maxH
        if done >= ringStart {
            let s = ring[done]
            if trainingBlock, let hidden = s.hidden { addHiddenSums(hidden, s.targets) }
            if !trainingBlock { addTest(s) }
        }
        // Keep ~130 ms.
        if ring.count - ringStart > maxH + 50 {
            ringStart += 1
            if ringStart > 4096 { ring.removeFirst(ringStart); ringStart = 0 }
        }

        if trainingBlock, let last = ring.dropLast().last { trainingTime += min(max(t - last.t, 0), 0.02) }
        samplesSinceSolve += 1
        if Double(samplesSinceSolve) / 1000 >= OnlineLearner.solveEverySeconds, testY.count > 3000 {
            samplesSinceSolve = 0
            solveAndMaybeAdopt()
        }
    }

    private func clearSums() {
        for i in xx.indices { xx[i] = 0; dxx[i] = 0 }
        for h in xy.indices { for i in xy[h].indices { xy[h][i] = 0; dxy[h][i] = 0 } }
        for i in hh.indices { hh[i] = 0 }
        for i in hy.indices { hy[i] = 0 }
        n = 0; nh = 0; trainingTime = 0
        testX.removeAll(); testH.removeAll(); testY.removeAll(); testS.removeAll(); testT.removeAll()
    }

    private func addFeatureSums(_ f: HeadPredictor.Features) {
        let nf = OnlineLearner.nf
        for i in 0..<nf {
            let a = Double(f.values[i]); if a == 0 { continue }
            for j in i..<nf { xx[i * nf + j] += a * Double(f.values[j]) }
        }
        n += 1
        let j8 = ring.count - 1 - 8
        if j8 >= ringStart {
            let g = ring[j8].f
            for i in 0..<nf {
                let a = Double(f.values[i] - g.values[i]); if a == 0 { continue }
                for j in i..<nf { dxx[i * nf + j] += a * Double(f.values[j] - g.values[j]) }
            }
        }
    }

    private func addTargetSums(sample j: Int, horizonIndex hi: Int, y: SIMD3<Float>) {
        let nf = OnlineLearner.nf
        let f = ring[j].f
        for i in 0..<nf {
            let a = Double(f.values[i]); if a == 0 { continue }
            xy[hi][i * 3] += a * Double(y.x); xy[hi][i * 3 + 1] += a * Double(y.y); xy[hi][i * 3 + 2] += a * Double(y.z)
        }
        let j8 = j - 8
        if j8 >= ringStart, let y8 = ring[j8].targets[hi] {
            let g = ring[j8].f, dy = y - y8
            for i in 0..<nf {
                let a = Double(f.values[i] - g.values[i]); if a == 0 { continue }
                dxy[hi][i * 3] += a * Double(dy.x); dxy[hi][i * 3 + 1] += a * Double(dy.y); dxy[hi][i * 3 + 2] += a * Double(dy.z)
            }
        }
    }

    private func addHiddenSums(_ h: [Float], _ targets: [SIMD3<Float>?]) {
        guard h.count == nHidden, targets.allSatisfy({ $0 != nil }), nOut == 3 * targets.count else { return }
        let m = nHidden + 1
        var v = h.map(Double.init); v.append(1)
        for i in 0..<m { let a = v[i]; for j in i..<m { hh[i * m + j] += a * v[j] } }
        let deg = 180.0 / Double.pi
        for i in 0..<m {
            let a = v[i]
            for (k, y) in targets.enumerated() {
                let y = y!
                hy[i * nOut + 3 * k] += a * Double(y.x) * deg
                hy[i * nOut + 3 * k + 1] += a * Double(y.y) * deg
                hy[i * nOut + 3 * k + 2] += a * Double(y.z) * deg
            }
        }
        nh += 1
    }

    private func addTest(_ s: Sample) {
        testStride = (testStride + 1) % 8
        guard testStride == 0, let hidden = s.hidden ?? HeadPredictor.netHidden(s.f) else { return }
        // Target at the evaluation horizon (between 30 and 40 ms).
        let hs = OnlineLearner.horizons
        guard let k = hs.firstIndex(where: { $0 >= OnlineLearner.evalHorizonMs }), k > 0,
              let y0 = s.targets[k - 1], let y1 = s.targets[k] else { return }
        let a = Float(OnlineLearner.evalHorizonMs - hs[k - 1]) / Float(hs[k] - hs[k - 1])
        testX.append(s.f); testH.append(hidden); testY.append(y0 * (1 - a) + y1 * a); testS.append(s.speed); testT.append(s.t)
        let keep = 3 * 60 * 125    // last 3 minutes of test data (8 ms steps)
        if testY.count > keep * 5 / 4 {
            let drop = testY.count - keep
            testX.removeFirst(drop); testH.removeFirst(drop); testY.removeFirst(drop); testS.removeFirst(drop); testT.removeFirst(drop)
        }
    }

    /// Tests: solve and gate now, and wait for it.
    public func solveNowForTesting() {
        solveAndMaybeAdopt()
        solveQueue.sync {}
    }

    // MARK: Solve and gate (background)

    private func solveAndMaybeAdopt() {
        let snapshot = (xx: xx, xy: xy, dxx: dxx, dxy: dxy, hh: hh, hy: hy, n: n, nh: nh, minutes: trainingTime / 60,
                        testX: testX, testH: testH, testY: testY, testS: testS, testT: testT)
        solveQueue.async { [self] in
            let current = HeadPredictor.learned
            guard let candidate = solve(snapshot.xx, snapshot.xy, snapshot.dxx, snapshot.dxy, snapshot.hh, snapshot.hy,
                                        n: snapshot.n, nh: snapshot.nh, prior: HeadPredictor.shipped, current: current),
                  candidate.isUsable else { return }
            let cur = OnlineLearner.jitter(current, snapshot.testX, snapshot.testH, snapshot.testY, snapshot.testS, snapshot.testT)
            let cand = OnlineLearner.jitter(candidate, snapshot.testX, snapshot.testH, snapshot.testY, snapshot.testS, snapshot.testT)
            var st = lock.withLock { $0.status }
            st.minutesLearned = max(st.minutesLearned, snapshot.minutes)
            st.lastScore = (cur.moving, cand.moving)
            // Adopt only if clearly better while moving and not worse while still.
            let better = cand.moving < cur.moving * 0.98 && cand.still <= cur.still * 1.01
            if !better {
                log?(String(format: "Tracking check: candidate jitter while moving %.3f vs %.3f px, still %.3f vs %.3f px: kept the current fit (%.1f min learned)",
                            cand.moving * 1920 / 46, cur.moving * 1920 / 46, cand.still * 1920 / 46, cur.still * 1920 / 46, st.minutesLearned))
            }
            if better {
                HeadPredictor.learned = candidate
                st.adoptions += 1
                save(candidate, minutes: st.minutesLearned, adoptions: st.adoptions)
                onImproved?(1 - cand.moving / max(cur.moving, 1e-9))
                log?(String(format: "Tracking improved from your head motion: jitter while moving %.3f → %.3f px, still %.3f → %.3f px (%.0f min learned)",
                            cur.moving * 1920 / 46, cand.moving * 1920 / 46, cur.still * 1920 / 46, cand.still * 1920 / 46, st.minutesLearned))
            }
            let final = st
            lock.withLock { $0.status = final }
        }
    }

    private func solve(_ xx: [Double], _ xy: [[Double]], _ dxx: [Double], _ dxy: [[Double]], _ hh: [Double], _ hy: [Double],
                       n: Double, nh: Double, prior: HeadPredictor.Learned, current: HeadPredictor.Learned) -> HeadPredictor.Learned? {
        let nf = OnlineLearner.nf
        guard n > 30_000 else { return nil }
        // Still-head fit: (XᵀX + μ dXᵀdX + κD) W = XᵀY + μ dXᵀdY + κD W_prior, one system for all horizons.
        var m = [Double](repeating: 0, count: nf * nf)
        for i in 0..<nf { for j in i..<nf {
            let v = xx[i * nf + j] + OnlineLearner.stillMU * dxx[i * nf + j]
            m[i * nf + j] = v; m[j * nf + i] = v
        } }
        let kappa = OnlineLearner.priorSamples / max(n, 1) * 1.0
        var still = prior.still
        for (hi, _) in OnlineLearner.horizons.enumerated() {
            var a = m
            var b = [Double](repeating: 0, count: nf * 3)
            for i in 0..<nf {
                let d = max(a[i * nf + i], 1e-12) * kappa
                a[i * nf + i] += d
                let w = prior.still[hi][i]
                for c in 0..<3 { b[i * 3 + c] = xy[hi][i * 3 + c] + OnlineLearner.stillMU * dxy[hi][i * 3 + c] + d * Double(w[c]) }
            }
            guard let x = OnlineLearner.solveSymmetric(a, b, n: nf, rhs: 3) else { return nil }
            still[hi] = (0..<nf).map { i in SIMD3(Float(x[i * 3]), Float(x[i * 3 + 1]), Float(x[i * 3 + 2])) }
        }
        // Net output layer: (HᵀH + κD) W3 = HᵀY + κD W3_prior (bias as the last row).
        var netW3 = prior.netW3, netB3 = prior.netB3
        let mh = nHidden + 1
        if nh > 5_000, nOut > 0, hh.count == mh * mh {
            var a = [Double](repeating: 0, count: mh * mh)
            for i in 0..<mh { for j in i..<mh { a[i * mh + j] = hh[i * mh + j]; a[j * mh + i] = hh[i * mh + j] } }
            let kh = OnlineLearner.priorSamples / 4 / max(nh, 1)
            var b = hy
            for i in 0..<mh {
                let d = max(a[i * mh + i], 1e-12) * kh
                a[i * mh + i] += d
                for j in 0..<nOut {
                    let w = i < nHidden ? prior.netW3[i * nOut + j] : prior.netB3[j]
                    b[i * nOut + j] += d * Double(w)
                }
            }
            if let x = OnlineLearner.solveSymmetric(a, b, n: mh, rhs: nOut) {
                netW3 = (0..<(nHidden * nOut)).map { Float(x[$0]) }
                netB3 = (0..<nOut).map { Float(x[nHidden * nOut + $0]) }
            }
        }
        return HeadPredictor.Learned(still: still, netW3: netW3, netB3: netB3)
    }

    /// Cholesky solve of a symmetric positive-definite n×n system with `rhs` right-hand sides.
    static func solveSymmetric(_ a: [Double], _ b: [Double], n: Int, rhs: Int) -> [Double]? {
        var l = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in 0...i {
                var s = a[i * n + j]
                for k in 0..<j { s -= l[i * n + k] * l[j * n + k] }
                if i == j {
                    guard s > 1e-18 else { return nil }
                    l[i * n + i] = s.squareRoot()
                } else {
                    l[i * n + j] = s / l[j * n + j]
                }
            }
        }
        var x = b
        for c in 0..<rhs {
            for i in 0..<n {   // forward
                var s = x[i * rhs + c]
                for k in 0..<i { s -= l[i * n + k] * x[k * rhs + c] }
                x[i * rhs + c] = s / l[i * n + i]
            }
            for i in stride(from: n - 1, through: 0, by: -1) {   // back
                var s = x[i * rhs + c]
                for k in (i + 1)..<n { s -= l[k * n + i] * x[k * rhs + c] }
                x[i * rhs + c] = s / l[i * n + i]
            }
        }
        return x.allSatisfy(\.isFinite) ? x : nil
    }

    /// Eye-visible jitter (degrees rms) of a fit on test data: prediction error at the evaluation
    /// horizon, averaged over ~10 ms, minus its 100 ms average; split still (<5°/s) / moving.
    static func jitter(_ p: HeadPredictor.Learned, _ xs: [HeadPredictor.Features], _ hs: [[Float]], _ ys: [SIMD3<Float>],
                       _ speeds: [Float], _ ts: [Double]) -> (still: Float, moving: Float) {
        let count = ys.count
        guard count > 200 else { return (.infinity, .infinity) }
        let seconds = Double(evalHorizonMs) / 1000
        let (lo, hi) = HeadPredictor.hybridDegreesPerSecond
        var e = [SIMD2<Float>](repeating: .zero, count: count)
        for i in 0..<count {
            let still = HeadPredictor.rotation(xs[i], seconds: seconds, stillWeights: p.still)
            var r = still
            let x = min(max((speeds[i] - lo) / max(hi - lo, 1e-3), 0), 1), t = x * x * (3 - 2 * x)
            if t > 0, let net = HeadPredictor.netRotation(hidden: hs[i], seconds: seconds, w3: p.netW3, b3: p.netB3) {
                r = still * (1 - t) + net * t
            }
            let d = (ys[i] - r) * (180 / .pi)
            e[i] = SIMD2(d.x, d.y)
        }
        // Moving averages within contiguous stretches (8 ms steps): eye ~10 ms (2), drift 100 ms (13).
        func avg(_ v: [SIMD2<Float>], _ w: Int) -> [SIMD2<Float>] {
            var out = v
            for i in 0..<v.count {
                var s = SIMD2<Float>(repeating: 0), c: Float = 0
                for j in max(0, i - w / 2)...min(v.count - 1, i + w / 2) where abs(ts[j] - ts[i]) < 0.2 { s += v[j]; c += 1 }
                out[i] = s / max(c, 1)
            }
            return out
        }
        let seen = avg(e, 2), drift = avg(seen, 13)
        var sStill: Float = 0, nStill: Float = 0, sMove: Float = 0, nMove: Float = 0
        for i in 0..<count {
            let j = simd_length_squared(seen[i] - drift[i])
            if speeds[i] < 5 { sStill += j; nStill += 1 } else { sMove += j; nMove += 1 }
        }
        return ((sStill / max(nStill, 1)).squareRoot(), (sMove / max(nMove, 1)).squareRoot())
    }
}
