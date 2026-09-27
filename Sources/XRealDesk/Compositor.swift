import AppKit
import Metal
import QuartzCore
import os
import simd
import XRCore

/// Renders the glasses view on its own high-priority thread, paced by the glasses' display
/// (CAMetalDisplayLink). The main thread (UI, settings, display reconfiguration, which can block for
/// seconds) never delays a frame. The main thread talks to it only through lock-protected
/// config snapshots and commands.
final class Compositor: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {

    struct Config {
        var layout = ScreenLayout()
        var style = Renderer.Style()
        var mode: TrackingMode = .anchored
        var predictionSeconds: Double = 0.014
        /// Stabiliser leash (radians): tiny head motion within this is ignored. 0 = off.
        var stabilityRadians: Float = 0
        var focusDim: Float = 0.25
        var brightness: Float = 1
        var highlightCursor = true
        var followLag: Float = 0.3
        var flickSensitivity: Float = 0.5
        var smartFlick = false
        /// Picture rotation to match how the glasses sit on your face (+ = clockwise).
        var rollRadians: Float = 0
        /// Side-by-side output but the same flat picture in both eyes (no depth). Default: depth felt
        /// warpy on head turns (60 Hz, rotation-only tracking) while the flat picture felt clean.
        var flat3D = true
        /// Show every frame this many refreshes after the display link's target. macOS showed frames
        /// on time or one refresh late, flipping between the two (measured with presented times):
        /// predicted for the wrong moment half the time, it read as jolts while panning. A fixed
        /// extra refresh is always met, so every frame appears exactly when it was predicted for.
        var presentDelay = 0
        /// Predict for when macOS is actually showing frames (see presentationLateness).
        var followPresentation = true
        /// Experiment (`set handoff=ms`): start each frame at the display link's deadline + this.
        var handoffOffset: Double?
        /// Just-in-time frames: wait until the latest safe moment before reading the head pose.
        var lateStart = true
        /// Scan-out compensation strength: the fraction of a refresh the glasses take to light the
        /// picture top to bottom. Blind A/B while panning: 40% beat 30/50/70/100/130% and off.
        var scanScale: Float = 0.4

        /// Flat pictures (2D, or the same picture in both eyes) also get the neck model, scaled to
        /// where the eyes converge on them (the displays' factory convergence, ~3.6 m).
        var neckModel = true
        var preview = false
        var version = 0
    }

    enum Command {
        /// Put the layout in front of you; `panel` becomes the focused screen.
        case recenter(panel: Int)
        /// Focus a screen (kept in front in follow/locked modes). `moveAnchor` also swings the
        /// anchored layout so that screen sits where you're looking.
        case focus(panel: Int, moveAnchor: Bool)
        /// Glasses (re)connected: recenter once the new orientation has settled.
        case trackingRestarted
        case forgetTextures(Int?)
        case snapshot(URL)
        /// Test only: block the render thread (exercises the stall watchdog).
        case stall(Double)
        /// Record every frame for N seconds to ~/Library/Logs/XRealDesk/frames.csv.
        case trace(Double)
    }

    struct Output {
        var gaze: Int?
        /// Head yaw/pitch relative to the layout (radians).
        var viewYawPitch = SIMD2<Float>(0, 0)
        var tracking = false
        var fps: Double = 0
        /// When the render thread last ran a frame (for the stall watchdog).
        var lastFrameAt: CFTimeInterval = 0
        /// The display link is pacing wrong; the main thread should restart it.
        var needsResync = false
        var sideBySide = false
        /// Screens within reach of the view (field of view plus a margin): captured at full rate.
        var nearView: Set<Int> = []
        /// Where straight ahead meets a screen (index, UV with v top → bottom), for calibration.
        var gazeIndex: Int?
        var gazeUV = SIMD2<Float>(0.5, 0.5)
        /// Where straight ahead appears in the glasses picture (0…1, y top → bottom).
        var aim = SIMD2<Float>(0.5, 0.5)
    }

    private let renderer: Renderer
    private let layer: CAMetalLayer
    private let hid: GlassesHIDService

    private let configLock = OSAllocatedUnfairLock(uncheckedState: Config())
    private let commandLock = OSAllocatedUnfairLock<[Command]>(uncheckedState: [])
    private let capturesLock = OSAllocatedUnfairLock<[Int: DisplayCapture]>(uncheckedState: [:])
    private let cursorLock = OSAllocatedUnfairLock<Int?>(initialState: nil)
    struct CursorState {
        var image: CGImage?
        var hotSpot = CGPoint.zero      // points
        var size = CGSize.zero          // points
        var visible = true
        var seq = 0
    }
    private let cursorStateLock = OSAllocatedUnfairLock(uncheckedState: CursorState())
    private let screensLock = OSAllocatedUnfairLock<[(index: Int, id: CGDirectDisplayID)]>(uncheckedState: [])
    private var uploadedCursorSeq = -1
    private let outputLock = OSAllocatedUnfairLock(uncheckedState: Output())
    /// One per render thread, so a stop immediately followed by a start can never confuse the old
    /// thread with the new one.
    private final class RenderThread: @unchecked Sendable {
        let alive = OSAllocatedUnfairLock(initialState: true)
        /// Signalled when the thread has finished its last frame and exited.
        let exited = DispatchSemaphore(value: 0)
        let runLoopLock = OSAllocatedUnfairLock<CFRunLoop?>(uncheckedState: nil)
        var isAlive: Bool { alive.withLock { $0 } }
    }
    private var current: RenderThread?   // main thread only

    // Render-thread-only state.
    private var anchor = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    /// Frame trace: the latest measured (unpredicted) head orientation and when it was sampled.
    private var traceNow: (q: simd_quatf, t: Double)?
    private var anchorFrom = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var anchorTo = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var anchorAnimStart: CFTimeInterval = 0
    private var needsRecenter = true
    private var lastHead = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var stabilizer = ViewStabilizer()
    private var focus = 0
    private var lockedView = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var panelDim: [Int: Float] = [:]
    private var lastFrameTime: CFTimeInterval = 0
    private var pendingSnapshot: URL?
    private var frameCount = 0
    private var fpsWindowStart: CFTimeInterval = 0
    private var statsSeconds = 0
    private var smart = SmartFollow()
    private var installedMapKey: String?
    private var lastStereo = false
    private var lastCallbackAt: CFTimeInterval = 0
    private var lastCallbackCPUMs = 0.0
    private var hitchReports = 0
    private var lastDrawnView: simd_quatf?
    private var lastFrameView: simd_quatf?
    private var pictureMotion: Float = 0
    private var traceUntil: CFTimeInterval = 0, traceRows: [String] = []
    private let presentedLock = OSAllocatedUnfairLock(initialState: [(CFTimeInterval, CFTimeInterval)]())
    /// How late (s) each recent frame appeared versus macOS's own schedule (last 5 frames).
    private let latenessLock = OSAllocatedUnfairLock(initialState: [Double]())
    private var latenessSum = 0.0

