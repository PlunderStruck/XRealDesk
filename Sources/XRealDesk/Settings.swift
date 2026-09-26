import Foundation
import CoreGraphics
import Combine
import XRCore

extension ScreenPlacement {
    var title: String {
        switch self {
        case .above: return "Above laptop"
        case .below: return "Below laptop"
        case .left: return "Left of laptop"
        case .right: return "Right of laptop"
        case .custom: return "Custom"
        }
    }
}

enum TrackingMode: String, CaseIterable, Identifiable {
    /// Screens stay fixed in space; turn your head to look between them.
    case anchored
    /// Anchored for normal head movement; a quick flick drags the screens along, and looking past
    /// the outermost screen pushes them into view.
    case smart
    /// The focused screen glides after your head with a slight lag (walking, lying down).
    case smoothFollow
    /// Screens are glued to your view (like plain mirroring).
    case headLocked
    var id: String { rawValue }
    var title: String {
        switch self {
        case .anchored: return "Anchored"
        case .smart: return "Smart"
        case .smoothFollow: return "Follow"
        case .headLocked: return "Locked"
        }
    }
    var detail: String {
        switch self {
        case .anchored: return "Screens stay put. Turn your head to look around."
        case .smart: return "Look around the whole group freely. Look past its edge on any side and it glides after you."
        case .smoothFollow: return "The screen in front of you glides after your head. ⌃⌥←/→ switches screens."
        case .headLocked: return "Screens move with your head. Use ⌃⌥←/→ to switch screens."
        }
    }
}

struct ResolutionPreset: Hashable, Identifiable {
    let width: Int
    let height: Int
    var id: String { "\(width)x\(height)" }
    var aspect: Float { Float(width) / Float(height) }
    var title: String {
        let ratio: String
        switch Double(width) / Double(height) {
        case 1.7...1.8: ratio = "16:9"
        case 1.55...1.65: ratio = "16:10"
        case 2.3...2.45: ratio = "21:9"
        case 3.5...3.6: ratio = "32:9"
        default: ratio = ""
        }
        return "\(width) × \(height)" + (ratio.isEmpty ? "" : "  (\(ratio))")
    }

    static let all: [ResolutionPreset] = [
        .init(width: 1280, height: 720),
        .init(width: 1600, height: 900),
        .init(width: 1920, height: 1080),
        .init(width: 2560, height: 1440),
        .init(width: 1920, height: 1200),
        .init(width: 2560, height: 1080),
        .init(width: 3440, height: 1440),
        .init(width: 3840, height: 1080),
    ]
    /// 1600 px across ~33° is 1:1 with the Air 2 Pro's ~49 px/degree: the sharpest default.
    static let `default` = ResolutionPreset(width: 1600, height: 900)

    static func from(id: String) -> ResolutionPreset {
        all.first { $0.id == id } ?? .default
    }
}

/// One-click setups.
struct LayoutPreset: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let count: Int
    let rows: Int
    let resolution: ResolutionPreset
    let widthDegrees: Double
    let curve: Double

    static let all: [LayoutPreset] = [
        .init(id: "single", title: "Single", symbol: "rectangle", count: 1, rows: 1,
              resolution: .init(width: 1920, height: 1080), widthDegrees: 36, curve: 0.25),
        .init(id: "dual", title: "Dual", symbol: "rectangle.split.2x1", count: 2, rows: 1,
              resolution: .default, widthDegrees: 33, curve: 0.45),
        .init(id: "triple", title: "Triple", symbol: "rectangle.split.3x1", count: 3, rows: 1,
              resolution: .default, widthDegrees: 33, curve: 0.55),
        .init(id: "ultrawide", title: "Wide", symbol: "rectangle.ratio.16.to.9", count: 1, rows: 1,
              resolution: .init(width: 3840, height: 1080), widthDegrees: 80, curve: 0.85),
        .init(id: "quad", title: "Quad", symbol: "rectangle.split.2x2", count: 4, rows: 2,
              resolution: .default, widthDegrees: 33, curve: 0.45),
        .init(id: "command", title: "Six", symbol: "square.grid.3x2", count: 6, rows: 2,
              resolution: .default, widthDegrees: 33, curve: 0.7),
    ]
}

