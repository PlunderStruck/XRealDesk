import AppKit
import QuartzCore
import simd
import XRCore

/// A guided tracking session: ~8 minutes of short "levels" across all glasses screens that produce
/// the head motion a personal tracking model learns from (reading, talking, typing, glancing down at
/// the keyboard, popping bubbles on every screen, following a firefly, searching a grid, leaning).
/// Everything is recorded as one take (imu.csv) with a label per level (labels.csv).
///
/// Targets live in viewing angles (degrees, the layout's frame: yaw + = left, pitch + = up), so they
/// can sit on any screen and moving between them is real panning. A head-locked aim ring in the
/// glasses shows where you're looking and fills as a level progresses. Each level waits until you're
/// on its start target. Esc stops, Space skips a level.
final class TrackingSession {
    /// A glasses screen: where it sits (degrees) and its window.
    struct Screen {
        let index: Int
        let yaw: Float, pitch: Float        // centre, degrees
        let width: Float, height: Float     // degrees
        let window: SessionWindow
        var visible = true
    }

    enum Level: CaseIterable {
        case focus, talk, type, glance, pop, firefly, search, shift
        var label: String { "\(self)" }
        var title: String {
            switch self {
            case .focus: return "Focus: read the passage"
            case .talk: return "Talk: read it aloud"
            case .type: return "Type: copy the sentence"
            case .glance: return "Glance: keyboard and back"
            case .pop: return "Pop: look at each bubble"
            case .firefly: return "Firefly: follow it"
            case .search: return "Search: find the odd letter"
            case .shift: return "Shift: lean while you watch the dot"
            }
        }
    }

    static let passage = "The glasses measure your head a thousand times a second. To keep these screens perfectly still, the app has to guess where your head will be about forty milliseconds from now, the time a picture takes to reach your eyes. Everyone's head moves a little differently: how you settle after a turn, how you sway while you read, how typing jolts you. This session records exactly that, so a model can be trained on how you move."
    static let sentence = "The quick brown fox jumps over the lazy dog while five wizards box quickly."

    // Hooks into the app.
    var showInstruction: (String?) -> Void = { _ in }
    var showAim: (SIMD2<Float>?, CGFloat, NSColor) -> Void = { _, _, _ in }
    var onFinish: (_ folder: URL?, _ completed: Bool) -> Void = { _, _ in }
    /// Test mode (`set calibrate=autopilot`): looks at every target by itself.
    var autopilot = false

    private var screens: [Screen]
    private let hid: GlassesHIDService
    private let folder: URL
    private var level: Level = .focus
    private var levelIndex = 0
    private enum Phase { case ready, running, done }
    private var phase = Phase.ready
    private var dwell = 0.0
    private var progress = 0.0
    private var levelStart: CFTimeInterval = 0
    private var doneAt: CFTimeInterval = 0
    private var lastTick: CFTimeInterval = 0
    private var lastKeyAt: CFTimeInterval = 0
    private var recordStart: CFTimeInterval?
    private var labels: [String] = []
    private var score = 0
    private var combo = 0
    private var lastHitAt: CFTimeInterval = 0
    private var rng = SystemRandomNumberGenerator()
    private var previousApp: NSRunningApplication?
    // Level state
    private var target = SIMD2<Float>(0, 0)          // degrees
    private var hitAt: CFTimeInterval?
    private var glanceDown = false
    private var glanceCount = 0
    private var glanceStart: CFTimeInterval = 0
    private var typed = ""
    private var searchGrid: (screen: Int, odd: Int, cols: Int, rows: Int, letter: Character, oddLetter: Character) = (0, 0, 7, 4, "O", "Q")
    private var onTargetTime = 0.0

    private static let popCount = 18, glanceRounds = 6, searchRounds = 7
    private static let levelSeconds: [Level: Double] = [.focus: 25, .talk: 20, .type: 25, .firefly: 32, .shift: 22]

