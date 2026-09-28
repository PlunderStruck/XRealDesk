import Foundation
import simd
import os

/// Predicts where the head will be a few tens of milliseconds ahead from its recent motion, with
/// weights fitted to recorded head motion (typing, talking, turning: HeadPredictorWeights.swift).
///
/// The constant-speed guess only knows how fast the head turns right now. This also knows how that
/// speed has been changing over the last ~0.1 s, and what the accelerometer felt: a head movement
/// starts with a push (neck muscles, the jaw while talking) that the accelerometer feels before the
/// rotation builds up. On recordings it wasn't fitted to: ~15% less error while working or talking,
/// ~60% less while turning.
///
/// Fed every 1 kHz sample. Features: the mean rotation rate over windows 0–2, 2–4, 4–8 … 64–128 ms
/// back (head frame, rad/s), then the accelerometer's mean over 0–2 … 32–64 ms back minus its
/// 300 ms mean (head frame, g): 39 numbers.
public struct HeadPredictor: Sendable {
    public static let featureCount = 39
    static let gyroEdges = [2, 4, 8, 16, 32, 64, 128]
    static let accelEdges = [2, 4, 8, 16, 32, 64]
    static let slowWindow = 300
    static let ringSize = 512

    public struct Features: Sendable {
        public var values = SIMD64<Float>(repeating: 0)
    }

    private var gyroRing = [SIMD3<Float>](repeating: .zero, count: ringSize)
    private var accelRing = [SIMD3<Float>](repeating: .zero, count: ringSize)
    private var head = 0          // next write index
    private var count = 0
    /// Running sums of the last k samples for each window edge (Double: no drift).
    private var gyroSums = [SIMD3<Double>](repeating: .zero, count: gyroEdges.count)
    private var accelSums = [SIMD3<Double>](repeating: .zero, count: accelEdges.count)
    private var accelSlowSum = SIMD3<Double>(repeating: 0)

    public init() {}

    public mutating func reset() { self = HeadPredictor() }

    public mutating func add(gyro: SIMD3<Float>, accel: SIMD3<Float>) {
        guard gyro.x.isFinite, gyro.y.isFinite, gyro.z.isFinite,
              accel.x.isFinite, accel.y.isFinite, accel.z.isFinite else { reset(); return }
        let n = HeadPredictor.ringSize
        func old(_ ring: [SIMD3<Float>], _ k: Int) -> SIMD3<Double> {   // sample k back from the newest-to-be
            SIMD3<Double>(ring[(head - k + n) % n])
        }
        for (j, k) in HeadPredictor.gyroEdges.enumerated() {
            gyroSums[j] += SIMD3<Double>(gyro)
            if count >= k { gyroSums[j] -= old(gyroRing, k) }
        }
        for (j, k) in HeadPredictor.accelEdges.enumerated() {
            accelSums[j] += SIMD3<Double>(accel)
            if count >= k { accelSums[j] -= old(accelRing, k) }
        }
        accelSlowSum += SIMD3<Double>(accel)
        if count >= HeadPredictor.slowWindow { accelSlowSum -= old(accelRing, HeadPredictor.slowWindow) }
        gyroRing[head] = gyro; accelRing[head] = accel
        head = (head + 1) % n
        count = min(count + 1, n)
    }

    /// nil until there's enough history.
    public var features: Features? {
        guard count > HeadPredictor.slowWindow else { return nil }
        var f = Features()
        var i = 0
        var prev = SIMD3<Double>(repeating: 0), prevK = 0
        for (j, k) in HeadPredictor.gyroEdges.enumerated() {
            let m = (gyroSums[j] - prev) / Double(k - prevK)
            f.values[i] = Float(m.x); f.values[i + 1] = Float(m.y); f.values[i + 2] = Float(m.z); i += 3
            prev = gyroSums[j]; prevK = k
        }
        let slow = accelSlowSum / Double(HeadPredictor.slowWindow)
        prev = .zero; prevK = 0
        for (j, k) in HeadPredictor.accelEdges.enumerated() {
            let m = (accelSums[j] - prev) / Double(k - prevK) - slow
            f.values[i] = Float(m.x); f.values[i + 1] = Float(m.y); f.values[i + 2] = Float(m.z); i += 3
            prev = accelSums[j]; prevK = k
        }
        return f
    }

    public enum Model: Int, Sendable {
        /// Two fits blended by head speed: a very smooth one while (nearly) still, a sharp one
        /// while moving. Fitted with the wearer's own tracking calibration.
        case blended = 1
        /// The first single fit, kept for comparing.
        case previous = 2
        /// The still-head linear fit while (nearly) still, a small neural net while moving: on
        /// held-out calibration sessions the net cut eye-visible jitter while panning by ~15%.
        case hybrid = 3
    }

