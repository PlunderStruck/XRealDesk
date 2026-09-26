import Foundation
import simd

/// 3-DoF head orientation from gyro + accelerometer.
///
/// Mahony-style complementary filter:
///  - the gyro is integrated at the full 1 kHz rate (smooth, low latency),
///  - gravity from the accelerometer slowly corrects pitch/roll drift,
///  - gyro bias is re-estimated whenever the head has been steady for a while, which is what keeps
///    yaw from creeping (there's no usable magnetometer reference, so yaw can only be protected).
///
/// Every gyro sample is integrated: nothing is ever zeroed or thrown away, so slow deliberate
/// movements and tiny reading-style adjustments are tracked exactly. Bias learning is gated so real
/// motion can never be mistaken for sensor error: it needs ~1 s of steadiness, and it only accepts
/// small corrections (true bias is small and changes slowly; head motion is larger or bursty).
///
/// `orientation` rotates head-frame vectors into the world frame (world +Y is up).
public struct OrientationFilter: Sendable {
    public struct Settings: Sendable {
        /// Correction gain toward gravity after warm-up (rad/s per unit error).
        public var gravityGain: Float = 0.25
        /// Integral gain: learns tilt-axis gyro error from gravity continuously, even while moving,
        /// so the horizon converges to exactly level instead of settling crooked.
        public var gravityIntegralGain: Float = 0.02
        /// Cap on the integral correction (rad/s).
        public var gravityIntegralLimit: Float = 0.02
        /// Large gain used for the first `warmupSeconds` so the horizon locks in quickly.
        public var warmupGain: Float = 5
        public var warmupSeconds: Float = 1.0
        /// Accelerometer magnitude must be within this of 1 g to be trusted as gravity.
        public var accelTrustBand: Float = 0.12
        /// Largest bias correction ever accepted: a steady rate further than this from the current
        /// bias estimate is treated as real (slow) motion, not sensor error.
        public var biasGate: Float = 0.007               // rad/s (0.4 °/s)
        /// Motion detector: short-window mean rate must stay within this of the bias.
        public var motionThreshold: Float = 0.014        // rad/s (0.8 °/s)
        /// Gyro jitter (std-dev per axis) above which the head isn't considered steady.
        public var steadyJitter: Float = 0.021           // rad/s (1.2 °/s)
        /// Max deviation of |accel| from its own recent average (handles per-unit scale error).
        public var stillAccelBand: Float = 0.02          // g
        /// Steadiness required before learning (lets the slow mean settle after a movement).
        public var stillSecondsBeforeLearning: Float = 1.0
        public var biasTimeConstant: Float = 3.0         // seconds
        /// Recovery path for a larger bias error (e.g. big temperature change): a perfectly steady,
        /// constant offset held this long is sensor error, not a human head movement.
        public var longSteadySeconds: Float = 15
        public var wideBiasGate: Float = 0.021           // rad/s (1.2 °/s)
        public init() {}
    }

    public var settings = Settings()
    public private(set) var orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    /// Latest bias-corrected angular velocity in the head frame (rad/s).
    public private(set) var angularVelocity = SIMD3<Float>(repeating: 0)
    /// Learned residual gyro bias on top of the factory one (rad/s).
    public private(set) var learnedBias = SIMD3<Float>(repeating: 0)
    public private(set) var initialized = false
    public private(set) var elapsed: Float = 0
    public private(set) var isStill = false

    private var stillTime: Float = 0
    /// Tilt-axis gyro error learned from gravity (rad/s, head frame).
    public private(set) var tiltBias = SIMD3<Float>(repeating: 0)
    /// Recent average angle between measured and estimated "up" (radians): how level we are.
    public private(set) var tiltError: Float = 0
    private var longSteadyTime: Float = 0
    private var fastGyro = SIMD3<Float>(repeating: 0)     // ~0.1 s mean: detects motion quickly
    private var slowGyro = SIMD3<Float>(repeating: 0)     // ~0.5 s mean: what bias learns toward
    private var gyroVar = SIMD3<Float>(repeating: 0)      // ~0.5 s variance around the slow mean
    private var slowGyroValid = false
    private var slowAccelNorm: Float = 1

    public init(settings: Settings = Settings()) { self.settings = settings }

    public mutating func reset() {
        orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        angularVelocity = .zero
        initialized = false
        elapsed = 0
        stillTime = 0
        longSteadyTime = 0
        tiltBias = .zero
        tiltError = 0
        slowGyroValid = false
        isStill = false
    }

    /// Seed bias from a previous session (persisted per headset) so yaw is stable immediately.
    public mutating func seedBias(_ b: SIMD3<Float>) {
        if b.x.isFinite && b.y.isFinite && b.z.isFinite && simd_length(b) < 0.05 { learnedBias = b }
    }

