import Foundation
import simd

/// Keeps the screens rock-still through tiny head motion (typing bumps, breathing, pulse) without
/// adding lag to real movement.
///
/// The rendered view is tied to the true head orientation by a soft leash:
///  - while the head wobbles well inside `leash`, the view doesn't move (only a very slow re-centre,
///    so it never settles at an offset),
///  - toward and past the leash length a spring eases in and pulls the view along: always smooth,
///    never a stop-start jerk at the edge (a hard leash made wobble just past it look worse),
///  - during real head turns the view blends to the exact head orientation, so turning is exactly
///    as responsive as without stabilisation.
public struct ViewStabilizer: Sendable {
    /// Leash length when the head is (nearly) still, radians. 0 disables stabilisation.
    public var leash: Float = SpatialMath.radians(0.12)   // app default is 0.03° (tuned on real data)
    /// Head speed range over which the leash shrinks to zero (rad/s).
    public var releaseStart: Float = SpatialMath.radians(4)
    public var releaseFull: Float = SpatialMath.radians(12)
    /// Time constant of the slow re-centre while inside the leash (seconds).
    public var settleTime: Float = 0.8
    /// Spring rate once fully past the leash (1/s): how firmly the view is pulled along.
    public var springRate: Float = 25
    /// Spring engagement ramps from `engageStart`×leash to (`engageStart`+`engageWidth`)×leash.
    public var engageStart: Float = 0.5
    public var engageWidth: Float = 2.5

    private var view: simd_quatf?
    private var speed: Float = 0

    public init() {}

    public mutating func reset() { view = nil; speed = 0 }

    /// - Parameters:
    ///   - head: true (predicted) head orientation for this frame
    ///   - angularSpeed: current head angular speed (rad/s), from the gyro
    ///   - dt: seconds since last frame
    /// - Returns: the orientation to render with.
    public mutating func update(head: simd_quatf, angularSpeed: Float, dt: Float) -> simd_quatf {
        guard leash > 0, dt > 0, var v = view else {
            view = head
            return head
        }
        // Lightly smoothed speed (~30 ms) so a single typing jolt doesn't release the leash.
        speed += (angularSpeed - speed) * min(1, dt / 0.03)
        let t = min(max((speed - releaseStart) / (releaseFull - releaseStart), 0), 1)
        let release = t * t * (3 - 2 * t)

        // Shortest rotation from the view to the head.
        var q = head * v.inverse
        if q.real < 0 { q = simd_quatf(ix: -q.imag.x, iy: -q.imag.y, iz: -q.imag.z, r: -q.real) }
        let angle = q.angle
        // Spring engagement eases in from half the leash to 1.5× the leash.
        let e = min(max((angle - engageStart * leash) / (engageWidth * leash), 0), 1)
        let engage = e * e * (3 - 2 * e)
        let rate = engage * springRate + (1 - engage) / settleTime
        v = simd_slerp(v, head, 1 - exp(-dt * rate))
        // Real head motion: blend to the exact head orientation (no lag while turning).
        if release > 0 { v = simd_slerp(v, head, release) }
        view = v.normalized
        return view!
    }
}