    /// A small neural net: standardise the 39 features, two tanh layers, a linear output with the
    /// rotation (degrees) at every horizon. Weights row-major [in][out].
    public struct Net: Sendable, Codable {
        public var sizes: [Int]
        public var mean: [Float], scale: [Float]
        public var w1: [Float], b1: [Float], w2: [Float], b2: [Float], w3: [Float], b3: [Float]
        public init(sizes: [Int], mean: [Float], scale: [Float], w1: [Float], b1: [Float], w2: [Float], b2: [Float], w3: [Float], b3: [Float]) {
            self.sizes = sizes; self.mean = mean; self.scale = scale
            self.w1 = w1; self.b1 = b1; self.w2 = w2; self.b2 = b2; self.w3 = w3; self.b3 = b3
        }
        public var isUsable: Bool {
            sizes.count == 4 && sizes[0] == featureCount && sizes[3] == 3 * horizonsMs.count
                && mean.count == sizes[0] && scale.count == sizes[0]
                && w1.count == sizes[0] * sizes[1] && b1.count == sizes[1]
                && w2.count == sizes[1] * sizes[2] && b2.count == sizes[2]
                && w3.count == sizes[2] * sizes[3] && b3.count == sizes[3]
                && [mean, scale, w1, b1, w2, b2, w3, b3].allSatisfy { $0.allSatisfy(\.isFinite) }
        }
    }