/// User settings, persisted in UserDefaults. Main-thread only.
final class Settings: ObservableObject {
    private let d = UserDefaults.standard

    // Screens
    @Published var screenCount: Int { didSet { d.set(screenCount, forKey: "screenCount") } }
    @Published var rows: Int { didSet { d.set(rows, forKey: "rows") } }
    @Published var resolutionID: String { didSet { d.set(resolutionID, forKey: "resolution") } }
    @Published var hiDPI: Bool { didSet { d.set(hiDPI, forKey: "hiDPI") } }
    @Published var refreshRate: Int { didSet { d.set(refreshRate, forKey: "refreshRate") } }
    @Published var glassesIsMain: Bool { didSet { d.set(glassesIsMain, forKey: "glassesIsMain") } }
    @Published var placement: ScreenPlacement { didSet { d.set(placement.rawValue, forKey: "placement") } }
    /// Custom arrangement: each glasses screen's offset from the laptop screen's top-left (points).
    @Published var customOffsets: [Int: CGPoint] {
        didSet {
            d.set(Dictionary(uniqueKeysWithValues: customOffsets.map { ("\($0.key)", [Double($0.value.x), Double($0.value.y)]) }),
                  forKey: "customOffsets")
        }
    }

    // Layout
    /// Angular width of each screen in degrees (the Air 2 Pro shows ~39° × 22°).
    @Published var screenWidthDegrees: Double { didSet { d.set(screenWidthDegrees, forKey: "screenWidthDegrees") } }
    @Published var gapDegrees: Double { didSet { d.set(gapDegrees, forKey: "gapDegrees") } }
    /// 0 = flat wall, 1 = wrapped around you.
    @Published var curve: Double { didSet { d.set(curve, forKey: "curve") } }
    /// Raise (+) or lower (−) all screens, degrees.
    @Published var tiltDegrees: Double { didSet { d.set(tiltDegrees, forKey: "tiltDegrees") } }

    // Tracking
    @Published var trackingMode: TrackingMode { didSet { d.set(trackingMode.rawValue, forKey: "trackingMode") } }
    @Published var cursorFollowsGaze: Bool { didSet { d.set(cursorFollowsGaze, forKey: "cursorFollowsGaze") } }
    /// When the cursor jumps to the screen you look at, focus the window you last used there.
    @Published var keyboardFollowsGaze: Bool { didSet { d.set(keyboardFollowsGaze, forKey: "keyboardFollowsGaze") } }
    /// Put windows back on their glasses screens after restarts, unplugging, sleep.
    @Published var windowMemory: Bool { didSet { d.set(windowMemory, forKey: "windowMemory") } }
    @Published var predictionMs: Double { didSet { d.set(predictionMs, forKey: "predictionMs") } }
    /// Screens ignore head wobble smaller than this (degrees): typing, breathing. 0 = off.
    @Published var stabilityDegrees: Double { didSet { d.set(stabilityDegrees, forKey: "stabilityDegrees") } }
    /// Smooth-follow lag time constant, seconds (smaller = snappier).
    @Published var followLag: Double { didSet { d.set(followLag, forKey: "followLag") } }
    /// Smart mode: 0 = only very fast flicks move the screens, 1 = gentle flicks do.
    @Published var flickSensitivity: Double { didSet { d.set(flickSensitivity, forKey: "flickSensitivity") } }
    /// Smart mode: a quick head flick also drags the screens along.
    @Published var smartFlick: Bool { didSet { d.set(smartFlick, forKey: "smartFlick") } }
    /// Rotates the picture clockwise (+) / counter-clockwise (−) to match how the glasses sit on your face.
    @Published var rollDegrees: Double { didSet { d.set(rollDegrees, forKey: "rollDegrees") } }
    /// How far away the screens sit (m). Only noticeable in 3D: their size stays the same.
    @Published var screenDistance: Double { didSet { d.set(screenDistance, forKey: "screenDistance") } }

