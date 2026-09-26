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
        var stabilityRadians: Float = SpatialMath.radians(0.12)
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
        var preview = false
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
    }

    struct Output {
        var gaze: Int?
        /// Head yaw/pitch relative to the layout (radians).
        var viewYawPitch = SIMD2<Float>(0, 0)
        var tracking = false
        var fps: Double = 0
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
        let runLoopLock = OSAllocatedUnfairLock<CFRunLoop?>(uncheckedState: nil)
        var isAlive: Bool { alive.withLock { $0 } }
    }
    private var current: RenderThread?   // main thread only

    // Render-thread-only state.
    private var anchor = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
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
    private var distortionInstalled = false
    private var lastStereo = false
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

    func update(_ config: Config) { configLock.withLock { $0 = config } }
    func send(_ command: Command) { commandLock.withLock { $0.append(command) } }
    func setCaptures(_ captures: [Int: DisplayCapture]) { capturesLock.withLock { $0 = captures } }
    func setCursorScreen(_ index: Int?) { cursorLock.withLock { $0 = index } }
    func setScreens(_ screens: [(index: Int, id: CGDirectDisplayID)]) { screensLock.withLock { $0 = screens } }
    func setCursorImage(_ image: CGImage?, hotSpot: CGPoint, size: CGSize) {
        cursorStateLock.withLock { $0.image = image; $0.hotSpot = hotSpot; $0.size = size; $0.seq += 1 }
    }
    func setCursorVisible(_ visible: Bool) { cursorStateLock.withLock { $0.visible = visible } }
    var output: Output { outputLock.withLock { $0 } }
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
    }

    // MARK: Render thread

    private func threadMain(_ ctx: RenderThread) {
        let rl = CFRunLoopGetCurrent()!
        ctx.runLoopLock.withLock { $0 = rl }
        let link = CAMetalDisplayLink(metalLayer: layer)
        link.delegate = self
        link.preferredFrameRateRange = CAFrameRateRange(minimum: targetFPS, maximum: targetFPS, preferred: targetFPS)
        // macOS shows each frame 3 refreshes after this callback either way (measured: 25 ms at
        // 120 Hz, 50 ms at 60 Hz, for latency 1 or 2), so the head prediction covers that instead.
        link.preferredFrameLatency = 2
        link.add(to: .current, forMode: .default)
        Log.info("Render thread started")
        while ctx.isAlive {
            CFRunLoopRunInMode(.defaultMode, 0.25, false)
        }
        link.invalidate()
        Log.info("Render thread stopped")
    }

    /// Serializes frames: during a stop→start handover the old thread may still be finishing one.
    private let frameMutex = NSLock()

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        frameMutex.lock()
        defer { frameMutex.unlock() }
        let cfg = configLock.withLock { $0 }
        let now = CACurrentMediaTime()
        let dt = Float(lastFrameTime > 0 ? min(now - lastFrameTime, 0.1) : 1.0 / 60)
        lastFrameTime = now
        let layout = cfg.layout

        // Head pose, predicted to when this frame reaches the glasses.
        let presentAt = update.targetPresentationTimestamp
        if lastTarget > 0 {
            let gap = presentAt - lastTarget
            let nominal = 1.0 / Double(targetFPS)
            if gap > nominal * 1.5 { missedVsyncs += 1 }
            maxTargetGapMs = max(maxTargetGapMs, gap * 1000)
        }
        lastTarget = presentAt
        // Predict to the middle of the frame's time on screen: the tuned lead was measured at 120 Hz,
        // and a 60 Hz frame stays up twice as long.
        let target = presentAt + cfg.predictionSeconds + max(0, 0.5 / Double(targetFPS) - 0.5 / 120)
        horizonSum += target - now; horizonN += 1
        presentSum += presentAt - now; deadlineSum += update.targetTimestamp - now
        var head = lastHead
        var tracking = false
        var headSpeed: Float = 0
        if let pose = hid.pose, now - pose.hostTime < 0.5 {
            headSpeed = simd_length(pose.angularVelocity)
            maxPoseAgeMs = max(maxPoseAgeMs, (now - pose.hostTime) * 1000)
            head = pose.predicted(to: target)
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
        switch cfg.mode {
        case .anchored, .smart, .smoothFollow:
            viewRot = (tracking || !needsRecenter) ? head.inverse * anchor : simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            gaze = layout.hit(direction: viewRot.inverse.act(SIMD3(0, 0, -1)), margin: 0.03)?.index
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
        let wantMap = cfg.preview ? false : cal.distortion != nil
        if wantMap != distortionInstalled {
            renderer.setDistortion(average: wantMap ? cal.distortion : nil, left: nil, right: nil, calibrated: cal.resolution)
            distortionInstalled = wantMap
        }
        // Side-by-side 3D (the glasses' button switches the display to 3840x1080): by default the same
        // flat picture in both halves; with depth on (`set depth=1`), one view per eye.
        let size = update.drawable.texture
        let stereo = !cfg.preview && cal.eyes.count == 2 && size.width * 10 > size.height * 25
        let eyes: [Renderer.EyeView]
        if stereo && cfg.flat3D {
            let flat = Renderer.EyeView(intrinsics: intrinsics, view: simd_float4x4(viewRot), map: 0)
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
            eyes = [Renderer.EyeView(intrinsics: intrinsics, view: simd_float4x4(viewRot), map: 0)]
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
            for s in screensLock.withLock({ $0 }) {
                let b = CGDisplayBounds(s.id)
                guard b.contains(loc), b.width > 0, b.height > 0 else { continue }
                let x0 = (loc.x - cursorState.hotSpot.x - b.minX) / b.width
                let y0 = (loc.y - cursorState.hotSpot.y - b.minY) / b.height
                cursorRect = SIMD4(Float(x0), Float(y0), Float(x0 + cursorState.size.width / b.width),
                                   Float(y0 + cursorState.size.height / b.height))
                cursorPanel = s.index
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
        if renderer.render(drawable: update.drawable, eyes: eyes,
                           layout: layout, panels: draws, style: cfg.style, snapshotTo: pendingSnapshot) {
            pendingSnapshot = nil
        }

        // Publish for the UI / cursor controller.
        let (vy, vp) = SpatialMath.yawPitch(of: layout.tiltRotation.inverse * viewNoRoll.inverse)
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
                Log.info(String(format: "Frames: %.0f fps (render thread), rendered %d, skipped busy %d, missed vsyncs %d, max frame gap %.1f ms, max pose age %.1f ms, max head step %.2f°, jitter rms %.4f° max %.3f°, GPU %.2f ms avg / %.2f ms max (%.1fx%@), IMU %.0f Hz, predicting %.1f ms ahead (shown in %.1f ms, deadline %.1f ms)",
                                fps!, st.rendered, st.skippedBusy, missedVsyncs, maxTargetGapMs, maxPoseAgeMs, maxHeadStepDeg,
                                sqrt(jitterSum / Double(max(jitterN, 1))), jitterMax,
                                gpuTimes.avg, gpuTimes.max, cfg.style.supersample, cfg.style.lensCorrection ? ", lens corrected" : "",
                                hid.sampleRate, horizonSum / Double(max(horizonN, 1)) * 1000,
                                presentSum / Double(max(horizonN, 1)) * 1000, deadlineSum / Double(max(horizonN, 1)) * 1000))
                horizonSum = 0; horizonN = 0; presentSum = 0; deadlineSum = 0
                jitterSum = 0; jitterN = 0; jitterMax = 0
                if quietN > 120 {
                    let rawRMS = sqrt(quietRawSum / Double(quietN)), stabRMS = sqrt(quietStabSum / Double(quietN))
                    Log.info(String(format: "Working jitter (%.0f s not turning): without stabilizer %.4f° rms / %.3f° max, with %.4f° rms / %.3f° max → %.0f× steadier (stability %.2f°)",
                                    Double(quietN) / 120, rawRMS, quietRawMax, stabRMS, quietStabMax,
                                    rawRMS / max(stabRMS, 1e-6), SpatialMath.degrees(cfg.stabilityRadians)))
                }
                quietRawSum = 0; quietStabSum = 0; quietN = 0; quietRawMax = 0; quietStabMax = 0
                missedVsyncs = 0; maxTargetGapMs = 0; maxPoseAgeMs = 0; maxHeadStepDeg = 0
            }
        }
        var out = outputLock.withLock { $0 }
        out.gaze = gaze
        out.viewYawPitch = SIMD2(vy, vp)
        out.tracking = tracking
        if let fps { out.fps = fps }
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