    /// Everything the hybrid predictor uses: the still-head linear fit and the net. Starts as the
    /// shipped model; a personal model (trained from the wearer's own session) can replace it.
    public struct Personal: Sendable {
        public var still: [[SIMD3<Float>]]
        public var net: Net
        public init(still: [[SIMD3<Float>]], net: Net) { self.still = still; self.net = net }
        public var isUsable: Bool {
            still.count == horizonsMs.count && still.allSatisfy { $0.count == featureCount }
                && still.allSatisfy { $0.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite } } && net.isUsable
        }
    }
    public static let shippedNet = Net(sizes: netSizes, mean: netMean, scale: netScale, w1: netW1, b1: netB1,
                                       w2: netW2, b2: netB2, w3: netW3, b3: netB3)
    public static let shipped = Personal(still: weightsStill, net: shippedNet)
    private static let modelLock = OSAllocatedUnfairLock(initialState: shipped)
    /// What the hybrid predictor uses right now (thread-safe). Unusable models are refused.
    public static var current: Personal {
        get { modelLock.withLock { $0 } }
        set { if newValue.isUsable { modelLock.withLock { $0 = newValue } } }
    }

    /// Head speed (°/s) over which the neural net takes over from the still-head fit (hybrid).
    /// Held-out sessions: 2–8°/s beat 5–20°/s (slow movement 0.73 vs 0.77 px jitter).
    static let hybridDegreesPerSecond: (start: Float, full: Float) = (2, 8)

    /// Head speed (°/s) over the last ~32 ms, from the features.
    static func speed(_ f: Features) -> Float {
        var w = SIMD3<Float>(repeating: 0)
        let weights: [Float] = [2, 2, 4, 8, 16]   // 0-2, 2-4, 4-8, 8-16, 16-32 ms bins
        for (k, x) in weights.enumerated() { w += SIMD3(f.values[3 * k], f.values[3 * k + 1], f.values[3 * k + 2]) * x }
        return simd_length(w / 32) * 180 / .pi
    }

    /// Head-frame rotation vector (radians) expected over the next `seconds`.
    public static func rotation(_ f: Features, seconds: Double, model: Model = .blended) -> SIMD3<Float> {
        switch model {
        case .previous:
            return rotation(f, seconds: seconds, weights: weightsPrevious)
        case .hybrid:
            return hybridRotation(f, seconds: seconds, model: current)
        case .blended:
            let (lo, hi) = blendDegreesPerSecond
            let x = min(max((speed(f) - lo) / max(hi - lo, 1e-3), 0), 1)
            let t = x * x * (3 - 2 * x)
            if t <= 0 { return rotation(f, seconds: seconds, weights: weightsStill) }
            if t >= 1 { return rotation(f, seconds: seconds, weights: weightsMoving) }
            return rotation(f, seconds: seconds, weights: weightsStill) * (1 - t)
                 + rotation(f, seconds: seconds, weights: weightsMoving) * t
        }
    }

    /// The hybrid prediction with a given model (the shipped one or a personal one).
    public static func hybridRotation(_ f: Features, seconds: Double, model p: Personal) -> SIMD3<Float> {
        let (lo, hi) = hybridDegreesPerSecond
        let x = min(max((speed(f) - lo) / max(hi - lo, 1e-3), 0), 1)
        let t = x * x * (3 - 2 * x)
        let still = rotation(f, seconds: seconds, weights: p.still)
        guard t > 0, let h = netHidden(f, net: p.net),
              let net = netRotation(hidden: h, seconds: seconds, w3: p.net.w3, b3: p.net.b3) else { return still }
        return still * (1 - t) + net * t
    }

    /// The neural net's last hidden layer for these features (what its output layer reads).
    public static func netHidden(_ f: Features, net: Net) -> [Float]? {
        let sizes = net.sizes
        guard net.isUsable else { return nil }
        var x = [Float](repeating: 0, count: sizes[0])
        for i in 0..<sizes[0] { x[i] = (f.values[i] - net.mean[i]) / max(net.scale[i], 1e-12) }
        func layer(_ input: [Float], _ w: [Float], _ b: [Float], _ n: Int, tanh apply: Bool) -> [Float] {
            var out = b
            for i in 0..<input.count {
                let v = input[i]
                if v == 0 { continue }
                let row = i * n
                for j in 0..<n { out[j] += v * w[row + j] }
            }
            if apply { for j in 0..<n { out[j] = tanhf(out[j]) } }
            return out
        }
        let h1 = layer(x, net.w1, net.b1, sizes[1], tanh: true)
        return layer(h1, net.w2, net.b2, sizes[2], tanh: true)
    }

    /// All net outputs (degrees; 3 per horizon) from the last hidden layer and an output layer.
    public static func netOutputs(hidden h: [Float], w3: [Float], b3: [Float]) -> [Float] {
        let n = b3.count
        var out = b3
        guard w3.count == h.count * n else { return out }
        for i in 0..<h.count {
            let v = h[i], row = i * n
            for j in 0..<n { out[j] += v * w3[row + j] }
        }
        return out
    }

    /// The neural net's rotation (radians, head frame) over `seconds`, or nil if it isn't usable.
    static func netRotation(hidden: [Float], seconds: Double, w3: [Float], b3: [Float]) -> SIMD3<Float>? {
        let hs = horizonsMs
        guard b3.count == 3 * hs.count, w3.count == hidden.count * b3.count, let first = hs.first, let last = hs.last else { return nil }
        let ms = Float(seconds * 1000)
        guard ms > 0 else { return .zero }
        let o = netOutputs(hidden: hidden, w3: w3, b3: b3)
        func at(_ k: Int) -> SIMD3<Float> { SIMD3(o[3 * k], o[3 * k + 1], o[3 * k + 2]) * (.pi / 180) }
        let r: SIMD3<Float>
        if ms <= first { r = at(0) * (ms / first) }
        else if ms >= last { r = at(hs.count - 1) * (ms / last) }
        else {
            var k = 0
            while k + 1 < hs.count && hs[k + 1] < ms { k += 1 }
            let t = (ms - hs[k]) / (hs[k + 1] - hs[k])
            r = at(k) * (1 - t) + at(k + 1) * t
        }
        return r.x.isFinite && r.y.isFinite && r.z.isFinite ? r : nil
    }

    /// The linear fit's rotation over `seconds` with the given per-horizon weights.
    static func rotation(_ f: Features, seconds: Double, stillWeights: [[SIMD3<Float>]]) -> SIMD3<Float> {
        rotation(f, seconds: seconds, weights: stillWeights)
    }

    private static func rotation(_ f: Features, seconds: Double, weights: [[SIMD3<Float>]]) -> SIMD3<Float> {
        let ms = Float(seconds * 1000)
        let hs = horizonsMs
        guard ms > 0, let first = hs.first, let last = hs.last, weights.count == hs.count else { return .zero }
        func at(_ k: Int) -> SIMD3<Float> {
            var r = SIMD3<Float>(repeating: 0)
            let w = weights[k]
            for i in 0..<min(w.count, featureCount) { r += w[i] * f.values[i] }
            return r
        }
        if ms <= first { return at(0) * (ms / first) }
        if ms >= last { return at(hs.count - 1) * (ms / last) }
        var k = 0
        while k + 1 < hs.count && hs[k + 1] < ms { k += 1 }
        let t = (ms - hs[k]) / (hs[k + 1] - hs[k])
        return at(k) * (1 - t) + at(k + 1) * t
    }
}
