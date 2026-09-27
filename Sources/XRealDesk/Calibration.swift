import AppKit
import QuartzCore
import simd
import XRCore

/// Guided tracking calibration: short tasks that produce exactly the head motion the learned
/// predictor needs (holding still, talking, typing, following a dot at three speeds, jumping between
/// targets, fast back-and-forth), each recorded and labelled, then an eye-test style timing check.
///
/// A head-locked aim ring is drawn in the glasses (it moves with your head); the targets are drawn in
/// a window on the glasses screen you're facing, so they're world-locked like everything else. A task
/// starts only once the ring has rested on its start target, and its progress fills the ring.
/// Esc cancels, Space skips a task.
final class CalibrationSession {
    enum Kind {
        case hold, talk, type
        /// The dot swings smoothly (fast in the middle, slowing at the ends) along a path that's
        /// drawn in full, so you always know where it goes. Amplitude in degrees.
        case follow(shape: FollowShape, amplitude: SIMD2<Float>, period: Double)
        case jumps(count: Int)
        case sweep(count: Int)
        case timing
    }

    enum FollowShape { case horizontal, circle }

    struct Step {
        let label: String
        let title: String
        let detail: String
        let kind: Kind
        let seconds: Double
    }

    static let steps: [Step] = [
        Step(label: "still", title: "Hold still",
             detail: "Keep the ring on the dot and hold your head as still as you comfortably can.",
             kind: .hold, seconds: 15),
        Step(label: "talking", title: "Hold still and talk",
             detail: "Keep the ring on the dot and read this aloud:\n\n“The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs. How vexingly quick daft zebras jump. Sphinx of black quartz, judge my vow.”",
             kind: .talk, seconds: 20),
        Step(label: "typing", title: "Hold still and type",
             detail: "Keep the ring on the dot and type anything, like you normally would.",
             kind: .type, seconds: 20),
        Step(label: "follow-slow", title: "Follow the dot (slow)",
             detail: "Keep the ring on the dot as it swings left and right.",
             kind: .follow(shape: .horizontal, amplitude: SIMD2(10, 0), period: 8), seconds: 16),
        Step(label: "follow-medium", title: "Follow the dot (circle)",
             detail: "Keep the ring on the dot as it goes around the circle.",
             kind: .follow(shape: .circle, amplitude: SIMD2(9, 6), period: 7), seconds: 21),
        Step(label: "follow-fast", title: "Follow the dot (faster)",
             detail: "Keep up as well as you can: it swings left and right a bit faster.",
             kind: .follow(shape: .horizontal, amplitude: SIMD2(10, 0), period: 3.5), seconds: 14),
        Step(label: "jumps", title: "Jump to each dot",
             detail: "Look at each dot until it turns green; the next one appears after a moment.",
             kind: .jumps(count: 10), seconds: 0),
        Step(label: "sweep", title: "Back and forth, fast",
             detail: "Look at the lit dot, as fast as you can.", kind: .sweep(count: 10), seconds: 0),
        Step(label: "timing", title: "Timing check",
             detail: "Gently shake your head side to side while looking at the line.\nPress 1 or 2 for the one where the line holds stiller (3 if they look the same).",
             kind: .timing, seconds: 0),
    ]

    // Hooks into the app.
    var showInstruction: (String?) -> Void = { _ in }
    var showAim: (SIMD2<Float>?, CGFloat, NSColor) -> Void = { _, _, _ in }
    var predictionMs: () -> Double = { 14 }
    var setPredictionMs: (Double) -> Void = { _ in }
    var onFinish: (_ folder: URL?, _ completed: Bool) -> Void = { _, _ in }

    private(set) var screenIndex: Int
    /// Other glasses screens to fall back to: a screen showing an app in full screen can't show
    /// this window (macOS keeps other apps' windows out of a full-screen Space).
    var fallbackScreens: [(index: Int, screen: NSScreen)] = []
    private let hid: GlassesHIDService
    private let window: CalibrationWindow
    /// Angular size of the screen (degrees), to judge "on target" in degrees.
    private let widthDegrees: Float
    private var heightDegrees: Float
    private let folder: URL