    // Look
    @Published var sharpen: Double { didSet { d.set(sharpen, forKey: "sharpen") } }
    /// Subpixel text rendering for the glasses' color stripes: 0 off, 1 RGB, 2 BGR (the Air 2 Pro as
    /// seen through its mirror optics, chosen by eye at full strength), 3/4 the same with vertical stripes.
    @Published var subpixel: Int { didSet { d.set(subpixel, forKey: "subpixel") } }
    @Published var subpixelStrength: Double { didSet { d.set(subpixelStrength, forKey: "subpixelStrength") } }
    /// White point: −1 cooler … 0 neutral … +1 warmer.
    @Published var warmth: Double { didSet { d.set(warmth, forKey: "warmth") } }

    /// Linear-light multipliers for `warmth`, scaled so the strongest channel stays at 1 (no clipping).
    /// Roughly 6500 K ± 2500 K: warmer drops blue (and a little green), cooler drops red.
    var whitePoint: SIMD3<Float> {
        let w = Float(min(max(warmth, -1), 1))
        let rgb = w >= 0 ? SIMD3<Float>(1, 1 - 0.10 * w, 1 - 0.38 * w) : SIMD3<Float>(1 + 0.30 * w, 1 + 0.07 * w, 1)
        return rgb / max(rgb.x, max(rgb.y, rgb.z))
    }
    /// How much to dim screens you're not looking at.
    @Published var focusDim: Double { didSet { d.set(focusDim, forKey: "focusDim") } }
    /// Overall image brightness. Lower = more see-through on the glasses.
    @Published var brightness: Double { didSet { d.set(brightness, forKey: "brightness") } }
    @Published var highlightCursorScreen: Bool { didSet { d.set(highlightCursorScreen, forKey: "highlightCursorScreen") } }
    @Published var cornerRadius: Double { didSet { d.set(cornerRadius, forKey: "cornerRadius") } }
    /// Offscreen render scale: 1 = Standard, 1.5 = High, 2 = Ultra.
    @Published var renderScale: Double { didSet { d.set(renderScale, forKey: "renderScale") } }
    /// Correct the glasses' lens distortion with their factory calibration.
    @Published var lensCorrection: Bool { didSet { d.set(lensCorrection, forKey: "lensCorrection") } }

    // General
    @Published var autoExtendDisplay: Bool { didSet { d.set(autoExtendDisplay, forKey: "autoExtendDisplay") } }
    @Published var hotkeysEnabled: Bool { didSet { d.set(hotkeysEnabled, forKey: "hotkeysEnabled") } }
    @Published var showHUD: Bool { didSet { d.set(showHUD, forKey: "showHUD") } }
    /// On quit, set the glasses to mirror the main screen (their normal state without XRealDesk).
    @Published var mirrorWhenQuitting: Bool { didSet { d.set(mirrorWhenQuitting, forKey: "mirrorWhenQuitting") } }
    /// Full diagnostic log on disk (frame timing, tracking health, events). Off: errors only.
    @Published var diagnosticLog: Bool { didSet { d.set(diagnosticLog, forKey: "diagnosticLog"); Log.diagnostics = diagnosticLog } }
    /// Seconds after the glasses come off before your windows move to the Mac (and back when you
    /// put them on). < 0 = never.
    @Published var glassesOffMoveDelay: Double { didSet { d.set(glassesOffMoveDelay, forKey: "glassesOffMoveDelay") } }
    @Published var showInDock: Bool { didSet { d.set(showInDock, forKey: "showInDock") } }