    /// Median lateness of recent frames, snapped to whole refreshes (0 or 1 in practice).
    private func presentationLateness(refresh: Double) -> Double {
        let recent = latenessLock.withLock { $0 }
        guard recent.count >= 3 else { return 0 }
        let m = recent.sorted()[recent.count / 2]
        return (min(max(m / refresh, 0), 2)).rounded() * refresh
    }

    /// Hooked to every presented frame: records how late it appeared.
    private func installPresentationFeedback() {
        let lateness = latenessLock
        let trace = presentedLock
        renderer.onPresented = { [weak self] target, actual in
            guard actual > 0 else { return }   // never shown (replaced by a newer frame)
            lateness.withLock { r in
                r.append(actual - target)
                if r.count > 5 { r.removeFirst(r.count - 5) }   // 5: fastest to follow a switch (simulated on recorded timings)
            }
            if self?.traceUntil ?? 0 > 0 { trace.withLock { $0.append((target, actual)) } }
        }
    }
    // Just-in-time frames (render thread).
    private var jitGPU = [Double](repeating: 0.004, count: 240), jitIndex = 0, jitGPUp98 = 0.004
    private var jitBackoff = 0.0, lastLateWait = 0.0, lateWaitSum = 0.0
    private var lastGPUSeen = 0.0

    /// Precise sleep on the real-time render thread (mach clock, same as CACurrentMediaTime).
    private static func wait(until t: CFTimeInterval) {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        mach_wait_until(UInt64(t * 1e9 * Double(tb.denom) / Double(tb.numer)))
    }
    private var scanRotation = SIMD3<Float>(repeating: 0)
    private var lastDrawnKey: [Double] = []
    private var unchangedFrames = 0
    private var shownSeq: [Int: UInt64] = [:]
    private var unshownCaptures: [Int: Int] = [:]
    private var captureToGlassesSum: [Int: Double] = [:]
    private var captureShown: [Int: Int] = [:]
    private var pacingWindowStart: CFTimeInterval = 0, pacingCallbacks = 0, pacingSlow = 0
    /// Neck pivot → midpoint between the eyes, head frame (m): the usual neck model (eyes ~7.5 cm
    /// above and ~8 cm in front of the pivot the head turns about).
    static let neckToEyes = SIMD3<Float>(0, 0.075, -0.08)
    private var horizonSum = 0.0, horizonN = 0, presentSum = 0.0, deadlineSum = 0.0
    // Frame-timing diagnostics (render thread).
    private var lastTarget: CFTimeInterval = 0
    private var missedVsyncs = 0
    private var maxTargetGapMs = 0.0
    private var maxPoseAgeMs = 0.0
    private var maxHeadStepDeg: Float = 0
    private var lastRenderedHead: simd_quatf?
    private var yp1: SIMD2<Float>?, yp2: SIMD2<Float>?
    private var jitterSum: Double = 0, jitterN = 0, jitterMax: Float = 0
    // "Working" jitter: only frames where the head isn't deliberately turning (< 10°/s), measured
    // on the raw head and on the stabilised view, so the stabiliser's effect shows directly.
    private var rawYP1: SIMD2<Float>?, rawYP2: SIMD2<Float>?, stabYP1: SIMD2<Float>?, stabYP2: SIMD2<Float>?
    private var quietRawSum: Double = 0, quietStabSum: Double = 0, quietN = 0
    private var quietRawMax: Float = 0, quietStabMax: Float = 0
    private var lastMode: TrackingMode?

    init(renderer: Renderer, layer: CAMetalLayer, hid: GlassesHIDService) {
        self.renderer = renderer
        self.layer = layer
        self.hid = hid
    }

    // MARK: Main-thread API

    /// The config and its version change together (one lock): a frame can never draw an old config
    /// under the new version, which the unchanged-frame check would then keep on screen.
    func update(_ config: Config) {
        configLock.withLock { c in
            let version = c.version + 1
            c = config
            c.version = version
        }
    }
    func send(_ command: Command) { commandLock.withLock { $0.append(command) } }
    func setCaptures(_ captures: [Int: DisplayCapture]) { capturesLock.withLock { $0 = captures } }
    func setCursorScreen(_ index: Int?) { cursorLock.withLock { $0 = index } }
    func setScreens(_ screens: [(index: Int, id: CGDirectDisplayID)]) { screensLock.withLock { $0 = screens } }
    func setCursorImage(_ image: CGImage?, hotSpot: CGPoint, size: CGSize) {
        cursorStateLock.withLock { $0.image = image; $0.hotSpot = hotSpot; $0.size = size; $0.seq += 1 }
    }
    func setCursorVisible(_ visible: Bool) { cursorStateLock.withLock { $0.visible = visible } }
    var output: Output { outputLock.withLock { $0 } }
    func clearResyncRequest() { outputLock.withLock { $0.needsResync = false } }
    var isRunning: Bool { current != nil }

    /// Frame rate to lock to (the glasses' refresh rate). A fixed rate, not a range: given a range,
    /// macOS picks lower rates on battery (it ran at 80 fps on a 120 Hz display).
    private var targetFPS: Float = 120

    func start(fps: Int) {
        let f = Float(min(max(fps, 30), 240))
        if current != nil, f == targetFPS { return }
        if current != nil { stop() }
        targetFPS = f
        let ctx = RenderThread()
        current = ctx
        let t = Thread { [weak self] in self?.threadMain(ctx) }
        t.name = "XRealDesk.Render"
        t.qualityOfService = .userInteractive
        t.start()
    }