    private enum Phase { case waiting, running, done }
    private var stepIndex = 0
    private var phase = Phase.waiting
    private var dwell: Double = 0          // time the ring has rested on the start target
    private var progress: Double = 0       // seconds (or hits) completed in the current task
    private var runStart: CFTimeInterval = 0
    private var doneAt: CFTimeInterval = 0
    private var lastTick: CFTimeInterval = 0
    private var lastKeyAt: CFTimeInterval = 0
    private var recordStart: CFTimeInterval?
    private var labels: [String] = []
    private var target = SIMD2<Float>(0.5, 0.5)
    private var litSide = 0
    private var jumpHitAt: CFTimeInterval?
    private var rng = SystemRandomNumberGenerator()
    // Timing check (eye-test ladder around the current setting).
    private var timingBase: Double = 14
    private var timingRound = 0
    private var timingShowingB = false
    private var timingSwitchAt: CFTimeInterval = 0
    private static let timingSteps: [(spread: Double, move: Double)] = [(6, 4), (3, 2), (2, 1)]
    private var startingPrediction: Double = 14
    /// The app you were in: gets the keyboard back afterwards (calibration takes it so the typing
    /// task doesn't type into your apps).
    private var previousApp: NSRunningApplication?

    init(screen: NSScreen, index: Int, widthDegrees: Float, hid: GlassesHIDService) {
        self.screenIndex = index
        self.hid = hid
        self.widthDegrees = widthDegrees
        let aspect = Float(screen.frame.height / max(screen.frame.width, 1))
        self.heightDegrees = widthDegrees * aspect
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                formatOptions: [.withYear, .withMonth, .withDay, .withTime])
        folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/XRealDesk/calibration-\(stamp)", isDirectory: true)
        window = CalibrationWindow(screen: screen)
        window.view.onKey = { [weak self] e in self?.key(e) }
    }

    func start() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        startingPrediction = predictionMs()
        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.checkVisible() }
        Log.info("Calibration started on screen \(screenIndex + 1) → \(folder.path); window visible \(window.isVisible) on \(window.screen?.localizedName ?? "no screen") at \(window.frame), app active \(NSApp.isActive)")
        enter(0)
    }

    func cancel() { finish(completed: false) }

    private func checkVisible() {
        guard window.isVisible else { return }   // finished or cancelled meanwhile
        if window.occlusionState.contains(.visible) {
            if !fallbackTried.isEmpty {
                showInstruction("Calibration is on screen \(screenIndex + 1): look there")
            }
            return
        }
        guard let next = fallbackScreens.first else {
            Log.info("Calibration window can't be shown on any glasses screen (all in full screen?)")
            showInstruction("Calibration needs a glasses screen that isn't in full screen")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.cancel() }
            return
        }
        fallbackScreens.removeFirst()
        fallbackTried.append(screenIndex)
        Log.info("Calibration window hidden on screen \(screenIndex + 1) (full screen app?); trying screen \(next.index + 1)")
        screenIndex = next.index
        let aspect = Float(next.screen.frame.height / max(next.screen.frame.width, 1))
        heightDegrees = widthDegrees * aspect
        window.setFrame(next.screen.frame, display: true)
        window.view.frame = NSRect(origin: .zero, size: next.screen.frame.size)
        window.makeKeyAndOrderFront(nil)
        if let s = CalibrationSession.steps.indices.contains(stepIndex) ? CalibrationSession.steps[stepIndex] : nil {
            window.view.set(title: "\(stepIndex + 1) of \(CalibrationSession.steps.count)  ·  \(s.title)",
                            detail: s.detail + "\n\nRest the ring on the dot to start.")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.checkVisible() }
    }
    private var fallbackTried: [Int] = []

    // MARK: Tick (60 Hz, main thread)

    /// `gaze`: where straight ahead meets this screen (UV), nil if you're looking elsewhere.
    func tick(now: CFTimeInterval, gaze realGaze: SIMD2<Float>?, aim: SIMD2<Float>) {
        let dt = lastTick > 0 ? min(now - lastTick, 0.1) : 0
        lastTick = now
        guard stepIndex < CalibrationSession.steps.count else { return }
        let step = CalibrationSession.steps[stepIndex]
        var gaze = realGaze
        if autopilot {
            // Test mode: "look" at the target, "type", and answer the timing check with 3.
            gaze = phase == .waiting ? startTarget(step) : target
            if isTyping(step) { lastKeyAt = now }
            if isTiming(step), phase == .running, now - timingSwitchAt > 1 { answerTiming("3", now: now) }
        }

        switch phase {
        case .waiting:
            let start = startTarget(step)
            window.view.show(targets: [(start, .active)], path: pathFor(step), bigLabel: nil)
            let on = gaze.map { degrees($0, start) < 2.0 } ?? false
            dwell = on ? dwell + dt : max(0, dwell - dt * 2)
            showAim(aim, CGFloat(dwell / 0.8), .systemBlue)
            if dwell >= 0.8 { begin(step, now: now) }

        case .running:
            let fraction = run(step, now: now, dt: dt, gaze: gaze, aim: aim)
            if fraction >= 1 { complete(now: now) }

        case .done:
            showAim(aim, 1, .systemGreen)
            if now - doneAt > 0.7 { enter(stepIndex + 1) }
        }
    }

    // MARK: Steps

    private func enter(_ i: Int) {
        stepIndex = i
        guard i < CalibrationSession.steps.count else { finish(completed: true); return }
        let step = CalibrationSession.steps[i]
        phase = .waiting
        dwell = 0; progress = 0; litSide = 0
        target = startTarget(step)
        window.view.set(title: "\(i + 1) of \(CalibrationSession.steps.count)  ·  \(step.title)",
                        detail: step.detail + "\n\nRest the ring on the dot to start.")
        showInstruction("\(step.title): rest the ring on the dot to start")
        if case .timing = step.kind {
            timingBase = predictionMs(); timingRound = 0
        }
    }

    private func begin(_ step: Step, now: CFTimeInterval) {
        phase = .running
        runStart = now
        progress = 0
        if recordStart == nil, !isTiming(step) {
            hid.recordIMU(to: folder.appendingPathComponent("imu.csv"), seconds: 1800)
            recordStart = now
        }
        window.view.set(title: "\(stepIndex + 1) of \(CalibrationSession.steps.count)  ·  \(step.title)", detail: step.detail)
        showInstruction(step.title)
        if case .timing = step.kind { timingSwitchAt = now; timingShowingB = false; applyTiming() }
        if case .jumps = step.kind { target = randomTarget(awayFrom: target) }
    }

    /// Runs one tick of the current task; returns how far along it is (1 = done).
    private func run(_ step: Step, now: CFTimeInterval, dt: Double, gaze: SIMD2<Float>?, aim: SIMD2<Float>) -> Double {
        let onTarget: (Float) -> Bool = { tol in gaze.map { self.degrees($0, self.target) < tol } ?? false }
        switch step.kind {
        case .hold, .talk:
            if onTarget(2.5) { progress += dt }
            window.view.show(targets: [(target, .active)], path: nil, bigLabel: nil)
            showAim(aim, CGFloat(progress / step.seconds), onTarget(2.5) ? .systemGreen : .systemOrange)
            return progress / step.seconds

        case .type:
            let typing = now - lastKeyAt < 1.2
            if onTarget(2.5) && typing { progress += dt }
            window.view.show(targets: [(target, .active)], path: nil, bigLabel: nil)
            showAim(aim, CGFloat(progress / step.seconds), onTarget(2.5) && typing ? .systemGreen : .systemOrange)
            return progress / step.seconds

        case .follow:
            let t = now - runStart
            target = followPoint(step, time: t)
            window.view.show(targets: [(target, .active)], path: pathFor(step), bigLabel: nil)
            showAim(aim, CGFloat(t / step.seconds), onTarget(3) ? .systemGreen : .systemOrange)
            return t / step.seconds

        case .jumps(let count):
            if let hit = jumpHitAt {
                // Hit: green for a moment, then the next dot.
                window.view.show(targets: [(target, .done)], path: nil, bigLabel: nil)
                if now - hit > 0.6 { jumpHitAt = nil; target = randomTarget(awayFrom: target) }
            } else {
                if onTarget(2.5) {
                    dwell += dt
                    if dwell >= 0.5 { progress += 1; dwell = 0; jumpHitAt = now }
                } else { dwell = 0 }
                window.view.show(targets: [(target, .active)], path: nil, bigLabel: nil)
            }
            showAim(aim, CGFloat(progress / Double(count)), .systemGreen)
            return progress / Double(count)

        case .sweep(let count):
            let sides = [SIMD2<Float>(0.1, 0.5), SIMD2<Float>(0.9, 0.5)]
            target = sides[litSide]
            if onTarget(3) { progress += 1; litSide = 1 - litSide }
            window.view.show(targets: [(sides[0], litSide == 0 ? .active : .idle), (sides[1], litSide == 1 ? .active : .idle)],
                             path: nil, bigLabel: nil)
            showAim(aim, CGFloat(progress / Double(count)), .systemGreen)
            return progress / Double(count)

        case .timing:
            // Alternate the two candidate timings every 3 s until a key is pressed.
            if now - timingSwitchAt > 3 { timingSwitchAt = now; timingShowingB.toggle(); applyTiming() }
            window.view.show(targets: [], path: nil, bigLabel: timingShowingB ? "2" : "1", line: true)
            showAim(aim, CGFloat(Double(timingRound) / Double(CalibrationSession.timingSteps.count)), .systemGreen)
            showInstruction("Timing \(timingRound + 1)/\(CalibrationSession.timingSteps.count): now showing \(timingShowingB ? "2" : "1") · press 1, 2 or 3")
            return Double(timingRound) / Double(CalibrationSession.timingSteps.count)
        }
    }

    private func complete(now: CFTimeInterval) {
        let step = CalibrationSession.steps[stepIndex]
        if let r = recordStart, !isTiming(step) {
            // Seconds since the recording started (its first sample arrives within ~1 ms).
            labels.append(String(format: "%@,%.3f,%.3f", step.label, max(0, runStart - r), now - r))
        }
        if case .timing = step.kind {
            Log.info(String(format: "Calibration timing: %.0f ms (was %.0f ms)", timingBase, startingPrediction))
            setPredictionMs(timingBase)
        }
        phase = .done
        doneAt = now
        window.view.show(targets: [(target, .done)], path: nil, bigLabel: nil)
        showInstruction("\(step.title) ✓")
    }

    private func finish(completed: Bool) {
        if recordStart != nil { hid.stopIMURecording() }
        if !labels.isEmpty {
            try? ("label,start_s,end_s\n" + labels.joined(separator: "\n") + "\n")
                .write(to: folder.appendingPathComponent("labels.csv"), atomically: true, encoding: .utf8)
        }
        if !completed, stepIndex < CalibrationSession.steps.count,
           case .timing = CalibrationSession.steps[stepIndex].kind {
            setPredictionMs(startingPrediction)   // don't leave a half-tested timing in place
        }
        showAim(nil, 0, .clear)
        showInstruction(nil)
        window.orderOut(nil)
        if let app = previousApp, app != NSRunningApplication.current { app.activate() }
        Log.info("Calibration \(completed ? "finished" : "cancelled"): \(labels.count) tasks recorded")
        onFinish(labels.isEmpty ? nil : folder, completed)
    }

    // MARK: Keys

    private func key(_ e: NSEvent) {
        let now = CACurrentMediaTime()
        lastKeyAt = now
        if e.keyCode == 53 { cancel(); return }   // Esc
        guard stepIndex < CalibrationSession.steps.count else { return }
        let step = CalibrationSession.steps[stepIndex]
        if e.charactersIgnoringModifiers == " ", !isTyping(step) {
            // Space skips the task (recorded part still counts).
            if phase == .running { complete(now: now) } else { enter(stepIndex + 1) }
            return
        }
        guard case .timing = step.kind, phase == .running, let c = e.charactersIgnoringModifiers else { return }
        answerTiming(c, now: now)
    }

    /// Test mode (`set calibrate=autopilot`): runs the whole flow without anyone wearing the glasses.
    var autopilot = false

    private func answerTiming(_ c: String, now: CFTimeInterval) {
        let move = CalibrationSession.timingSteps[timingRound].move
        switch c {
        case "1": timingBase -= move
        case "2": timingBase += move
        case "3": break
        default: return
        }
        timingBase = min(max(timingBase, 0), 40)
        timingRound += 1
        if timingRound >= CalibrationSession.timingSteps.count {
            complete(now: now)
        } else {
            timingShowingB = false; timingSwitchAt = now; applyTiming()
        }
    }

    private func isTiming(_ step: Step) -> Bool {
        if case .timing = step.kind { return true }
        return false
    }

    private func isTyping(_ step: Step) -> Bool {
        if case .type = step.kind, phase == .running { return true }
        return false
    }

    private func applyTiming() {
        let spread = CalibrationSession.timingSteps[min(timingRound, CalibrationSession.timingSteps.count - 1)].spread
        setPredictionMs(min(max(timingBase + (timingShowingB ? spread : -spread), 0), 40))
    }

    // MARK: Geometry (screen UV: u left → right, v top → bottom)

    private func degrees(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let d = (a - b) * SIMD2(widthDegrees, heightDegrees)
        return simd_length(d)
    }

    private func startTarget(_ step: Step) -> SIMD2<Float> {
        switch step.kind {
        case .follow: return followPoint(step, time: 0)
        case .sweep: return SIMD2(0.1, 0.5)
        default: return SIMD2(0.5, 0.5)
        }
    }

    private func pathFor(_ step: Step) -> [SIMD2<Float>]? {
        guard case .follow(let shape, _, let period) = step.kind else { return nil }
        let n = shape == .circle ? 64 : 2
        if shape == .horizontal {
            // The whole swing: from one end to the other.
            return [followPoint(step, time: -period / 4), followPoint(step, time: period / 4)]
        }
        return (0...n).map { followPoint(step, time: period * Double($0) / Double(n)) }
    }

    /// Where the following dot is `time` seconds into the task (starts at the centre, moving right).
    private func followPoint(_ step: Step, time: Double) -> SIMD2<Float> {
        guard case .follow(let shape, let amp, let period) = step.kind else { return SIMD2(0.5, 0.5) }
        let a = Float(2 * Double.pi * time / period)
        let ax = amp.x / widthDegrees, ay = amp.y / heightDegrees
        switch shape {
        case .horizontal: return SIMD2(0.5 + ax * sin(a), 0.5)
        case .circle: return SIMD2(0.5 + ax * sin(a), 0.5 - ay * cos(a))
        }
    }

    private func randomTarget(awayFrom last: SIMD2<Float>) -> SIMD2<Float> {
        for _ in 0..<50 {
            let t = SIMD2(Float.random(in: 0.15...0.85, using: &rng), Float.random(in: 0.25...0.75, using: &rng))
            let d = degrees(t, last)
            if d > 8 && d < 20 { return t }
        }
        return SIMD2(1 - last.x, 1 - last.y)
    }
}