    var resolution: ResolutionPreset {
        get { .from(id: resolutionID) }
        set { resolutionID = newValue.id }
    }

    static let maxScreens = 8

    init() {
        d.register(defaults: [
            "screenCount": 3, "rows": 1, "resolution": ResolutionPreset.default.id, "hiDPI": true,
            "refreshRate": 120, "glassesIsMain": false,
            "screenWidthDegrees": 33.0, "gapDegrees": 1.5, "curve": 0.55, "tiltDegrees": 0.0,
            "trackingMode": TrackingMode.smart.rawValue, "cursorFollowsGaze": true, "keyboardFollowsGaze": true, "windowMemory": true,
            "predictionMs": 14.0, "stabilityDegrees": 0.03, "followLag": 0.3, "flickSensitivity": 0.5, "smartFlick": false, "rollDegrees": 0.0, "screenDistance": 1.5,
            "sharpen": 0.35, "subpixel": 2, "subpixelStrength": 1.0, "warmth": 0.0, "focusDim": 0.25, "brightness": 1.0, "highlightCursorScreen": true, "cornerRadius": 0.018, "renderScale": 2.0, "lensCorrection": true,
            "autoExtendDisplay": true, "hotkeysEnabled": true, "showHUD": true, "mirrorWhenQuitting": true, "glassesOffMoveDelay": 10.0, "diagnosticLog": false, "showInDock": true,
        ])
        screenCount = min(max(d.integer(forKey: "screenCount"), 1), Settings.maxScreens)
        rows = min(max(d.integer(forKey: "rows"), 1), 3)
        resolutionID = ResolutionPreset.from(id: d.string(forKey: "resolution") ?? "").id
        hiDPI = d.bool(forKey: "hiDPI")
        refreshRate = d.integer(forKey: "refreshRate") == 120 ? 120 : 60
        glassesIsMain = d.bool(forKey: "glassesIsMain")
        placement = ScreenPlacement(rawValue: d.string(forKey: "placement") ?? "") ?? .above
        var offsets: [Int: CGPoint] = [:]
        for (k, v) in (d.dictionary(forKey: "customOffsets") as? [String: [Double]]) ?? [:] where v.count == 2 {
            if let i = Int(k) { offsets[i] = CGPoint(x: v[0], y: v[1]) }
        }
        customOffsets = offsets
        screenWidthDegrees = d.double(forKey: "screenWidthDegrees")
        gapDegrees = d.double(forKey: "gapDegrees")
        curve = d.double(forKey: "curve")
        tiltDegrees = d.double(forKey: "tiltDegrees")
        trackingMode = TrackingMode(rawValue: d.string(forKey: "trackingMode") ?? "") ?? .smart
        cursorFollowsGaze = d.bool(forKey: "cursorFollowsGaze")
        keyboardFollowsGaze = d.bool(forKey: "keyboardFollowsGaze")
        windowMemory = d.bool(forKey: "windowMemory")
        predictionMs = d.double(forKey: "predictionMs")
        stabilityDegrees = d.double(forKey: "stabilityDegrees")
        followLag = d.double(forKey: "followLag")
        flickSensitivity = d.double(forKey: "flickSensitivity")
        smartFlick = d.bool(forKey: "smartFlick")
        rollDegrees = d.double(forKey: "rollDegrees")
        screenDistance = min(max(d.double(forKey: "screenDistance"), 0.5), 10)
        sharpen = d.double(forKey: "sharpen")
        subpixel = min(max(d.integer(forKey: "subpixel"), 0), 4)
        subpixelStrength = min(max(d.double(forKey: "subpixelStrength"), 0), 1)
        warmth = min(max(d.double(forKey: "warmth"), -1), 1)
        focusDim = d.double(forKey: "focusDim")
        brightness = d.double(forKey: "brightness")
        highlightCursorScreen = d.bool(forKey: "highlightCursorScreen")
        cornerRadius = d.double(forKey: "cornerRadius")
        renderScale = min(max(d.double(forKey: "renderScale"), 1), 2)
        lensCorrection = d.bool(forKey: "lensCorrection")
        autoExtendDisplay = d.bool(forKey: "autoExtendDisplay")
        hotkeysEnabled = d.bool(forKey: "hotkeysEnabled")
        showHUD = d.bool(forKey: "showHUD")
        mirrorWhenQuitting = d.bool(forKey: "mirrorWhenQuitting")
        glassesOffMoveDelay = d.double(forKey: "glassesOffMoveDelay")
        diagnosticLog = d.bool(forKey: "diagnosticLog")
        Log.diagnostics = d.bool(forKey: "diagnosticLog")
        showInDock = d.bool(forKey: "showInDock")
    }