    init(screens: [Screen], hid: GlassesHIDService) {
        self.screens = screens
        self.hid = hid
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                formatOptions: [.withYear, .withMonth, .withDay, .withTime])
        folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/XRealDesk/calibration-\(stamp)", isDirectory: true)
        for s in screens { s.window.view.onKey = { [weak self] e in self?.key(e) } }
    }

    // MARK: Start / stop

    func start() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        for s in screens { s.window.orderFrontRegardless() }
        home.window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.checkVisible() }
        Log.info("Tracking session started on \(screens.count) screen(s) → \(folder.path)")
        enter(0)
    }

    func cancel() { finish(completed: false) }

    /// A screen showing an app in full screen can't show these windows: leave it out.
    private func checkVisible() {
        for i in screens.indices where !screens[i].window.occlusionState.contains(.visible) {
            screens[i].visible = false
            screens[i].window.orderOut(nil)
            Log.info("Tracking session: screen \(screens[i].index + 1) is hidden (full screen app?), not used")
        }
        if !screens.contains(where: \.visible) {
            showInstruction("The session needs a glasses screen that isn't in full screen")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.cancel() }
        } else if !home.visible, let v = screens.first(where: \.visible) {
            v.window.makeKeyAndOrderFront(nil)
            showInstruction("The session is on screen \(v.index + 1): look there")
        }
    }

    /// The screen that shows text and the start dots (the one you faced, or the first visible).
    private var home: Screen { screens.first(where: \.visible) ?? screens[0] }
    private var usable: [Screen] { screens.filter(\.visible) }

    // MARK: Tick (60 Hz)

    /// - Parameters: gaze: where straight ahead meets a screen (index, UV); pitch: head pitch (degrees,
    ///   layout frame; down is negative); aim: where straight ahead appears in the glasses (0…1).
    func tick(now: CFTimeInterval, gaze realGaze: (Int, SIMD2<Float>)?, headPitch: Float, aim: SIMD2<Float>) {
        let dt = lastTick > 0 ? min(now - lastTick, 0.1) : 0
        lastTick = now
        var gaze = realGaze.flatMap { angle(screen: $0.0, uv: $0.1) }
        var pitch = headPitch
        if autopilot {
            gaze = phase == .ready ? startTarget : target
            if level == .glance, phase == .running { pitch = glanceDown ? 0 : -30; if !glanceDown { gaze = nil } }
            if level == .type, phase == .running { lastKeyAt = now }
        }
        switch phase {
        case .ready:
            let on = gaze.map { distance($0, startTarget) < 2.5 } ?? false
            dwell = on ? dwell + dt : max(0, dwell - dt * 2)
            draw(dots: [(startTarget, .active)])
            showAim(aim, CGFloat(dwell / 0.8), .systemBlue)
            if dwell >= 0.8 { begin(now) }
        case .running:
            let f = run(now: now, dt: dt, gaze: gaze, pitch: pitch, aim: aim)
            if f >= 1 { complete(now) }
        case .done:
            showAim(aim, 1, .systemGreen)
            if now - doneAt > 1.2 { enter(levelIndex + 1) }
        }
    }

    private var startTarget: SIMD2<Float> {
        switch level {
        case .focus, .talk, .type: return textDot
        case .firefly: return fireflyPoint(0)
        default: return homeCentre
        }
    }
    private var homeCentre: SIMD2<Float> { SIMD2(home.yaw, home.pitch) }
    private var textDot: SIMD2<Float> { SIMD2(home.yaw + home.width * 0.3, home.pitch + home.height * 0.25) }

    // MARK: Levels

    private func enter(_ i: Int) {
        levelIndex = i
        guard i < Level.allCases.count else { finish(completed: true); return }
        level = Level.allCases[i]
        phase = .ready; dwell = 0; progress = 0; hitAt = nil; onTargetTime = 0
        let n = Level.allCases.count
        setText(title: "\(i + 1) of \(n)  ·  \(level.title)", detail: intro(level) + "\n\nRest the ring on the blue dot to start.", body: nil)
        showInstruction("\(level.title): rest the ring on the blue dot")
    }

    private func intro(_ l: Level) -> String {
        switch l {
        case .focus: return "Read the passage at your normal pace. Keep your head relaxed."
        case .talk: return "Read the passage out loud, like you're on a call."
        case .type: return "Type the sentence shown. Your typing stays inside this session."
        case .glance: return "When asked, look down at your keyboard, then back at the dot. As fast as is comfortable."
        case .pop: return "Bubbles appear on all your screens. Look at each one to pop it. Quick pops build a combo."
        case .firefly: return "Follow the firefly with your eyes and head as it drifts across your screens. It speeds up."
        case .search: return "Find the one letter that's different and look at it."
        case .shift: return "Keep your eyes on the dot while you lean back, lean forward and shift in your chair."
        }
    }

    private func begin(_ now: CFTimeInterval) {
        phase = .running
        levelStart = now
        if recordStart == nil {
            hid.recordIMU(to: folder.appendingPathComponent("imu.csv"), seconds: 3600)
            recordStart = now
        }
        Self.sound("Tink")
        switch level {
        case .focus, .talk: setText(title: level.title, detail: "", body: Self.passage)
        case .type: typed = ""; setText(title: level.title, detail: "", body: Self.sentence + "\n\n▍")
        case .glance: glanceCount = 0; glanceDown = false; glanceStart = now; target = homeCentre
            setText(title: level.title, detail: "", body: nil); showInstruction("Look DOWN at your keyboard")
        case .pop: combo = 0; target = randomTarget(awayFrom: homeCentre); setText(title: level.title, detail: "", body: nil)
        case .firefly: setText(title: level.title, detail: "", body: nil)
        case .search: newGrid(); setText(title: level.title, detail: "", body: nil)
        case .shift: target = homeCentre; setText(title: level.title, detail: "", body: nil)
        }
        if level != .glance { showInstruction(level.title) }
    }

    /// One tick of the running level; returns progress (1 = done).
    private func run(now: CFTimeInterval, dt: Double, gaze: SIMD2<Float>?, pitch: Float, aim: SIMD2<Float>) -> Double {
        let t = now - levelStart
        func near(_ p: SIMD2<Float>, _ tol: Float) -> Bool { gaze.map { distance($0, p) < tol } ?? false }
        switch level {
        case .focus, .talk:
            let onText = gaze.map { g in usable.contains { s in abs(g.x - s.yaw) < s.width / 2 && abs(g.y - s.pitch) < s.height / 2 && s.index == home.index } } ?? false
            if onText { progress += dt }
            draw(dots: [])
            let total = Self.levelSeconds[level]!
            showAim(aim, CGFloat(progress / total), onText ? .systemGreen : .systemOrange)
            return progress / total
        case .type:
            if now - lastKeyAt < 1.2 { progress += dt }
            draw(dots: [])
            let total = Self.levelSeconds[.type]!
            showAim(aim, CGFloat(progress / total), now - lastKeyAt < 1.2 ? .systemGreen : .systemOrange)
            return progress / total
        case .glance:
            draw(dots: [(target, glanceDown ? .active : .idle)])
            if !glanceDown, pitch < -20 {
                glanceDown = true; Self.sound("Tink"); showInstruction("Now back to the dot")
            } else if glanceDown, near(target, 3) {
                glanceDown = false; glanceCount += 1
                let secs = now - glanceStart
                score += max(20, 200 - Int(secs * 60)); glanceStart = now
                Self.sound("Pop")
                if glanceCount < Self.glanceRounds { showInstruction(String(format: "%.1f s · look DOWN again", secs)) }
            }
            showAim(aim, CGFloat(Double(glanceCount) / Double(Self.glanceRounds)), .systemGreen)
            return Double(glanceCount) / Double(Self.glanceRounds)
        case .pop:
            if let h = hitAt {
                draw(dots: [(target, .done)])
                if now - h > 0.25 { hitAt = nil; target = randomTarget(awayFrom: target) }
            } else {
                if near(target, 2.5) { dwell += dt } else { dwell = 0 }
                draw(dots: [(target, .active)])
                if dwell >= 0.25 {
                    dwell = 0; hitAt = now; progress += 1
                    combo = now - lastHitAt < 1.6 ? combo + 1 : 1
                    lastHitAt = now
                    score += 100 * combo
                    Self.sound(combo >= 3 ? "Glass" : "Pop")
                    showInstruction(combo >= 2 ? "Combo ×\(combo)" : "Pop!")
                }
            }
            showAim(aim, CGFloat(progress / Double(Self.popCount)), .systemGreen)
            return progress / Double(Self.popCount)
        case .firefly:
            target = fireflyPoint(t)
            let on = near(target, 3.5)
            if on { onTargetTime += dt; score += Int(dt * 60) }
            draw(dots: [(target, on ? .done : .active)])
            let total = Self.levelSeconds[.firefly]!
            showAim(aim, CGFloat(t / total), on ? .systemGreen : .systemOrange)
            return t / total
        case .search:
            let odd = gridPoint(searchGrid.odd)
            if near(odd, 2) { dwell += dt } else { dwell = 0 }
            drawGrid()
            if dwell >= 0.4 {
                dwell = 0; progress += 1; score += 250
                Self.sound("Pop")
                if progress < Double(Self.searchRounds) { newGrid() }
            }
            showAim(aim, CGFloat(progress / Double(Self.searchRounds)), .systemGreen)
            return progress / Double(Self.searchRounds)
        case .shift:
            let steps = ["Lean BACK", "Lean FORWARD", "Shift in your chair", "Sit back and relax", "Lean to the LEFT", "Lean to the RIGHT"]
            let step = min(Int(t / 3.6), steps.count - 1)
            showInstruction(steps[step] + " · eyes on the dot")
            draw(dots: [(target, near(target, 4) ? .done : .active)])
            let total = Self.levelSeconds[.shift]!
            showAim(aim, CGFloat(t / total), .systemGreen)
            return t / total
        }
    }

    private func complete(_ now: CFTimeInterval) {
        if let r = recordStart {
            labels.append(String(format: "%@,%.3f,%.3f", level.label, max(0, levelStart - r), now - r))
        }
        phase = .done
        doneAt = now
        Self.sound("Hero")
        showInstruction("\(level.title) ✓   ·   score \(score)")
        setText(title: "✓  \(level.title)", detail: "Score \(score)", body: nil)
        draw(dots: [])
    }

    private func finish(completed: Bool) {
        if recordStart != nil { hid.stopIMURecording() }
        if !labels.isEmpty {
            try? ("label,start_s,end_s\n" + labels.joined(separator: "\n") + "\n")
                .write(to: folder.appendingPathComponent("labels.csv"), atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: folder)
        }
        showAim(nil, 0, .clear)
        showInstruction(nil)
        for s in screens { s.window.orderOut(nil) }
        if let app = previousApp, app != NSRunningApplication.current { app.activate() }
        Log.info("Tracking session \(completed ? "finished" : "stopped"): \(labels.count) levels recorded, score \(score)")
        onFinish(labels.isEmpty ? nil : folder, completed)
    }

    // MARK: Keys

    private func key(_ e: NSEvent) {
        let now = CACurrentMediaTime()
        lastKeyAt = now
        if e.keyCode == 53 { cancel(); return }                       // Esc
        if level == .type, phase == .running {
            if e.keyCode == 51 { if !typed.isEmpty { typed.removeLast() } }   // delete
            else if let c = e.characters { typed += c }
            setText(title: level.title, detail: "", body: Self.sentence + "\n\n" + typed + "▍")
            return
        }
        if e.charactersIgnoringModifiers == " " {                     // Space skips
            if phase == .running { complete(now) } else if phase == .ready { enter(levelIndex + 1) }
        }
    }

    // MARK: Geometry (degrees; yaw + = left, pitch + = up)

    private func angle(screen: Int, uv: SIMD2<Float>) -> SIMD2<Float>? {
        guard let s = screens.first(where: { $0.index == screen }) else { return nil }
        return SIMD2(s.yaw - (uv.x - 0.5) * s.width, s.pitch - (uv.y - 0.5) * s.height)
    }

    private func place(_ a: SIMD2<Float>) -> (Screen, SIMD2<Float>)? {
        for s in usable {
            let u = 0.5 - (a.x - s.yaw) / s.width, v = 0.5 - (a.y - s.pitch) / s.height
            if u >= 0, u <= 1, v >= 0, v <= 1 { return (s, SIMD2(u, v)) }
        }
        return nil
    }

    private func distance(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { simd_length(a - b) }

    private func randomTarget(awayFrom last: SIMD2<Float>) -> SIMD2<Float> {
        let pool = usable
        for _ in 0..<60 {
            let s = pool.randomElement(using: &rng)!
            let uv = SIMD2(Float.random(in: 0.12...0.88, using: &rng), Float.random(in: 0.18...0.82, using: &rng))
            let a = SIMD2(s.yaw - (uv.x - 0.5) * s.width, s.pitch - (uv.y - 0.5) * s.height)
            let d = distance(a, last)
            if d > 8 && d < 45 { return a }
        }
        return homeCentre
    }

    /// Drifts across every screen, speeding up over the level.
    private func fireflyPoint(_ t: Double) -> SIMD2<Float> {
        let pool = usable
        let yaws = pool.flatMap { [$0.yaw - $0.width * 0.42, $0.yaw + $0.width * 0.42] }
        let pitches = pool.flatMap { [$0.pitch - $0.height * 0.35, $0.pitch + $0.height * 0.35] }
        let cy = ((yaws.min() ?? 0) + (yaws.max() ?? 0)) / 2, ay = ((yaws.max() ?? 0) - (yaws.min() ?? 0)) / 2
        let cp = ((pitches.min() ?? 0) + (pitches.max() ?? 0)) / 2, ap = ((pitches.max() ?? 0) - (pitches.min() ?? 0)) / 2
        // Phase grows faster over time (speed ramps from gentle to brisk).
        let phase = 2 * Double.pi * (t / 9 + t * t / 900)
        return SIMD2(cy + ay * Float(sin(phase)), cp + ap * Float(sin(phase * 1.7 + 0.6)))
    }

    private func newGrid() {
        let pool = usable
        let s = pool.randomElement(using: &rng)!
        let pairs: [(Character, Character)] = [("O", "Q"), ("E", "F"), ("P", "R"), ("C", "G"), ("I", "l"), ("M", "N"), ("b", "d")]
        let p = pairs.randomElement(using: &rng)!
        searchGrid = (s.index, Int.random(in: 0..<28, using: &rng), 7, 4, p.0, p.1)
    }

    private func gridPoint(_ k: Int) -> SIMD2<Float> {
        guard let s = screens.first(where: { $0.index == searchGrid.screen }) else { return homeCentre }
        let c = k % searchGrid.cols, r = k / searchGrid.cols
        let uv = SIMD2(0.14 + Float(c) * 0.72 / Float(searchGrid.cols - 1), 0.25 + Float(r) * 0.5 / Float(searchGrid.rows - 1))
        return SIMD2(s.yaw - (uv.x - 0.5) * s.width, s.pitch - (uv.y - 0.5) * s.height)
    }

    // MARK: Drawing

    private func draw(dots: [(SIMD2<Float>, SessionView.DotState)]) {
        for s in screens where s.visible {
            let mine = dots.compactMap { d -> (SIMD2<Float>, SessionView.DotState)? in
                guard let (ps, uv) = place(d.0), ps.index == s.index else { return nil }
                return (uv, d.1)
            }
            s.window.view.show(dots: mine, grid: nil, score: score)
        }
    }

    private func drawGrid() {
        for s in screens where s.visible {
            if s.index == searchGrid.screen {
                var cells: [(SIMD2<Float>, Character)] = []
                for k in 0..<(searchGrid.cols * searchGrid.rows) {
                    let c = k % searchGrid.cols, r = k / searchGrid.cols
                    let uv = SIMD2(0.14 + Float(c) * 0.72 / Float(searchGrid.cols - 1), 0.25 + Float(r) * 0.5 / Float(searchGrid.rows - 1))
                    cells.append((uv, k == searchGrid.odd ? searchGrid.oddLetter : searchGrid.letter))
                }
                s.window.view.show(dots: [], grid: cells, score: score)
            } else {
                s.window.view.show(dots: [], grid: nil, score: score)
            }
        }
    }

    private func setText(title: String, detail: String, body: String?) {
        for s in screens where s.visible {
            if s.index == home.index { s.window.view.set(title: title, detail: detail, body: body) }
            else { s.window.view.set(title: title, detail: "", body: nil) }
        }
    }

    private static func sound(_ name: String) { NSSound(named: NSSound.Name(name))?.play() }
}