    /// - Parameters:
    ///   - gyro: head-frame angular velocity, rad/s (factory bias already removed)
    ///   - accel: head-frame specific force, g (reads +1 on the up axis when level and still)
    ///   - dt: seconds since previous sample
    public mutating func update(gyro rawGyro: SIMD3<Float>, accel: SIMD3<Float>, dt rawDt: Float) {
        guard rawGyro.x.isFinite, rawGyro.y.isFinite, rawGyro.z.isFinite,
              accel.x.isFinite, accel.y.isFinite, accel.z.isFinite else { return }
        // The sensor tops out at ±2000 °/s and ±16 g: anything beyond is a corrupted packet, not motion.
        guard simd_length(rawGyro) < 60, simd_length(accel) < 32 else { return }
        let aNorm = simd_length(accel)

        if !initialized {
            guard aNorm > 0.5 && aNorm < 1.5 else { return }
            // Level the horizon from gravity; heading is arbitrary until the app recenters.
            orientation = simd_quatf(from: accel / aNorm, to: SIMD3(0, 1, 0))
            initialized = true
            return
        }

        // Clamp dt: a USB hiccup must not turn into a giant integration step.
        let dt = min(max(rawDt, 0), 0.02)
        guard dt > 0 else { return }
        elapsed += dt

        // --- Online gyro-bias learning, only while genuinely steady.
        let aFast = min(1, dt / 0.1), aSlow = min(1, dt / 0.5)
        if !slowGyroValid {
            fastGyro = learnedBias; slowGyro = learnedBias; gyroVar = .zero
            slowGyroValid = true
        }
        fastGyro += (rawGyro - fastGyro) * aFast
        slowGyro += (rawGyro - slowGyro) * aSlow
        let dev = rawGyro - slowGyro
        gyroVar += (dev * dev - gyroVar) * aSlow
        slowAccelNorm += (aNorm - slowAccelNorm) * aSlow
        let jitter = sqrt(max(gyroVar.x, max(gyroVar.y, gyroVar.z)))
        let steady = simd_length(fastGyro - learnedBias) < settings.motionThreshold
            && simd_length(slowGyro - learnedBias) < settings.biasGate
            && jitter < settings.steadyJitter
            && abs(aNorm - slowAccelNorm) < settings.stillAccelBand
            && abs(aNorm - 1) < 0.15
        stillTime = steady ? stillTime + dt : 0
        isStill = stillTime > settings.stillSecondsBeforeLearning
        let constantRate = simd_length(fastGyro - slowGyro) < settings.motionThreshold
            && simd_length(slowGyro - learnedBias) < settings.wideBiasGate
            && jitter < settings.steadyJitter
            && abs(aNorm - slowAccelNorm) < settings.stillAccelBand
        longSteadyTime = constantRate ? longSteadyTime + dt : 0
        if isStill || longSteadyTime > settings.longSteadySeconds {
            learnedBias += (slowGyro - learnedBias) * min(1, dt / settings.biasTimeConstant)
        }

        // Always integrate the full (bias-corrected) rate: no dead zones, no lost motion.
        var omega = rawGyro - learnedBias - tiltBias
        angularVelocity = omega

        // --- Gravity correction (pitch / roll only), proportional + integral.
        if abs(aNorm - 1) < settings.accelTrustBand {
            let measuredUp = accel / aNorm
            let estimatedUp = orientation.inverse.act(SIMD3(0, 1, 0))
            let error = simd_cross(measuredUp, estimatedUp)
            tiltError += (asin(min(1, simd_length(error))) - tiltError) * min(1, dt / 2)
            // Trust gravity less while the head is accelerating (|a| away from 1 g).
            let trust = max(0, 1 - abs(aNorm - 1) / settings.accelTrustBand)
            let warm = elapsed < settings.warmupSeconds
            let gain = (warm ? settings.warmupGain : settings.gravityGain) * trust
            omega += error * gain
            if !warm {
                // error = measured × estimated; a positive rate error along e shows up as +e,
                // so learn it as bias (subtracted above).
                tiltBias -= error * settings.gravityIntegralGain * trust * dt
                let len = simd_length(tiltBias)
                if len > settings.gravityIntegralLimit { tiltBias *= settings.gravityIntegralLimit / len }
            }
        }

        // --- Integrate body-frame rate: q ← q ⊗ exp(ω dt / 2)
        let angle = simd_length(omega) * dt
        if angle > 1e-9 {
            orientation = (orientation * simd_quatf(angle: angle, axis: omega / simd_length(omega))).normalized
        }
    }

    /// Orientation extrapolated `seconds` into the future using the current angular velocity.
    public func predicted(by seconds: Float) -> simd_quatf {
        let angle = simd_length(angularVelocity) * seconds
        guard angle > 1e-7, seconds > 0 else { return orientation }
        return (orientation * simd_quatf(angle: angle, axis: simd_normalize(angularVelocity))).normalized
    }
}