    /// Settings that require (re)creating macOS virtual displays when changed.
    var displaySignature: String { "\(screenCount)-\(resolutionID)-\(hiDPI)-\(refreshRate)" }

    func layout() -> ScreenLayout {
        ScreenLayout(count: screenCount, rows: rows, widthDegrees: Float(screenWidthDegrees),
                     aspect: resolution.aspect, gapDegrees: Float(gapDegrees), curve: Float(curve),
                     tiltDegrees: Float(tiltDegrees), distance: Float(screenDistance))
    }

    func apply(_ p: LayoutPreset) {
        screenCount = p.count
        rows = p.rows
        resolution = p.resolution
        screenWidthDegrees = p.widthDegrees
        curve = p.curve
    }

    var matchingPreset: String? {
        LayoutPreset.all.first {
            $0.count == screenCount && $0.rows == rows && $0.resolution == resolution
                && abs($0.widthDegrees - screenWidthDegrees) < 0.5 && abs($0.curve - curve) < 0.01
        }?.id
    }

    /// The settings that work best on the Air 2 Pro (measured over many sessions): HiDPI screens,
    /// Smart mode, 120 Hz, the best picture and tracking. Leaves your layout (screens, size, curve,
    /// placement) alone.
    func applyRecommended() {
        hiDPI = true
        trackingMode = .smart
        refreshRate = 120
        renderScale = 2
        lensCorrection = true
        predictionMs = 14
        stabilityDegrees = 0.03
        followLag = 0.3
        cursorFollowsGaze = true
        keyboardFollowsGaze = true
        windowMemory = true
        glassesOffMoveDelay = 10
        autoExtendDisplay = true
        mirrorWhenQuitting = true
        showHUD = true
        hotkeysEnabled = true
        resetLook()
    }

    /// True when every recommended value is already set.
    var isRecommended: Bool {
        hiDPI && trackingMode == .smart && refreshRate == 120 && renderScale == 2 && lensCorrection && predictionMs == 14
            && abs(stabilityDegrees - 0.03) < 0.001 && cursorFollowsGaze && keyboardFollowsGaze && windowMemory
            && autoExtendDisplay && mirrorWhenQuitting
    }

    func resetLook() {
        subpixel = 2
        subpixelStrength = 1
        warmth = 0
        sharpen = 0.35; focusDim = 0.25; brightness = 1; highlightCursorScreen = true; cornerRadius = 0.018
    }
}

/// Stores learned gyro bias per headset serial.
final class DefaultsBiasStore: GlassesBiasStore, @unchecked Sendable {
    func loadBias(serial: String) -> SIMD3<Float>? {
        guard let a = UserDefaults.standard.array(forKey: "gyroBias.v2.\(serial)") as? [Double], a.count == 3 else { return nil }
        return SIMD3(Float(a[0]), Float(a[1]), Float(a[2]))
    }
    func saveBias(_ bias: SIMD3<Float>, serial: String) {
        UserDefaults.standard.set([Double(bias.x), Double(bias.y), Double(bias.z)], forKey: "gyroBias.v2.\(serial)")
    }
}