// MARK: - Window and view

/// Borderless window covering one glasses screen, above everything (also full-screen apps' menus).
final class SessionWindow: NSWindow {
    let view: SessionView
    init(screen: NSScreen) {
        view = SessionView(frame: NSRect(origin: .zero, size: screen.frame.size))
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

final class SessionView: NSView {
    enum DotState { case idle, active, done }
    var onKey: ((NSEvent) -> Void)?

    private var dotLayers: [CAShapeLayer] = []
    private var gridLayers: [CATextLayer] = []
    private let titleLayer = CATextLayer(), detailLayer = CATextLayer(), bodyLayer = CATextLayer(), scoreLayer = CATextLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 1).cgColor
        for (l, size, weight, alpha) in [(titleLayer, CGFloat(30), NSFont.Weight.semibold, CGFloat(1)), (detailLayer, 20, .regular, 0.75),
                                          (bodyLayer, 26, .regular, 0.92), (scoreLayer, 22, .semibold, 0.85)] {
            l.font = NSFont.systemFont(ofSize: size, weight: weight); l.fontSize = size
            l.foregroundColor = NSColor(white: 1, alpha: alpha).cgColor
            l.alignmentMode = l === bodyLayer ? .left : .center
            l.isWrapped = true; l.contentsScale = 2
            layer?.addSublayer(l)
        }
        scoreLayer.alignmentMode = .right
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { onKey?(event) }

    func set(title: String, detail: String, body: String?) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let w = bounds.width * 0.72, x = (bounds.width - w) / 2
        titleLayer.string = title
        titleLayer.frame = CGRect(x: x, y: bounds.height - 80, width: w, height: 44)
        detailLayer.string = detail
        detailLayer.frame = CGRect(x: x, y: 40, width: w, height: bounds.height * 0.2)
        bodyLayer.string = body
        bodyLayer.frame = CGRect(x: x, y: bounds.height * 0.18, width: w, height: bounds.height * 0.62)
        scoreLayer.frame = CGRect(x: bounds.width - 260, y: bounds.height - 76, width: 230, height: 36)
        CATransaction.commit()
    }