// MARK: - Window

/// Borderless window covering one glasses screen, above everything (also full-screen apps).
final class CalibrationWindow: NSWindow {
    let view: CalibrationView

    init(screen: NSScreen) {
        view = CalibrationView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        contentView = view
        isReleasedWhenClosed = false
        backgroundColor = .black
        isOpaque = true
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class CalibrationView: NSView {
    enum TargetState { case idle, active, done }
    var onKey: ((NSEvent) -> Void)?

    private let pathLayer = CAShapeLayer()
    private let lineLayer = CAShapeLayer()
    private var dotLayers: [CAShapeLayer] = []
    private let titleLayer = CATextLayer()
    private let detailLayer = CATextLayer()
    private let bigLayer = CATextLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        pathLayer.strokeColor = NSColor(white: 1, alpha: 0.18).cgColor
        pathLayer.fillColor = nil
        pathLayer.lineWidth = 2
        pathLayer.lineDashPattern = [6, 6]
        lineLayer.strokeColor = NSColor.white.cgColor
        lineLayer.lineWidth = 3
        for (l, size, weight) in [(titleLayer, CGFloat(30), NSFont.Weight.semibold), (detailLayer, 20, .regular), (bigLayer, 90, .bold)] {
            l.font = NSFont.systemFont(ofSize: size, weight: weight)
            l.fontSize = size
            l.foregroundColor = NSColor(white: 1, alpha: l === detailLayer ? 0.75 : 1).cgColor
            l.alignmentMode = .center
            l.isWrapped = true
            l.contentsScale = 2
        }
        [pathLayer, lineLayer, titleLayer, detailLayer, bigLayer].forEach { layer?.addSublayer($0) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { onKey?(event) }

    func set(title: String, detail: String) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        titleLayer.string = title
        detailLayer.string = detail
        let w = bounds.width * 0.7
        titleLayer.frame = CGRect(x: (bounds.width - w) / 2, y: bounds.height - 90, width: w, height: 44)
        detailLayer.frame = CGRect(x: (bounds.width - w) / 2, y: 30, width: w, height: bounds.height * 0.22)
        CATransaction.commit()
    }

    private func point(_ uv: SIMD2<Float>) -> CGPoint {
        CGPoint(x: CGFloat(uv.x) * bounds.width, y: (1 - CGFloat(uv.y)) * bounds.height)
    }

    func show(targets: [(SIMD2<Float>, TargetState)], path: [SIMD2<Float>]?, bigLabel: String?, line: Bool = false) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        while dotLayers.count < targets.count {
            let l = CAShapeLayer()
            l.path = CGPath(ellipseIn: CGRect(x: -14, y: -14, width: 28, height: 28), transform: nil)
            l.lineWidth = 3
            layer?.addSublayer(l)
            dotLayers.append(l)
        }
        for (i, l) in dotLayers.enumerated() {
            guard i < targets.count else { l.isHidden = true; continue }
            let (uv, state) = targets[i]
            l.isHidden = false
            l.position = point(uv)
            switch state {
            case .idle: l.fillColor = NSColor(white: 1, alpha: 0.15).cgColor; l.strokeColor = NSColor(white: 1, alpha: 0.6).cgColor
            case .active: l.fillColor = NSColor.systemBlue.cgColor; l.strokeColor = NSColor.white.cgColor
            case .done: l.fillColor = NSColor.systemGreen.cgColor; l.strokeColor = NSColor.white.cgColor
            }
        }
        if let path, let first = path.first {
            let p = CGMutablePath()
            p.move(to: point(first))
            for q in path.dropFirst() { p.addLine(to: point(q)) }
            pathLayer.path = p
        } else {
            pathLayer.path = nil
        }
        if line {
            let p = CGMutablePath()
            p.move(to: CGPoint(x: bounds.midX, y: bounds.height * 0.2))
            p.addLine(to: CGPoint(x: bounds.midX, y: bounds.height * 0.8))
            lineLayer.path = p
        } else {
            lineLayer.path = nil
        }
        bigLayer.string = bigLabel
        bigLayer.frame = CGRect(x: bounds.midX + 60, y: bounds.midY - 55, width: 140, height: 110)
        CATransaction.commit()
    }
}