    func stop() {
        guard let ctx = current else { return }
        current = nil
        ctx.alive.withLock { $0 = false }
        if let rl = ctx.runLoopLock.withLock({ $0 }) { CFRunLoopStop(rl); CFRunLoopWakeUp(rl) }
        // Wait for the frame in progress: after stop() returns, nothing else touches the renderer's
        // caches (callers clear them), and no frame is drawn with a stale display link.
        if ctx.exited.wait(timeout: .now() + 1) == .timedOut { Log.error("Render thread didn't stop within 1 s") }
    }

    // MARK: Cursor glide

    /// When the cursor jumps to another screen (it follows your gaze), the glasses draw it gliding
    /// there along the screens' surface instead of vanishing and reappearing. Moving the mouse across
    /// a screen edge isn't a jump and is never delayed.
    private var cursorLast: (panel: Int, uv: SIMD2<Float>)?
    private var cursorGlide: (from: SIMD2<Float>, start: CFTimeInterval)?
    static let cursorGlideSeconds = 0.13

    /// Point on the layout surface (arc length, height) for a panel's UV.
    private static func surfacePoint(_ p: ScreenLayout.Panel, _ uv: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2(p.arcCenter + (uv.x - 0.5) * p.size.x, p.height + (0.5 - uv.y) * p.size.y)
    }

    private func glideCursor(to panel: Int, uv: SIMD2<Float>, layout: ScreenLayout, now: CFTimeInterval) -> (Int, SIMD2<Float>) {
        defer { cursorLast = (panel, uv) }
        guard let target = layout.panels.first(where: { $0.index == panel }) else { return (panel, uv) }
        let to = Compositor.surfacePoint(target, uv)
        // Where the cursor is drawn right now (mid-glide, or its last spot).
        func current() -> SIMD2<Float>? {
            if let g = cursorGlide, let last = cursorLast, let lp = layout.panels.first(where: { $0.index == last.panel }) {
                let t = Float(min(max((now - g.start) / Compositor.cursorGlideSeconds, 0), 1))
                let e = 1 - (1 - t) * (1 - t) * (1 - t)
                return g.from + (Compositor.surfacePoint(lp, last.uv) - g.from) * e
            }
            guard let last = cursorLast, let lp = layout.panels.first(where: { $0.index == last.panel }) else { return nil }
            return Compositor.surfacePoint(lp, last.uv)
        }
        if let last = cursorLast, last.panel != panel, let from = current(),
           simd_length(to - from) > 0.15 * target.size.x {
            cursorGlide = (from, now)   // a jump between screens: glide from where it was drawn
        }
        guard let g = cursorGlide else { return (panel, uv) }
        let t = Float((now - g.start) / Compositor.cursorGlideSeconds)
        if t >= 1 || !t.isFinite { cursorGlide = nil; return (panel, uv) }
        let e = 1 - (1 - t) * (1 - t) * (1 - t)   // ease out
        let pos = g.from + (to - g.from) * e
        // The panel under that point (or the nearest one, while crossing the gap between screens).
        var best: (Int, SIMD2<Float>, Float)?
        for p in layout.panels {
            let u = (pos.x - p.arcCenter) / p.size.x + 0.5, v = 0.5 - (pos.y - p.height) / p.size.y
            let out = max(max(-u, u - 1), max(-v, v - 1), 0)
            if best == nil || out < best!.2 { best = (p.index, SIMD2(min(max(u, 0), 1), min(max(v, 0), 1)), out) }
        }
        guard let b = best else { return (panel, uv) }
        return (b.0, b.1)
    }

    // MARK: Render thread