    private func point(_ uv: SIMD2<Float>) -> CGPoint { CGPoint(x: CGFloat(uv.x) * bounds.width, y: (1 - CGFloat(uv.y)) * bounds.height) }

    func show(dots: [(SIMD2<Float>, DotState)], grid: [(SIMD2<Float>, Character)]?, score: Int) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        scoreLayer.string = score > 0 ? "\(score) pts" : ""
        while dotLayers.count < dots.count {
            let l = CAShapeLayer()
            l.path = CGPath(ellipseIn: CGRect(x: -16, y: -16, width: 32, height: 32), transform: nil)
            l.lineWidth = 3
            layer?.addSublayer(l); dotLayers.append(l)
        }
        for (i, l) in dotLayers.enumerated() {
            guard i < dots.count else { l.isHidden = true; continue }
            l.isHidden = false
            l.position = point(dots[i].0)
            switch dots[i].1 {
            case .idle: l.fillColor = NSColor(white: 1, alpha: 0.15).cgColor; l.strokeColor = NSColor(white: 1, alpha: 0.5).cgColor
            case .active: l.fillColor = NSColor.systemBlue.cgColor; l.strokeColor = NSColor.white.cgColor
            case .done: l.fillColor = NSColor.systemGreen.cgColor; l.strokeColor = NSColor.white.cgColor
            }
        }
        let cells = grid ?? []
        while gridLayers.count < cells.count {
            let t = CATextLayer()
            t.fontSize = 44; t.font = NSFont.monospacedSystemFont(ofSize: 44, weight: .medium)
            t.foregroundColor = NSColor.white.cgColor; t.alignmentMode = .center; t.contentsScale = 2
            layer?.addSublayer(t); gridLayers.append(t)
        }
        for (i, t) in gridLayers.enumerated() {
            guard i < cells.count else { t.isHidden = true; continue }
            t.isHidden = false
            t.string = String(cells[i].1)
            let p = point(cells[i].0)
            t.frame = CGRect(x: p.x - 30, y: p.y - 30, width: 60, height: 60)
        }
        CATransaction.commit()
    }
}
