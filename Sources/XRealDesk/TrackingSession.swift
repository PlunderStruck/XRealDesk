import AppKit
import QuartzCore
import simd
import XRCore

/// A guided tracking session: one ~14-minute take of game "levels" that produce
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
        case focus, talk, type, glance, pop, firefly, search, shift, finale
        var label: String { "\(self)" }
        var title: String {
            switch self {
            case .focus: return "Focus: read the passage"
            case .talk: return "Talk: read it aloud"
            case .type: return "Type: copy the sentence"
            case .glance: return "Glance: keyboard and back"
            case .pop: return "Pop: look at each bubble"
            case .firefly: return "Firefly: follow it"
            case .search: return "Search: find the square"
            case .shift: return "Shift: lean while you watch the dot"
            case .finale: return "Encore: everything, faster"
            }
        }
    }

    static let passage = """
    The glasses measure your head a thousand times a second. To keep these screens perfectly still, the app has to guess where your head will be about forty milliseconds from now, the time a picture takes to reach your eyes. Everyone's head moves a little differently: how you settle after a turn, how you sway while you read, how typing jolts you. This session records exactly that, so a model can learn how you move.

    Read on at your own pace. Nothing here is a test of reading: the point is simply to look the way you normally look while you read. Your eyes jump along each line and back to the start of the next; your head follows a little, and settles. Your pulse moves it too, by a hair, about once a second. When you talk, your jaw rocks the glasses gently. Each of these movements is tiny, but the screens have to cancel all of them, which is why they're worth learning. When you reach the end, start again from the top.
    """
    static let sentences = ["The quick brown fox jumps over the lazy dog.", "Five wizards box quickly while jumping frogs vex the judge.",
                            "Pack my box with five dozen liquor jugs.", "How vexingly quick daft zebras jump over logs.",
                            "Sphinx of black quartz, judge my vow and type it twice."]

    // Hooks into the app.
    var showInstruction: (String?) -> Void = { _ in }
    var showAim: (SIMD2<Float>?, CGFloat, NSColor) -> Void = { _, _, _ in }
    /// Draws world-locked shapes in the glasses (and hides the screens while `hide` is set).
    var setOverlay: ([RendererShaders.OverlayItem], _ hide: Bool) -> Void = { _, _ in }
    /// Viewing angle (degrees) → point on the screens' surface (metres), and metres per degree there.
    var surface: (SIMD2<Float>) -> SIMD2<Float>? = { _ in nil }
    var metresPerDegree: Float = 0.026
    var onFinish: (_ folder: URL?, _ completed: Bool) -> Void = { _, _ in }
    /// Head-locked progress in the glasses: overall fraction and "about N min left".
    var showProgress: (Double?, String) -> Void = { _, _ in }
    /// T at the end: train a model from this session right away.
    var onTrainRequested: () -> Void = {}
    /// Test mode (`set calibrate=autopilot`): looks at every target by itself.
    var autopilot = false

    private var screens: [Screen]
    private let hid: GlassesHIDService
    private let folder: URL
    private var level: Level = .focus
    private var levelIndex = 0
    private enum Phase { case ready, running, done, summary }
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
    private var sentenceIndex = 0
    private var finaleSegment = -1
    private var summaryAt: CFTimeInterval = 0
    private var searchGrid: (screen: Int, odd: Int, cols: Int, rows: Int, letter: Character, oddLetter: Character) = (0, 0, 7, 4, "O", "Q")
    private var onTargetTime = 0.0

    /// Monitor arrangements the target levels use, drawn world-locked in the glasses (degrees):
    /// they span far more head movement than one screen, whatever the wearer's own layout.
    struct Frame { var centre: SIMD2<Float>; var half: SIMD2<Float> }
    static let arrangements: [String: [Frame]] = [
        "wide": [Frame(centre: SIMD2(16, 0), half: SIMD2(15, 8.4)), Frame(centre: SIMD2(-16, 0), half: SIMD2(15, 8.4))],
        "ultra": [Frame(centre: SIMD2(28, 0), half: SIMD2(13, 7.3)), Frame(centre: SIMD2(0, 0), half: SIMD2(13, 7.3)),
                  Frame(centre: SIMD2(-28, 0), half: SIMD2(13, 7.3))],
        "stack": [Frame(centre: SIMD2(15, 9), half: SIMD2(14, 7.9)), Frame(centre: SIMD2(-15, 9), half: SIMD2(14, 7.9)),
                  Frame(centre: SIMD2(15, -9), half: SIMD2(14, 7.9)), Frame(centre: SIMD2(-15, -9), half: SIMD2(14, 7.9))],
        "column": [Frame(centre: SIMD2(0, 9.5), half: SIMD2(15, 8.4)), Frame(centre: SIMD2(0, -9.5), half: SIMD2(15, 8.4))],
    ]
    private var frames: [Frame] = []

    static let arrangementCycle = ["wide", "stack", "ultra", "column"]

    /// Which arrangement a level uses; `step` is the level's own counter (bubbles popped, rounds
    /// found, seconds elapsed or encore segment), so arrangements rotate within a level.
    private func arrangement(_ l: Level, progress step: Double) -> String {
        switch l {
        case .glance: return "column"
        case .pop: return Self.arrangementCycle[min(3, Int(step / 11))]
        case .firefly: return step < 45 ? "ultra" : "stack"
        case .search: return Int(step) % 2 == 0 ? "stack" : "ultra"
        case .shift: return "wide"
        case .finale: return Self.arrangementCycle[Int(step) % 4]
        case .focus, .talk, .type: return ""
        }
    }
    private var usesOverlay: Bool { !arrangement(level, progress: 0).isEmpty }

    private static let popCount = 44, glanceRounds = 10, searchRounds = 15
    private static let levelSeconds: [Level: Double] = [.focus: 60, .talk: 60, .type: 75, .firefly: 90, .shift: 45, .finale: 180]
    /// Rough length of each level (incl. getting ready), for the progress bar and time left.
    private static let estimate: [Level: Double] = [.focus: 64, .talk: 64, .type: 79, .glance: 65, .pop: 118, .firefly: 94,
                                                    .search: 95, .shift: 49, .finale: 184]
    private static var totalEstimate: Double { Level.allCases.reduce(0) { $0 + (estimate[$1] ?? 60) } }

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

    /// - Parameter fresh: start from level 1 even if a stopped session could be picked up.
    func start(fresh: Bool = false) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        for s in screens { s.window.orderFrontRegardless() }
        home.window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.checkVisible() }
        Log.info("Tracking session started on \(screens.count) screen(s) → \(folder.path)")
        if !fresh, let r = Self.savedResume() {
            score = r.score
            enter(r.level)
            Log.info("Tracking session: picking up at level \(r.level + 1)")
        } else {
            Self.clearResume()
            enter(0)
        }
    }

    // MARK: Resume

    /// Where a stopped session picks up next time: the first unfinished level and the score so far.
    /// (Each sitting records its own folder; training uses them all.)
    struct Resume: Codable { var level: Int; var score: Int; var savedAt: Date }
    private static var resumeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/XRealDesk/session-resume.json")
    }
    static func savedResume() -> Resume? {
        guard let data = try? Data(contentsOf: resumeURL), let r = try? JSONDecoder().decode(Resume.self, from: data),
              r.level > 0, r.level < Level.allCases.count, Date().timeIntervalSince(r.savedAt) < 14 * 86400 else { return nil }
        return r
    }
    static func clearResume() { try? FileManager.default.removeItem(at: resumeURL) }
    private func saveResume(level: Int) {
        guard level < Level.allCases.count else { Self.clearResume(); return }
        if let data = try? JSONEncoder().encode(Resume(level: level, score: score, savedAt: Date())) {
            try? data.write(to: Self.resumeURL, options: .atomic)
        }
    }

    private func writeLabels() {
        try? ("label,start_s,end_s\n" + labels.joined(separator: "\n") + "\n")
            .write(to: folder.appendingPathComponent("labels.csv"), atomically: true, encoding: .utf8)
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

    /// - Parameters: gaze: where you're looking (degrees, layout frame: yaw + = left, pitch + = up);
    ///   aim: where straight ahead appears in the glasses (0…1).
    func tick(now: CFTimeInterval, gaze realGaze: SIMD2<Float>?, headPitch: Float, aim: SIMD2<Float>) {
        let dt = lastTick > 0 ? min(now - lastTick, 0.1) : 0
        lastTick = now
        var gaze = realGaze
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
        case .summary:
            if now - summaryAt > 10 { finish(completed: true); return }
        }
        updateProgress(now)
    }

    /// Overall progress and time left, from each level's rough length.
    private func updateProgress(_ now: CFTimeInterval) {
        guard phase != .summary else { return }
        let levels = Level.allCases
        var done = 0.0
        for l in levels.prefix(levelIndex) { done += Self.estimate[l] ?? 60 }
        let here = Self.estimate[level] ?? 60
        let fraction: Double
        switch phase {
        case .ready: fraction = 0
        case .running: fraction = min(levelFraction(now), 1)
        default: fraction = 1
        }
        let total = Self.totalEstimate
        let elapsed = done + fraction * here
        let left = max(0, total - elapsed)
        let text = left > 90 ? String(format: "about %.0f min left", (left / 60).rounded()) : left > 20 ? "about a minute left" : "almost done"
        showProgress(elapsed / total, "Level \(levelIndex + 1) of \(levels.count)  ·  \(text)  ·  \(score) pts")
    }

    private func levelFraction(_ now: CFTimeInterval) -> Double {
        switch level {
        case .glance: return Double(glanceCount) / Double(Self.glanceRounds)
        case .pop: return progress / Double(Self.popCount)
        case .search: return progress / Double(Self.searchRounds)
        case .focus, .talk, .type: return progress / (Self.levelSeconds[level] ?? 60)
        default: return (now - levelStart) / (Self.levelSeconds[level] ?? 60)
        }
    }

    private var startTarget: SIMD2<Float> {
        switch level {
        case .focus, .talk, .type: return textDot
        case .firefly: return fireflyPoint(0)
        default: return SIMD2(0, 0)
        }
    }
    private var homeCentre: SIMD2<Float> { SIMD2(home.yaw, home.pitch) }
    private var textDot: SIMD2<Float> { SIMD2(home.yaw + home.width * 0.3, home.pitch + home.height * 0.25) }

    // MARK: Levels

    private func enter(_ i: Int) {
        levelIndex = i
        guard i < Level.allCases.count else { showSummary(); return }
        level = Level.allCases[i]
        phase = .ready; dwell = 0; progress = 0; hitAt = nil; onTargetTime = 0
        frames = Self.arrangements[arrangement(level, progress: 0)] ?? []
        let n = Level.allCases.count
        setText(title: "\(i + 1) of \(n)  ·  \(level.title)", detail: intro(level) + (level == .type ? "\n\nStart typing, or rest the ring on the blue dot, to begin." : "\n\nRest the ring on the blue dot to start.")
                + "\n→ skips a level  ·  Esc stops (next time picks up here)", body: nil)
        showInstruction("\(level.title): rest the ring on the blue dot")
    }

    private func intro(_ l: Level) -> String {
        switch l {
        case .focus: return "Read the passage at your normal pace. Keep your head relaxed."
        case .talk: return "Read the passage out loud, like you're on a call."
        case .type: return "Type the sentence shown. Your typing stays inside this session."
        case .glance: return "Tip your head down to look at your keyboard, then back up at the dot, 10 times. Each time you're down you'll hear a tick."
        case .pop: return "Bubbles appear on all your screens. Look at each one to pop it. Quick pops build a combo."
        case .firefly: return "Follow the firefly with your eyes and head as it drifts across your screens. It speeds up."
        case .search: return "Among the circles there's one square. Find it and look at it."
        case .shift: return "Keep your eyes on the dot while you lean back, lean forward and shift in your chair."
        case .finale: return "Bubbles and fireflies take turns in every arrangement, faster and faster. Points count double."
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
        case .type: typed = ""; sentenceIndex = 0; showTyping()
        case .glance: glanceCount = 0; glanceDown = false; glanceStart = now; target = SIMD2(0, 0)
            setText(title: level.title, detail: "", body: nil); showInstruction("↓ Look DOWN at your keyboard ↓")
        case .pop: combo = 0; target = randomTarget(awayFrom: SIMD2(0, 0)); setText(title: level.title, detail: "", body: nil)
        case .firefly: setText(title: level.title, detail: "", body: nil)
        case .search: newGrid(); setText(title: level.title, detail: "", body: nil)
        case .shift: target = SIMD2(0, 0); setText(title: level.title, detail: "", body: nil)
        case .finale: finaleSegment = -1; combo = 0; setText(title: level.title, detail: "", body: nil)
        }
        if level != .glance { showInstruction(level.title) }
    }

    /// One tick of the running level; returns progress (1 = done).
    private func run(now: CFTimeInterval, dt: Double, gaze: SIMD2<Float>?, pitch: Float, aim: SIMD2<Float>) -> Double {
        let t = now - levelStart
        func near(_ p: SIMD2<Float>, _ tol: Float) -> Bool { gaze.map { distance($0, p) < tol } ?? false }
        switch level {
        case .focus, .talk:
            let onText = gaze.map { g in abs(g.x - home.yaw) < home.width / 2 && abs(g.y - home.pitch) < home.height / 2 } ?? false
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
            if !glanceDown, pitch < target.y - 12 {
                glanceDown = true; Self.sound("Tink"); showInstruction("Now back to the dot")
            } else if glanceDown, near(target, 3) {
                glanceDown = false; glanceCount += 1
                let secs = now - glanceStart
                score += max(20, 200 - Int(secs * 60)); glanceStart = now
                Self.sound("Pop")
                if glanceCount < Self.glanceRounds { showInstruction(String(format: "%.1f s  ·  ↓ look DOWN again (%d of %d done)", secs, glanceCount, Self.glanceRounds)) }
            }
            showAim(aim, CGFloat(Double(glanceCount) / Double(Self.glanceRounds)), .systemGreen)
            return Double(glanceCount) / Double(Self.glanceRounds)
        case .pop:
            if popStep(now: now, dt: dt, near: near, multiplier: 1, dwellNeeded: 0.25) {
                frames = Self.arrangements[arrangement(.pop, progress: progress)] ?? frames
            }
            showAim(aim, CGFloat(progress / Double(Self.popCount)), .systemGreen)
            return progress / Double(Self.popCount)
        case .finale:
            let segment = Int(t / 20)
            if segment != finaleSegment {
                finaleSegment = segment
                frames = Self.arrangements[arrangement(.finale, progress: Double(segment))] ?? frames
                target = randomTarget(awayFrom: target); hitAt = nil; dwell = 0
                Self.sound("Purr")
                showInstruction(segment % 2 == 0 ? "Pop them, fast! ×2" : "Follow the firefly! ×2")
            }
            if segment % 2 == 0 {
                _ = popStep(now: now, dt: dt, near: near, multiplier: 2, dwellNeeded: 0.2)
            } else {
                target = fireflyPoint(t * (1.2 + Double(segment) * 0.08))
                let on = near(target, 3.5)
                if on { score += Int(dt * 120) }
                draw(dots: [(target, on ? .done : .active)])
            }
            let total = Self.levelSeconds[.finale]!
            showAim(aim, CGFloat(t / total), .systemGreen)
            return t / total
        case .firefly:
            let wanted = arrangement(.firefly, progress: t)
            if let f = Self.arrangements[wanted], f.count != frames.count || f.first?.centre != frames.first?.centre {
                frames = f; Self.sound("Purr"); showInstruction("It's moving to a new arrangement")
            }
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
                if progress < Double(Self.searchRounds) {
                    frames = Self.arrangements[arrangement(.search, progress: progress)] ?? frames
                    newGrid()
                }
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

    /// One tick of popping; returns true when a bubble was just popped (a new one follows shortly).
    private func popStep(now: CFTimeInterval, dt: Double, near: (SIMD2<Float>, Float) -> Bool, multiplier: Int, dwellNeeded: Double) -> Bool {
        if let h = hitAt {
            draw(dots: [(target, .done)])
            if now - h > 0.25 { hitAt = nil; target = randomTarget(awayFrom: target) }
            return false
        }
        if near(target, 2.5) { dwell += dt } else { dwell = 0 }
        draw(dots: [(target, .active)])
        guard dwell >= dwellNeeded else { return false }
        dwell = 0; hitAt = now; progress += 1
        combo = now - lastHitAt < 1.6 ? combo + 1 : 1
        lastHitAt = now
        score += 100 * combo * multiplier
        Self.sound(combo >= 3 ? "Glass" : "Pop")
        showInstruction(combo >= 2 ? "Combo ×\(combo)" : "Pop!")
        return true
    }

    private func showTyping() {
        let s = Self.sentences[sentenceIndex % Self.sentences.count]
        setText(title: level.title, detail: "", body: s + "\n\n" + typed + "▍")
    }

    /// End of the session: the score, and T to train right away (otherwise it closes by itself).
    private func showSummary() {
        Self.clearResume()
        phase = .summary
        summaryAt = CACurrentMediaTime()
        setOverlay([], false)
        showProgress(1, "Session complete  ·  \(score) pts")
        Self.sound("Hero")
        setText(title: "Session complete  ·  \(score) points",
                detail: "Press T to train your tracking model now, or do it later in Settings. Any other key closes this.",
                body: nil)
        showInstruction("Done! \(score) pts  ·  press T to train your model now")
    }

    private func complete(_ now: CFTimeInterval) {
        if let r = recordStart {
            labels.append(String(format: "%@,%.3f,%.3f", level.label, max(0, levelStart - r), now - r))
            writeLabels()
        }
        saveResume(level: levelIndex + 1)
        phase = .done
        doneAt = now
        Self.sound("Hero")
        showInstruction("\(level.title) ✓   ·   score \(score)")
        setText(title: "✓  \(level.title)", detail: "Score \(score)", body: nil)
        draw(dots: [])
    }

    private func finish(completed: Bool) {
        // A level stopped partway still has useful motion in it (it's done again on resume).
        let now = CACurrentMediaTime()
        if phase == .running, let r = recordStart, now - levelStart > 10 {
            labels.append(String(format: "%@,%.3f,%.3f", level.label, max(0, levelStart - r), now - r))
        }
        if recordStart != nil { hid.stopIMURecording() }
        if !labels.isEmpty {
            writeLabels()
        } else {
            try? FileManager.default.removeItem(at: folder)
        }
        showAim(nil, 0, .clear)
        showInstruction(nil)
        showProgress(nil, "")
        setOverlay([], false)
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
        if e.keyCode == 124 {                                         // → skips a level
            if phase == .running { complete(now) } else if phase == .ready { enter(levelIndex + 1) }
            return
        }
        if phase == .summary {
            let train = e.charactersIgnoringModifiers?.lowercased() == "t"
            finish(completed: true)
            if train { onTrainRequested() }
            return
        }
        let printable = e.characters.map { c in !c.isEmpty && c.unicodeScalars.allSatisfy { $0.value >= 32 && !(0xF700...0xF8FF).contains($0.value) } } ?? false
        if level == .type, phase == .ready, printable { begin(now) }   // typing starts the typing level
        if level == .type, phase == .running {
            if e.keyCode == 51 { if !typed.isEmpty { typed.removeLast() } }   // delete
            else if e.keyCode == 36 || e.keyCode == 76 { typed = ""; sentenceIndex += 1 }   // return: next sentence
            else if printable, let c = e.characters { typed += c }
            let s = Self.sentences[sentenceIndex % Self.sentences.count]
            if typed.count >= s.count { typed = ""; sentenceIndex += 1; score += 150; Self.sound("Pop") }
            showTyping()
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
        guard !frames.isEmpty else { return SIMD2(0, 0) }
        for _ in 0..<60 {
            let f = frames.randomElement(using: &rng)!
            let a = f.centre + f.half * SIMD2(Float.random(in: -0.8...0.8, using: &rng), Float.random(in: -0.75...0.75, using: &rng))
            let d = distance(a, last)
            if d > 8 && d < 50 { return a }
        }
        return frames[0].centre
    }

    /// Drifts across the whole arrangement, speeding up over the level.
    private func fireflyPoint(_ t: Double) -> SIMD2<Float> {
        let fs = frames.isEmpty ? Self.arrangements["ultra"]! : frames
        let lo = fs.map { $0.centre - $0.half * 0.85 }.reduce(SIMD2(repeating: .infinity)) { simd_min($0, $1) }
        let hi = fs.map { $0.centre + $0.half * 0.85 }.reduce(SIMD2(repeating: -.infinity)) { simd_max($0, $1) }
        let c = (lo + hi) / 2, amp = (hi - lo) / 2
        let phase = 2 * Double.pi * (t / 9 + t * t / 900)
        return SIMD2(c.x + amp.x * Float(sin(phase)), c.y + amp.y * Float(sin(phase * 1.7 + 0.6)))
    }

    private func newGrid() {
        let pick = Int.random(in: 0..<max(frames.count, 1), using: &rng)
        searchGrid = (pick, Int.random(in: 0..<18, using: &rng), 6, 3, "O", "Q")
    }

    private func gridPoint(_ k: Int) -> SIMD2<Float> {
        guard searchGrid.screen < frames.count else { return SIMD2(0, 0) }
        let f = frames[searchGrid.screen]
        let c = k % searchGrid.cols, r = k / searchGrid.cols
        let x = -0.75 + Float(c) * 1.5 / Float(searchGrid.cols - 1), y = 0.6 - Float(r) * 1.2 / Float(searchGrid.rows - 1)
        return f.centre + f.half * SIMD2(x, y)
    }

    // MARK: Drawing

    private func draw(dots: [(SIMD2<Float>, SessionView.DotState)]) {
        // Getting ready: the screens stay up (they show how to play) with just the start dot on top.
        let hide = usesOverlay && phase != .ready
        guard hide || phase == .ready && !dots.isEmpty else { setOverlay([], false); return }
        var items: [RendererShaders.OverlayItem] = []
        let m = metresPerDegree
        if hide {
            for f in frames {
                if let c = surface(f.centre) {
                    items.append(.frame(c, halfSize: f.half * m, line: 0.15 * m, color: SIMD4(0.22, 0.28, 0.42, 1)))
                }
            }
        }
        for (a, state) in dots {
            guard let c = surface(a) else { continue }
            let fill: SIMD4<Float> = state == .done ? SIMD4(0.10, 0.75, 0.25, 1) : state == .active ? SIMD4(0.05, 0.35, 1, 1) : SIMD4(0.3, 0.3, 0.3, 1)
            items.append(.circle(c, radius: 0.95 * m, color: SIMD4(1, 1, 1, 1)))
            items.append(.circle(c, radius: 0.78 * m, color: fill))
        }
        setOverlay(items, hide)
        if !hide { for s in screens where s.visible { s.window.view.show(dots: [], grid: nil, score: score) } }
    }

    private func drawGrid() {
        var items: [RendererShaders.OverlayItem] = []
        let m = metresPerDegree
        for f in frames { if let c = surface(f.centre) { items.append(.frame(c, halfSize: f.half * m, line: 0.15 * m, color: SIMD4(0.22, 0.28, 0.42, 1))) } }
        for k in 0..<(searchGrid.cols * searchGrid.rows) {
            guard let c = surface(gridPoint(k)) else { continue }
            let col = SIMD4<Float>(0.85, 0.85, 0.9, 1)
            items.append(k == searchGrid.odd ? .square(c, halfSize: 0.62 * m, color: col) : .circle(c, radius: 0.7 * m, color: col))
        }
        setOverlay(items, true)
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