    /// Real-time scheduling for the render thread (as audio and games use): the kernel runs it on
    /// time even when every core is busy (a big compile starved it into 74 fps). It needs ~0.3 ms
    /// of CPU per frame; if it ever used far more than it asked for, the kernel would demote it.
    private func makeRealtime() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let abs = { (ns: Double) in UInt32(ns * Double(tb.denom) / Double(tb.numer)) }
        let period = 1e9 / Double(targetFPS)
        var policy = thread_time_constraint_policy_data_t(period: abs(period), computation: abs(1_500_000),
                                                          constraint: abs(min(period * 0.6, 5_000_000)), preemptible: 1)
        let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &policy) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_policy_set(pthread_mach_thread_np(pthread_self()), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
            }
        }
        if r != KERN_SUCCESS { Log.error("Render thread: real-time scheduling unavailable (\(r))") }
    }

    private func threadMain(_ ctx: RenderThread) {
        makeRealtime()
        let rl = CFRunLoopGetCurrent()!
        ctx.runLoopLock.withLock { $0 = rl }
        let link = CAMetalDisplayLink(metalLayer: layer)
        link.delegate = self
        link.preferredFrameRateRange = CAFrameRateRange(minimum: targetFPS, maximum: targetFPS, preferred: targetFPS)
        // macOS shows each frame 3 refreshes after this callback either way (measured: 25 ms at
        // 120 Hz, 50 ms at 60 Hz, for latency 1 or 2), so the head prediction covers that instead.
        link.preferredFrameLatency = 2
        link.add(to: .current, forMode: .default)
        installPresentationFeedback()
        Log.info("Render thread started")
        while ctx.isAlive {
            CFRunLoopRunInMode(.defaultMode, 0.25, false)
        }
        link.invalidate()
        Log.info("Render thread stopped")
        ctx.exited.signal()
    }

    /// Serializes frames: during a stop→start handover the old thread may still be finishing one.
    private let frameMutex = NSLock()

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        frame(presentAt: update.targetPresentationTimestamp, deadline: update.targetTimestamp, drawable: { update.drawable })
    }

    /// One frame. `presentAt`: when it reaches the glasses; `deadline`: when rendering must be done.
    private func frame(presentAt: CFTimeInterval, deadline: CFTimeInterval, drawable: () -> CAMetalDrawable?) {
        frameMutex.lock()
        defer { frameMutex.unlock() }
        let cfg = configLock.withLock { $0 }
        let now = CACurrentMediaTime()
        let dt = Float(lastFrameTime > 0 ? min(now - lastFrameTime, 0.1) : 1.0 / 60)
        lastFrameTime = now
        let layout = cfg.layout

        // Head pose, predicted to when this frame reaches the glasses.
        if lastTarget > 0 {
            let gap = presentAt - lastTarget
            let nominal = 1.0 / Double(targetFPS)
            if gap > nominal * 1.5 {
                missedVsyncs += 1
                if lastLateWait > 0 { jitBackoff = min(jitBackoff + 0.001, 0.004) }   // late-start may be too greedy: back off
                // Hitch report: was this callback woken late, did the previous frame's CPU work or
                // GPU wait run long, or did the GPU itself run long?
                if hitchReports < 8 {
                    hitchReports += 1
                    Log.info(String(format: "Hitch: skipped %.0f frame(s); callback %.1f ms after the previous one, arrived with %.1f ms to its deadline; previous frame: CPU %.2f ms, GPU wait %.2f ms, GPU %.2f ms",
                                    gap / nominal - 1, (now - lastCallbackAt) * 1000, (deadline - now) * 1000,
                                    lastCallbackCPUMs, renderer.lastWaitMs, renderer.lastGPUMs))
                }
            }
            maxTargetGapMs = max(maxTargetGapMs, gap * 1000)
        }
        lastTarget = presentAt
        // Wrong pacing: callbacks keep coming at half the rate (or less) while arriving with plenty
        // of time to spare, so it isn't us being slow. Seen for ~20 s after launch, when the link
        // attached while the glasses were still switching from mirroring to extended.
        let nominal = 1.0 / Double(targetFPS)
        pacingCallbacks += 1
        if lastCallbackAt > 0, now - lastCallbackAt > nominal * 1.7, deadline - now > nominal * 0.6 {
            pacingSlow += 1
        }
        if now - pacingWindowStart >= 0.5 {
            if pacingCallbacks >= 20, pacingSlow * 10 >= pacingCallbacks * 4 {
                Log.info(String(format: "Display link paced at %.0f fps instead of %.0f (callbacks early, not late); re-attaching",
                                Double(pacingCallbacks) / (now - pacingWindowStart), targetFPS))
                outputLock.withLock { $0.needsResync = true }
            }
            pacingWindowStart = now; pacingCallbacks = 0; pacingSlow = 0
        }
        lastCallbackAt = now
        defer { lastCallbackCPUMs = (CACurrentMediaTime() - now) * 1000 }
        // Predict to the middle of the frame's time on screen: the tuned lead was measured at 120 Hz,
        // and a 60 Hz frame stays up twice as long.
        // Just in time: the frame must be done by `deadline`, and our GPU work usually takes a
        // fraction of that. Wait until the latest safe moment (recent worst-case GPU time + CPU +
        // margin, backing off after any missed refresh) so the head pose is as fresh as possible:
        // prediction error grows with the square of how far ahead it has to guess.
        lastLateWait = 0
        var sampleNow = now
        if let offset = cfg.handoffOffset {
            // Experiment: start the frame at deadline + offset.
            let wakeAt = deadline + offset
            if wakeAt - now > 0, wakeAt - now < 0.02 {
                Compositor.wait(until: wakeAt)
                sampleNow = CACurrentMediaTime()
                lastLateWait = sampleNow - now
            }
        } else if cfg.lateStart {
            let budget = min(max(jitGPUp98 + 0.0006 + 0.0015 + jitBackoff, 0.0025), 0.008)
            let wakeAt = deadline - budget
            if wakeAt - now > 0.0003, wakeAt - now < 0.012 {
                Compositor.wait(until: wakeAt)
                sampleNow = CACurrentMediaTime()
                lastLateWait = sampleNow - now
            }
        }
        lateWaitSum += lastLateWait
        jitBackoff = max(0, jitBackoff - Double(dt) * 0.0001)   // relax slowly (0.1 ms per second)
        // macOS shows frames either on time or one refresh late, in stretches of seconds that
        // follow WindowServer's load (measured). Predict for when frames are actually appearing:
        // the typical lateness of the last few frames, from macOS's own presentation reports.
        let refresh = 1 / Double(targetFPS)
        let lateness = cfg.followPresentation ? presentationLateness(refresh: refresh) : 0
        let showAt = presentAt + Double(cfg.presentDelay) / Double(targetFPS) + lateness
        let target = showAt + cfg.predictionSeconds + max(0, 0.5 / Double(targetFPS) - 0.5 / 120)
        horizonSum += target - sampleNow; horizonN += 1
        presentSum += showAt - now; deadlineSum += deadline - now
        var head = lastHead
        var tracking = false
        var headSpeed: Float = 0
        var headRate = SIMD3<Float>(repeating: 0)
        if let pose = hid.pose, now - pose.hostTime < 0.5 {
            headSpeed = simd_length(pose.angularVelocity)
            headRate = pose.angularVelocity
            maxPoseAgeMs = max(maxPoseAgeMs, (now - pose.hostTime) * 1000)
            head = pose.predicted(to: target)
            if traceUntil > 0 { traceNow = (pose.orientation, pose.hostTime) }
            tracking = true
            if needsRecenter && pose.warmedUp {
                needsRecenter = false
                let (yaw, _) = SpatialMath.yawPitch(of: head)
                setAnchor(SpatialMath.orientation(yaw: yaw, pitch: 0), animated: false, now: now)
            }
        }
        // Rock-steady screens through tiny head motion (typing, breathing); no lag for real turns.
        let rawHead = head
        if tracking {
            stabilizer.leash = cfg.stabilityRadians
            head = stabilizer.update(head: head, angularSpeed: headSpeed, dt: dt)
        } else {
            stabilizer.reset()
        }
        if tracking {
            func yp(_ q: simd_quatf) -> SIMD2<Float> {
                let (y, p) = SpatialMath.yawPitch(of: q)
                return SIMD2(SpatialMath.degrees(y), SpatialMath.degrees(p))
            }
            let rNow = yp(rawHead), sNow = yp(head)
            if headSpeed < SpatialMath.radians(10), let r1 = rawYP1, let r2 = rawYP2, let s1 = stabYP1, let s2 = stabYP2 {
                let dr = simd_length(rNow - 2 * r1 + r2), ds = simd_length(sNow - 2 * s1 + s2)
                if dr < 5 && ds < 5 {
                    quietRawSum += Double(dr * dr); quietStabSum += Double(ds * ds); quietN += 1
                    quietRawMax = max(quietRawMax, dr); quietStabMax = max(quietStabMax, ds)
                }
            }
            rawYP2 = rawYP1; rawYP1 = rNow; stabYP2 = stabYP1; stabYP1 = sNow
        }
        if let prev = lastRenderedHead {
            maxHeadStepDeg = max(maxHeadStepDeg, SpatialMath.degrees((prev.inverse * head).angle))
        }
        lastRenderedHead = head
        // Jitter = second difference of the rendered view direction (≈0 for smooth motion).
        let (jy, jp) = SpatialMath.yawPitch(of: head)
        let ypNow = SIMD2(SpatialMath.degrees(jy), SpatialMath.degrees(jp))
        if let a = yp1, let b = yp2 {
            let d2 = simd_length(ypNow - 2 * a + b)
            if d2 < 5 { jitterSum += Double(d2 * d2); jitterN += 1; jitterMax = max(jitterMax, d2) }
        }
        yp2 = yp1; yp1 = ypNow
        lastHead = head

        runCommands(layout: layout, mode: cfg.mode, now: now)
        if !layout.panels.isEmpty { focus = min(focus, layout.panels.count - 1) }

        // Anchor animation (recenter / focus), smooth follow, or smart flick/edge-push.
        if cfg.mode != lastMode || !tracking { smart.reset() }
        lastMode = cfg.mode
        if anchorAnimStart > 0 {
            let t = Float(min(1, (now - anchorAnimStart) / 0.3))
            let e = t * t * (3 - 2 * t)
            anchor = simd_slerp(anchorFrom, anchorTo, e)
            if t >= 1 { anchorAnimStart = 0; anchor = anchorTo }
            smart.reset()
        } else if cfg.mode == .smoothFollow, tracking {
            smoothFollow(head: head, layout: layout, lag: cfg.followLag, dt: dt)
        } else if cfg.mode == .smart, tracking {
            smart.sensitivity = cfg.flickSensitivity
            smart.flickEnabled = cfg.smartFlick
            smart.followLag = cfg.followLag
            let (hy, hp) = SpatialMath.yawPitch(of: head)
            let (ay, ap) = SpatialMath.yawPitch(of: anchor)
            let a = smart.update(head: SIMD2(hy, hp), anchor: SIMD2(ay, ap), layout: layout, dt: dt)
            anchor = SpatialMath.orientation(yaw: a.x, pitch: a.y)
            anchorTo = anchor
        }

        // View rotation: layout frame -> eye.
        var viewRot: simd_quatf
        var gaze: Int?
        var gazeHit: (index: Int, uv: SIMD2<Float>)?
        switch cfg.mode {
        case .anchored, .smart, .smoothFollow:
            viewRot = (tracking || !needsRecenter) ? head.inverse * anchor : simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            gazeHit = layout.hit(direction: viewRot.inverse.act(SIMD3(0, 0, -1)), margin: 0.03)
            gaze = gazeHit?.index
        case .headLocked:
            let p = layout.panels.first { $0.index == focus }
            let targetView = p.map { (layout.tiltRotation * SpatialMath.orientation(yaw: $0.yaw, pitch: 0)).inverse }
                ?? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            lockedView = simd_slerp(lockedView, targetView, min(1, dt * 12))
            viewRot = lockedView
            gaze = p?.index
        }
        // Tilt correction: rotate the picture about the viewing axis (clockwise for +).
        let viewNoRoll = viewRot
        if abs(cfg.rollRadians) > 1e-5 {
            viewRot = simd_quatf(angle: -cfg.rollRadians, axis: SIMD3(0, 0, 1)) * viewRot
        }

        // Projection from the glasses' factory intrinsics.
        let cal = hid.calibration
        let center = cfg.preview ? cal.resolution / 2 : SIMD2(cal.centerX, cal.centerY)
        let intrinsics = Renderer.Intrinsics(focal: SIMD2(cal.focalX, cal.focalY), center: center, calibrated: cal.resolution)
        // Install the lens-distortion maps once the factory calibration is known (not in preview).
        // Keyed by the calibration itself, so another headset's map replaces this one.
        let mapKey: String? = cfg.preview ? nil : cal.distortion.map { "\($0.us.count)x\($0.vs.count)-\($0.xy.first ?? .zero)-\($0.xy.last ?? .zero)-\(cal.resolution)" }
        if mapKey != installedMapKey {
            renderer.setDistortion(average: mapKey != nil ? cal.distortion : nil, left: nil, right: nil, calibrated: cal.resolution)
            installedMapKey = mapKey
        }
        // Side-by-side 3D (the glasses' button switches the display to 3840x1080): by default the same
        // flat picture in both halves; with depth on (`set depth=1`), one view per eye.
        let size = layer.drawableSize
        // Side-by-side from the picture's shape alone: the flat picture needs no per-eye calibration
        // (a failed download mustn't stretch one view across both eyes); depth does.
        let stereo = !cfg.preview && size.width * 10 > size.height * 25
        let eyes: [Renderer.EyeView]
        // Flat picture: both eyes see the same image, so they converge where the two displays do
        // (~3.6 m) and the screens are seen at that distance, whatever the layout's own distance.
        // Turning or nodding swings the eyes around the neck; a real object 3.6 m away shifts by
        // the matching parallax, and screens drawn without it ride along with the head a little
        // (~0.5° on a 20° turn) — a faint swim. The neck offset is scaled so the parallax matches
        // 3.6 m while the geometry stays at the layout's distance. Not in head-locked mode, where
        // the screens are meant to move with the head.
        // Applied as the equivalent small rotation, not as moving the viewpoint: moving the viewpoint
        // off the centre of a curved layout made nearer parts shift more than farther ones, which
        // with no depth cues (both eyes see the same image) reads as the screens warping. A rotation
        // gives the exact parallax where you look and distorts nothing.
        var flatView = simd_float4x4(viewRot)
        if cfg.neckModel, cfg.mode != .headLocked, !cfg.preview {
            let headInLayout = viewNoRoll.inverse                 // head orientation in the layout frame
            let t = headInLayout.act(Compositor.neckToEyes) - Compositor.neckToEyes   // eye offset (m)
            let u = headInLayout.act(SIMD3<Float>(0, 0, -1))      // where you look
            let delta = simd_cross(t, u) / (cal.convergenceDistance ?? 3.6)
            let angle = simd_length(delta)
            if angle > 1e-7, angle < 0.1 {
                flatView = simd_float4x4(viewRot * simd_quatf(angle: angle, axis: delta / angle))
            }
        }
        if stereo && (cfg.flat3D || cal.eyes.count != 2) {
            let flat = Renderer.EyeView(intrinsics: intrinsics, view: flatView, map: 0)
            eyes = [flat, flat]
        } else if stereo {
            // Neck model: heads turn and tilt about the neck, so the eyes also move a few cm. Without
            // this, stereo screens at 1.5 m swim against the real world on every turn or tilt.
            let neck = Compositor.neckToEyes
            let headView = SpatialMath.translation(-neck) * simd_float4x4(viewRot) * SpatialMath.translation(neck)
            // Left half of the picture → left eye (verified with an eye test).
            eyes = (0..<2).map { i in
                Renderer.EyeView(intrinsics: intrinsics, view: cal.eyeView(i) * headView, map: 0)
            }
        } else {
            eyes = [Renderer.EyeView(intrinsics: intrinsics, view: flatView, map: 0)]
        }
        if stereo != lastStereo {
            lastStereo = stereo
            Log.info(stereo ? "3D side-by-side: \(cfg.flat3D ? "same flat picture in both eyes" : "one view per eye")" : "2D: rendering a single view")
        }

        // Per-panel look: brightness, eased focus dimming, cursor ring.
        let captures = capturesLock.withLock { $0 }
        let cursorIndex = cursorLock.withLock { $0 }
        let multi = layout.panels.count > 1
        let baseDim = 1 - cfg.brightness
        let ease = min(1, dt * 10)
        // Live cursor: read the mouse right now (120 Hz) and place it on its glasses screen.
        let cursorState = cursorStateLock.withLock { $0 }
        if cursorState.seq != uploadedCursorSeq {
            renderer.setCursorImage(cursorState.image)
            uploadedCursorSeq = cursorState.seq
        }
        var cursorPanel: Int?
        var cursorRect = SIMD4<Float>.zero
        if cursorState.visible, cursorState.image != nil, let loc = CGEvent(source: nil)?.location {
            // Cached bounds: asking WindowServer every frame cost ~20 µs, and up to 5 ms while it's busy.
            for s in screensLock.withLock({ $0 }) {
                let b = DisplayBoundsCache.bounds(s.id)
                guard b.contains(loc), b.width > 0, b.height > 0 else { continue }
                let tip = SIMD2(Float((loc.x - b.minX) / b.width), Float((loc.y - b.minY) / b.height))
                let (panel, uv) = glideCursor(to: s.index, uv: tip, layout: layout, now: now)
                let hot = SIMD2(Float(cursorState.hotSpot.x / b.width), Float(cursorState.hotSpot.y / b.height))
                let size = SIMD2(Float(cursorState.size.width / b.width), Float(cursorState.size.height / b.height))
                let o = uv - hot
                cursorRect = SIMD4(o.x, o.y, o.x + size.x, o.y + size.y)
                cursorPanel = panel
                break
            }
        }
        let draws = layout.panels.map { p -> Renderer.PanelDraw in
            let wantDim: Float = (multi && gaze != nil && gaze != p.index) ? cfg.focusDim : 0
            let d = (panelDim[p.index] ?? 0) + (wantDim - (panelDim[p.index] ?? 0)) * ease
            panelDim[p.index] = d
            let ring: Float = cfg.highlightCursor && multi && p.index == cursorIndex ? 0.9 : 0
            return Renderer.PanelDraw(index: p.index, panel: p, frame: captures[p.index]?.latestFrame,
                                      highlight: ring, dim: 1 - (1 - baseDim) * (1 - d),
                                      cursorRect: p.index == cursorPanel ? cursorRect : nil)
        }
        // Nothing changed since the last drawn frame (head within a tenth of a pixel, same screen
        // contents, cursor, fades and settings)? Then the glasses already show this frame: skip it.
        // Typing with a steady head costs no GPU time at all, which leaves the GPU free for the
        // frames that do change.
        var key: [Double] = [Double(cfg.version), Double(eyes.count), Double(installedMapKey?.hashValue ?? 0), Double(layer.drawableSize.width),
                             Double(cursorState.seq), cursorState.visible ? 1 : 0,
                             (Double(pictureMotion) * 100).rounded()]   // keep drawing until back to fully sharp
        for d in draws {
            key += [Double(d.index), Double(d.frame?.seq ?? 0), Double(d.highlight), (Double(d.dim) * 2048).rounded()]
            if let r = d.cursorRect { key += [Double(r.x), Double(r.y), Double(r.z), Double(r.w)] }
        }
        let viewMoved = lastDrawnView.map { SpatialMath.degrees(($0.inverse * viewRot).angle) > 0.002 } ?? true
        // How fast the picture moves across the display (the view, after stabilizing): 0 below
        // 3°/s … 1 above 15°/s. Rises at once, eases back over ~150 ms after you stop.
        let viewSpeed = lastFrameView.map { SpatialMath.degrees(($0.inverse * viewRot).angle) / max(dt, 1e-3) } ?? 0
        lastFrameView = viewRot
        let motionTarget = min(max((viewSpeed - 3) / 12, 0), 1)
        pictureMotion = motionTarget > pictureMotion ? motionTarget : pictureMotion + (motionTarget - pictureMotion) * min(1, dt / 0.15)
        // Rolling scan-out: how far the view turns while the display lights the picture top to
        // bottom (one refresh). Only when the view really moves (the stabiliser holds it still for
        // tiny wobble), never in head-locked mode (the screens move with the head there).
        if cfg.style.scanDirection != 0, tracking, cfg.mode != .headLocked {
            let t = min(max((viewSpeed - 2) / 6, 0), 1)
            let roll = simd_quatf(angle: -cfg.rollRadians, axis: SIMD3(0, 0, 1))
            scanRotation = roll.act(headRate) * Float(t * t * (3 - 2 * t)) * cfg.scanScale / Float(targetFPS)
        } else {
            scanRotation = .zero
        }
        var renderedThisFrame = false
        renderer.presentTarget = presentAt   // lateness is measured against macOS's own schedule
        if !viewMoved, key == lastDrawnKey, pendingSnapshot == nil {
            unchangedFrames += 1
        } else if let target = drawable(), renderer.render(drawable: target, eyes: eyes,
                                  layout: layout, panels: draws, style: cfg.style, motion: pictureMotion, scan: scanRotation,
                                  snapshotTo: pendingSnapshot) {
            pendingSnapshot = nil
            lastDrawnView = viewRot
            renderedThisFrame = true
            // Recent GPU frame times for the just-in-time budget (the value of the last finished frame).
            let g = renderer.lastGPUMs / 1000
            if g > 0, g != lastGPUSeen {
                lastGPUSeen = g
                jitGPU[jitIndex] = g; jitIndex = (jitIndex + 1) % jitGPU.count
                if jitIndex % 30 == 0 { jitGPUp98 = jitGPU.sorted()[jitGPU.count * 98 / 100] }
            }
            lastDrawnKey = key
            // Capture → glasses latency for screens showing a new frame.
            for d in draws {
                guard let f = d.frame, f.seq != shownSeq[d.index] else { continue }
                if let prev = shownSeq[d.index], f.seq > prev + 1 { unshownCaptures[d.index, default: 0] += Int(f.seq - prev - 1) }
                shownSeq[d.index] = f.seq
                captureToGlassesSum[d.index, default: 0] += showAt - f.arrival
                captureShown[d.index, default: 0] += 1
            }
        }

        // Publish for the UI / cursor controller.
        let (vy, vp) = SpatialMath.yawPitch(of: layout.tiltRotation.inverse * viewNoRoll.inverse)
        // Frame trace (`set trace=N`): every callback for N seconds, to find stutters in motion.
        if traceUntil > 0 {
            let (ry, rp) = SpatialMath.yawPitch(of: rawHead)
            // The measured head, as the same view direction the frame was drawn with (layout frame).
            var nowYP = SIMD2<Float>(.nan, .nan), nowT = 0.0
            if let n = traceNow {
                let v = n.q.inverse * anchor
                let (ny, np) = SpatialMath.yawPitch(of: layout.tiltRotation.inverse * v.inverse)
                nowYP = SIMD2(SpatialMath.degrees(ny), SpatialMath.degrees(np)); nowT = n.t
            }
            traceRows.append(String(format: "%.6f,%.6f,%.6f,%d,%.5f,%.5f,%.5f,%.5f,%.2f,%.3f,%.3f,%.3f,%.3f,%.3f,%.5f,%.5f,%.6f",
                                    now, presentAt, deadline, renderedThisFrame ? 1 : 0,
                                    SpatialMath.degrees(vy), SpatialMath.degrees(vp), SpatialMath.degrees(ry), SpatialMath.degrees(rp),
                                    SpatialMath.degrees(headSpeed), pictureMotion, renderer.lastGPUMs, lastCallbackCPUMs, lastLateWait * 1000,
                                    lateness * 1000, nowYP.x, nowYP.y, nowT))
            if now > traceUntil {
                let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/XRealDesk")
                let url = dir.appendingPathComponent("frames.csv")
                let text = "t,present,deadline,rendered,viewYaw,viewPitch,headYaw,headPitch,headSpeed,motion,gpuMs,cpuMs,lateMs,predictedLateMs,nowYaw,nowPitch,nowT\n" + traceRows.joined(separator: "\n") + "\n"
                try? text.write(to: url, atomically: true, encoding: .utf8)
                let presented = presentedLock.withLock { $0 }
                let ptext = "target,actual\n" + presented.map { String(format: "%.6f,%.6f", $0.0, $0.1) }.joined(separator: "\n") + "\n"
                try? ptext.write(to: dir.appendingPathComponent("presented.csv"), atomically: true, encoding: .utf8)
                Log.info("Frame trace written: \(traceRows.count) frames → \(url.path)")
                traceUntil = 0; traceRows.removeAll()
            }
        }
        frameCount += 1
        var fps: Double?
        if now - fpsWindowStart >= 1 {
            fps = Double(frameCount) / (now - fpsWindowStart)
            frameCount = 0
            fpsWindowStart = now
            statsSeconds += 1
            if statsSeconds % 10 == 0 {
                let st = renderer.takeStats()
                let gpuTimes = renderer.takeGPUTimes()
                Log.info(String(format: "Frames: %.0f fps (render thread), rendered %d, skipped busy %d, missed vsyncs %d, max frame gap %.1f ms, max pose age %.1f ms, max head step %.2f°, jitter rms %.4f° max %.3f°, GPU %.2f ms avg / %.2f ms max (%.1fx%@), IMU %.0f Hz, predicting %.1f ms ahead (shown in %.1f ms, deadline %.1f ms, started %.1f ms late, GPU p98 %.1f ms, backoff %.1f ms)",
                                fps!, st.rendered, st.skippedBusy, missedVsyncs, maxTargetGapMs, maxPoseAgeMs, maxHeadStepDeg,
                                sqrt(jitterSum / Double(max(jitterN, 1))), jitterMax,
                                gpuTimes.avg, gpuTimes.max, cfg.style.supersample, cfg.style.lensCorrection ? ", lens corrected" : "",
                                hid.sampleRate, horizonSum / Double(max(horizonN, 1)) * 1000,
                                presentSum / Double(max(horizonN, 1)) * 1000, deadlineSum / Double(max(horizonN, 1)) * 1000,
                                lateWaitSum / Double(max(horizonN, 1)) * 1000, jitGPUp98 * 1000, jitBackoff * 1000))
                horizonSum = 0; horizonN = 0; presentSum = 0; deadlineSum = 0; lateWaitSum = 0
                var capture: [String] = []
                for (i, c) in capturesLock.withLock({ $0 }).sorted(by: { $0.key < $1.key }) {
                    let s = c.takeStats()
                    let shown = captureShown[i] ?? 0
                    capture.append(String(format: "screen %d: %.0f new frames/s (%.1f ms old on arrival, max %.1f; longest gap %.0f ms), %d shown (%.1f ms arrival→glasses), %d never shown",
                                          i + 1, Double(s.frames) / 10, s.latencySum / Double(max(s.frames, 1)) * 1000, s.latencyMax * 1000,
                                          s.gapMax * 1000, shown, (captureToGlassesSum[i] ?? 0) / Double(max(shown, 1)) * 1000,
                                          unshownCaptures[i] ?? 0))
                }
                Log.info("Capture: " + capture.joined(separator: "; ") + String(format: "; %d unchanged frames skipped", unchangedFrames)
                         + (TypingLatency.report().map { "; " + $0 } ?? ""))
                captureShown = [:]; captureToGlassesSum = [:]; unshownCaptures = [:]; unchangedFrames = 0
                jitterSum = 0; jitterN = 0; jitterMax = 0
                if quietN > 120 {
                    let rawRMS = sqrt(quietRawSum / Double(quietN)), stabRMS = sqrt(quietStabSum / Double(quietN))
                    Log.info(String(format: "Working jitter (%.0f s not turning): without stabilizer %.4f° rms / %.3f° max, with %.4f° rms / %.3f° max → %.0f× steadier (stability %.2f°)",
                                    Double(quietN) / 120, rawRMS, quietRawMax, stabRMS, quietStabMax,
                                    rawRMS / max(stabRMS, 1e-6), SpatialMath.degrees(cfg.stabilityRadians)))
                }
                quietRawSum = 0; quietStabSum = 0; quietN = 0; quietRawMax = 0; quietStabMax = 0
                missedVsyncs = 0; hitchReports = 0; maxTargetGapMs = 0; maxPoseAgeMs = 0; maxHeadStepDeg = 0
            }
        }
        var out = outputLock.withLock { $0 }
        out.gaze = gaze
        out.gazeIndex = gazeHit?.index
        if let g = gazeHit { out.gazeUV = g.uv }
        if cal.resolution.x > 0, cal.resolution.y > 0 { out.aim = center / cal.resolution }
        out.viewYawPitch = SIMD2(vy, vp)
        // Which screens you could see within the next ~100 ms (FOV + 20° of head turn).
        let fovHalf = SIMD2<Float>(SpatialMath.radians(cal.fovDegrees.x / 2), SpatialMath.radians(cal.fovDegrees.y / 2))
        let margin = SpatialMath.radians(20)
        var near = Set<Int>()
        for p in layout.panels {
            var dy = p.yaw - vy
            while dy > .pi { dy -= 2 * .pi }
            while dy < -.pi { dy += 2 * .pi }
            let dp = (p.pitch - layout.tilt) - vp
            let half = SIMD2(atan(p.size.x / 2 / layout.distance), atan(p.size.y / 2 / layout.distance))
            if abs(dy) < half.x + fovHalf.x + margin, abs(dp) < half.y + fovHalf.y + margin { near.insert(p.index) }
        }
        out.nearView = near
        out.tracking = tracking
        out.sideBySide = lastStereo
        if let fps { out.fps = fps }
        out.lastFrameAt = now
        let published = out
        outputLock.withLock { $0 = published }
    }

    private func runCommands(layout: ScreenLayout, mode: TrackingMode, now: CFTimeInterval) {
        let commands = commandLock.withLock { c -> [Command] in defer { c.removeAll() }; return c }
        for c in commands {
            switch c {
            case .recenter(let panel):
                let (yaw, pitch) = SpatialMath.yawPitch(of: lastHead)
                // Keep screens level unless you're clearly reclined / looking down on purpose.
                let usePitch = abs(pitch) > SpatialMath.radians(20) ? pitch : 0
                setAnchor(SpatialMath.orientation(yaw: yaw, pitch: usePitch), animated: true, now: now)
                focus = panel
            case .focus(let panel, let moveAnchor):
                focus = panel
                if moveAnchor, let p = layout.panels.first(where: { $0.index == panel }) {
                    // Swing the layout so this panel sits where you're currently looking.
                    let (yaw, _) = SpatialMath.yawPitch(of: lastHead)
                    let (_, anchorPitch) = SpatialMath.yawPitch(of: anchorTo)
                    setAnchor(SpatialMath.orientation(yaw: yaw, pitch: anchorPitch) * SpatialMath.rotationY(-p.yaw),
                              animated: true, now: now)
                }
            case .trackingRestarted:
                needsRecenter = true
                stabilizer.reset()
            case .forgetTextures(let index):
                if let index { renderer.forget(index: index) } else { renderer.forgetAll() }
            case .snapshot(let url):
                pendingSnapshot = url
            case .trace(let seconds):
                traceRows.removeAll(); traceRows.reserveCapacity(Int(seconds * 130))
                presentedLock.withLock { $0.removeAll() }
                traceUntil = CACurrentMediaTime() + min(max(seconds, 1), 60)
            case .stall(let seconds):
                Log.info("Test: blocking the render thread for \(seconds) s")
                Thread.sleep(forTimeInterval: min(max(seconds, 0), 10))
            }
        }
    }

    private func setAnchor(_ q: simd_quatf, animated: Bool, now: CFTimeInterval) {
        anchorFrom = anchor
        anchorTo = q
        anchorAnimStart = animated ? now : 0
        if !animated { anchor = q }
    }

    /// Smooth follow: the focused screen stays in front of you and glides after your head with a
    /// slight lag. A small dead zone keeps it perfectly still for small head movements while reading.
    private func smoothFollow(head: simd_quatf, layout: ScreenLayout, lag: Float, dt: Float) {
        guard let p = layout.panels.first(where: { $0.index == focus }) ?? layout.panels.first else { return }
        let (hy, hp) = SpatialMath.yawPitch(of: head)
        var (ay, ap) = SpatialMath.yawPitch(of: anchor)
        // Where the anchor must be for the focused screen to sit straight ahead.
        // (Panel pitch includes the layout tilt, which is applied separately, so remove it here.)
        var dy = (hy - p.yaw) - ay
        while dy > .pi { dy -= 2 * .pi }
        while dy < -.pi { dy += 2 * .pi }
        let dp = (hp - (p.pitch - layout.tilt)) - ap
        let deadYaw = SpatialMath.radians(5), deadPitch = SpatialMath.radians(4)
        let excessY = dy > 0 ? max(dy - deadYaw, 0) : min(dy + deadYaw, 0)
        let excessP = dp > 0 ? max(dp - deadPitch, 0) : min(dp + deadPitch, 0)
        let k = 1 - exp(-dt / max(lag, 0.02))
        ay += excessY * k
        ap += excessP * k
        anchor = SpatialMath.orientation(yaw: ay, pitch: max(-1.3, min(1.3, ap)))
        anchorTo = anchor
    }
}
