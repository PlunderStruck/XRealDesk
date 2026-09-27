import AppKit
import Combine
import Metal
import QuartzCore
import simd
import XRCore

/// Owns everything and keeps it consistent. All state changes funnel into `reconcile()`, which is
/// idempotent: it looks at what's actually connected and makes the app match. That's what makes
/// plugging, unplugging, sleeping and display changes all recover on their own.
/// Values that change many times a second. Observed only by small leaf views.
final class LiveState: ObservableObject {
    @Published var gazeScreen: Int?
    @Published var cursorScreen: Int?
    /// Head yaw/pitch relative to the layout, radians.
    @Published var viewYawPitch = SIMD2<Float>(0, 0)
    @Published var renderFPS: Double = 0
    @Published var imuRate: Double = 0
    /// The glasses are in their side-by-side 3D mode (button), running at 60 Hz.
    @Published var sideBySide = false
}

final class AppController: ObservableObject {

    // MARK: Published status (for the menu / settings UI)

    @Published private(set) var glassesState: GlassesHIDService.State = .searching
    @Published private(set) var deviceInfo: GlassesHIDService.DeviceInfo?
    @Published private(set) var glassesDisplayName: String?
    @Published private(set) var permissionGranted = CGPreflightScreenCaptureAccess()
    @Published private(set) var activeScreenCount = 0
    @Published private(set) var capturingCount = 0
    @Published private(set) var trackingHealthy = false
    @Published private(set) var needsRelaunchForPermission = false
    /// Accessibility permission (window memory + keyboard focus following your eyes).
    @Published private(set) var accessibilityGranted = WindowKeeper.isTrusted
    /// Taken off your face (wear sensor): drawing is paused.
    @Published private(set) var glassesOffFace = false
    /// Called right before XRealDesk restarts itself (so the UI can remember where it was).
    var onBeforeRelaunch: (() -> Void)?
    /// Fast-changing values (gaze, fps…) live in their own object so only the small views that
    /// show them re-render, not the whole settings UI.
    let live = LiveState()

    let settings = Settings()
    let preview: Bool
    /// Set by the app delegate: opens the control panel (⌃⌥X).
    var onShowControlPanel: (() -> Void)?

    // MARK: Subsystems

    private let biasStore = DefaultsBiasStore()
    private let hid: GlassesHIDService
    /// The glasses screens, owned by the display host so they survive restarts (see DisplayHost).
    private let virtualDisplays = DisplayHostClient()
    /// Restarting (e.g. for a permission): leave the screens and their windows where they are.
    private var keepScreensOnQuit = false
    private var captures: [DisplayCapture] = []
    private var window: GlassesWindow?
    /// Side-by-side 3D with real depth (experimental; the flat picture felt better on the Air 2 Pro).
    private var stereoDepth = false
    /// Screen setup whose leaving windows were already moved onto the remaining screens.
    private var evacuatedFor: String?
    /// Stall watchdog: when rendering last (re)started after a deliberate pause.
    private var watchdogArmedAt: CFTimeInterval = 0
    /// Just-in-time frame start (`set jit=1`): measured to gain < 1 ms here (the GPU is shared with
    /// WindowServer, so there's little slack before the deadline), so off by default.
    private var lateStart = false
    private var presentDelay = 0
    private var handoffOffset: Double?
    private var followPresentation = true
    /// Record window positions at the next quiet moment (e.g. after the first check following a restore).
    private var needsWindowSnapshot = true
    /// Capture size relative to the screen's pixels (`set capturescale=`, for measuring).
    private var captureScale: CGFloat = 1
    private var sharpDownsample = true
    private var directRender = true
    private var renderer: Renderer?
    private let cursor = CursorController()
    private let windows = WindowKeeper()
    private var tickCount = 0
    private var slowSeconds = 0
    private var screenChangeObserver: NSObjectProtocol?
    private var failedRepairs = 0
    private var lastNearView: [Int: TimeInterval] = [:]
    private var lastRestoreAt: Date?
    private var lastStallRecovery: TimeInterval = 0
    private var lastResync: TimeInterval = 0
    private var lastWindowLook: TimeInterval = 0
    private var lastFrontPID: pid_t = 0
    /// Screen whose window should get keyboard focus once you've settled there and stopped typing.
    private var pendingFocus: (screen: Int, display: CGDirectDisplayID, since: CFTimeInterval)?
    private let hotkeys = Hotkeys()
    private var cancellables = Set<AnyCancellable>()

    // MARK: Spatial state

    private(set) var layout = ScreenLayout()
    /// Renders on its own thread; nil while there's no output window.
    private var compositor: Compositor?
    /// Focused screen (kept in front in smooth-follow / locked modes). Mirrors the compositor's.
    private var focusIndex = 0
    private var lastGaze: Int?
    private var trackingLostShown = false
    private var uiTimer: Timer?

    // MARK: Lifecycle bookkeeping

    private var glassesDisplayID: CGDirectDisplayID?
    private var arrangedKey: String?
    private var arrangeAttempts = 0
    private var extendAttempts = 0
    private var teardownWork: DispatchWorkItem?
    private var reconcileWork: DispatchWorkItem?
    private var displayGeneration = 0
    private var restartCapturesAfterModes = false
    private var permissionTimer: Timer?
    private var lastSettingsSnapshot: [String: Double] = [:]

    init(preview: Bool) {
        self.preview = preview
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("XRealDesk", isDirectory: true)
        hid = GlassesHIDService(cacheDirectory: support, biasStore: biasStore)
        layout = settings.layout()
        lastSettingsSnapshot = settingsSnapshot()
    }

    func start() {
        Log.info("XRealDesk starting (preview: \(preview)) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        hid.logger = { Log.info("[glasses] \($0)") }
        hid.onStateChange = { [weak self] state in self?.glassesStateChanged(state) }
        hid.onDeviceInfo = { [weak self] info in self?.deviceInfo = info }
        hid.onButton = { phys, virt, value in Log.info("Glasses button phys=\(phys) virt=\(virt) value=\(value)") }
        hid.onWornChange = { [weak self] worn in self?.wornChanged(worn) }
        hid.start()

        if let device = MTLCreateSystemDefaultDevice() {
            renderer = Renderer(device: device, pixelFormat: .bgra8Unorm_srgb)
        }
        if renderer == nil { Log.error("Metal unavailable; cannot render") }

        cursor.gazeFollowEnabled = settings.cursorFollowsGaze
        hotkeys.handler = { [weak self] in self?.handleHotkey($0) }
        if settings.hotkeysEnabled { hotkeys.register() }
        TypingLatency.start()
        lastHotkeys = settings.hotkeysEnabled

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.lastDisplayChange = Date()
            self?.scheduleReconcile(after: 0.4)
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemDidWake()
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleReconcile(after: 1.0)
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: Notification.Name("com.xrealdesk.snapshot"), object: nil, queue: .main) { [weak self] _ in
            self?.requestSnapshot()
        }
        dnc.addObserver(forName: Notification.Name("com.xrealdesk.recenter"), object: nil, queue: .main) { [weak self] _ in
            self?.recenter()
        }

        // Test hook: end-to-end window memory check with one app's front window (object = bundle id).
        dnc.addObserver(forName: Notification.Name("com.xrealdesk.windowReport"), object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.windows.report(screens: self.virtualScreenList)
        }
        dnc.addObserver(forName: Notification.Name("com.xrealdesk.testWindowMemory"), object: nil, queue: .main) { [weak self] note in
            guard let self, let bundle = note.object as? String,
                  let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first,
                  let wid = self.windows.frontWindowID(pid: app.processIdentifier),
                  let screen = self.virtualDisplays.screens.first else { Log.info("Test: setup failed"); return }
            let sb = CGDisplayBounds(screen.id)
            let onGlasses = CGRect(x: sb.minX + 200, y: sb.minY + 150, width: 700, height: 450)
            self.windows.debugPlace(pid: app.processIdentifier, windowID: wid, rect: onGlasses) { placed in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.windows.suspended = false
                    self.windows.snapshot(screens: self.virtualScreenList, displaysStableFor: self.displaysStableFor)
                    let remembered = self.windows.entries[wid] != nil
                    self.windows.suspended = true
                    let home = CGDisplayBounds(DisplayConfigurator.homeDisplay(excluding: self.glassesDisplayID))
                    self.windows.debugPlace(pid: app.processIdentifier, windowID: wid, rect: CGRect(x: home.minX + 100, y: home.minY + 100, width: 700, height: 450)) { evicted in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            let mid = self.windows.currentFrame(of: wid)
                            self.restoreWindows()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                let end = self.windows.currentFrame(of: wid)
                                let moved = mid.map { abs($0.minX - onGlasses.minX) > 50 } ?? false
                                let ok = moved && (end.map { abs($0.minX - onGlasses.minX) < 2 && abs($0.minY - onGlasses.minY) < 2 } ?? false)
                                Log.info("Test window memory: placed \(placed), remembered \(remembered), evicted \(evicted) → \(mid.map { "\($0.origin)" } ?? "?"), restored to \(end.map { "\($0.origin)" } ?? "?") [expected \(onGlasses.origin)] → \(ok ? "PASS" : "FAIL")")
                            }
                        }
                    }
                }
            }
        }

        // Diagnostics: record raw head-motion data for offline tuning (object = seconds).
        dnc.addObserver(forName: Notification.Name("com.xrealdesk.recordIMU"), object: nil, queue: .main) { [weak self] note in
            let seconds = (note.object as? String).flatMap(Double.init) ?? 60
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/XRealDesk", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                    formatOptions: [.withYear, .withMonth, .withDay, .withTime])
            self?.hid.recordIMU(to: dir.appendingPathComponent("imu-\(stamp).csv"), seconds: seconds)
        }

        // Scripting hook: `com.xrealdesk.set` with object "key=value" (preset, screens, curve, size, height, mode).
        dnc.addObserver(forName: Notification.Name("com.xrealdesk.set"), object: nil, queue: .main) { [weak self] note in
            guard let self, let arg = note.object as? String else { return }
            let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            let v = parts[1]
            switch parts[0] {
            case "preset": if let p = LayoutPreset.all.first(where: { $0.id == v }) { self.settings.apply(p) }
            case "screens": if let n = Int(v) { self.settings.screenCount = min(max(n, 1), Settings.maxScreens) }
            case "curve": if let x = Double(v) { self.settings.curve = min(max(x, 0), 1) }
            case "size": if let x = Double(v) { self.settings.screenWidthDegrees = x }
            case "height": if let x = Double(v) { self.settings.tiltDegrees = x }
            case "mode": if let m = TrackingMode(rawValue: v) { self.setMode(m) }
            case "lens": self.settings.lensCorrection = v == "1"
            case "warmth": if let x = Double(v) { self.settings.warmth = min(max(x, -1), 1) }
            case "subpixelstrength": if let x = Double(v) { self.settings.subpixelStrength = min(max(x, 0), 1) }
            case "subpixel":   // experiment: 0 off, 1 RGB, 2 BGR (across), 3 RGB, 4 BGR (down)
                self.settings.subpixel = min(max(Int(v) ?? 0, 0), 4)
            case "presentdelay":   // refreshes after the display link's target to show each frame (0 or 1)
                if let x = Int(v), (0...2).contains(x) { self.presentDelay = x; self.pushConfig() }
            case "followpresent":   // predict for when frames are actually shown: 1 on (default), 0 off
                self.followPresentation = v != "0"; self.pushConfig()
            case "handoff":   // experiment: start frames at deadline + N ms ("off" = normal)
                self.handoffOffset = Double(v).map { $0 / 1000 }; self.pushConfig()
            case "hud":     // show a message in the glasses (test cues)
                self.hud(v)
            case "trace":   // record every frame for N seconds (frames.csv), to find stutters
                self.compositor?.send(.trace(Double(v) ?? 10))
            case "stall":   // test: freeze the render thread for N seconds (the watchdog should recover)
                self.compositor?.send(.stall(Double(v) ?? 3))
            case "diagnostics": self.settings.diagnosticLog = v == "1"
            case "stability": if let x = Double(v) { self.settings.stabilityDegrees = min(max(x, 0), 0.4) }
            case "refresh": if let x = Int(v), x == 60 || x == 120 { self.settings.refreshRate = x }
            case "direct":   // 1 = single-pass renderer (default), 0 = two-pass (supersample + warp)
                self.directRender = v != "0"
                self.pushConfig()
            case "filter":   // 1 = Catmull-Rom downsample of the supersampled image, 0 = one bilinear tap
                self.sharpDownsample = v != "0"
                self.pushConfig()
            case "quality": if let x = Double(v) { self.settings.renderScale = min(max(x, 1), 2) }
            case "hidpi": self.settings.hiDPI = v == "1"

            case "sharpen": if let x = Double(v) { self.settings.sharpen = x }
            case "pause":   // diagnostics: stop drawing and capturing (1) / resume (0)
                if v == "1" { self.compositor?.stop(); self.stopCaptures() } else {
                    if let w = self.window { self.compositor?.start(fps: w.screen?.maximumFramesPerSecond ?? 120) }
                    self.syncCaptures(restartAll: false)
                }
            case "distance": if let x = Double(v) { self.settings.screenDistance = min(max(x, 0.5), 10) }
            case "depth":   // side-by-side 3D: 1 = real depth, 0 = the same flat picture in both eyes (default)
                self.stereoDepth = v == "1"
                self.pushConfig()
            case "capturescale":   // capture at this fraction of the screen's pixel size (0.4…1)
                self.captureScale = CGFloat(min(max(Double(v) ?? 1, 0.4), 1))
                for c in self.captures {
                    if let px = VirtualDisplayManager.pixelSize(of: c.displayID) {
                        c.matchSize(CGSize(width: (px.width * self.captureScale).rounded(), height: (px.height * self.captureScale).rounded()))
                    }
                }
            case "worn":    // test hook: as if the glasses' wear sensor reported off (0) / on (1)
                self.wornChanged(v != "0")
            case "jit":     // just-in-time frame start: 1 on (default), 0 off
                self.lateStart = v != "0"
                self.pushConfig()
            case "scan":    // rolling scan-out compensation: 0 off, 1 rows lit top to bottom, -1 bottom to top
                if let x = Int(v), (-1...1).contains(x) { self.settings.scanOut = x }
                self.hud(["Scan compensation: bottom → top", "Scan compensation off", "Scan compensation: top → bottom"][self.settings.scanOut + 1])
            case "steady":  // steady tracking: 1 = on (default), 0 = the previous tracking, for comparing
                self.hid.steadyTracking = v != "0"
                self.hud(self.hid.steadyTracking ? "Steady tracking on" : "Steady tracking off (old)")
            case "neck":    // 2D neck model: 1 = on (default), 0 = rotation only
                self.settings.neckModel = v != "0"
                self.hud(self.settings.neckModel ? "Neck model on" : "Neck model off")
            default: Log.info("Unknown set command \(arg)")
            }
        }

        settings.objectWillChange
            .debounce(for: .milliseconds(60), scheduler: RunLoop.main)
            .sink { [weak self] in self?.settingsChanged() }
            .store(in: &cancellables)

        windows.suspended = true   // until the first restore after the screens come up
        cursor.onGazeSwitch = { [weak self] index, displayID in
            guard let self, self.settings.keyboardFollowsGaze else { return }
            // Don't hand the keyboard over immediately: see tick() for the settle/typing guards.
            self.pendingFocus = (index, displayID, CACurrentMediaTime())
        }
        if !accessibilityGranted, !UserDefaults.standard.bool(forKey: "askedAccessibility") {
            UserDefaults.standard.set(true, forKey: "askedAccessibility")
            WindowKeeper.requestTrust()
        }

        if !permissionGranted {
            // Triggers the system prompt the first time; afterwards the setup window guides the user.
            if !UserDefaults.standard.bool(forKey: "askedScreenRecording") {
                UserDefaults.standard.set(true, forKey: "askedScreenRecording")
                CGRequestScreenCaptureAccess()
            }
            startPermissionPolling()
        }
        reconcile()
    }

    func shutdown() {
        Log.info("Shutting down")
        // Leave the glasses mirroring the main screen (their normal state without XRealDesk),
        // even if something had set them to extended for the session.
        let glassesForMirror = glassesDisplayID

        rememberWindows()
        if keepScreensOnQuit {
            Log.info("Restarting: keeping the glasses screens for the next XRealDesk")
            hotkeys.unregister()
            return
        }
        stopEverything()
        virtualDisplays.quit()
        if settings.mirrorWhenQuitting, glassesForMirror != nil || DisplayConfigurator.findGlassesDisplay() != nil,
           let exe = Bundle.main.executablePath {
            // macOS undoes this app's "extended while running" change as the process exits, which
            // would override a mirror set now. So a short-lived helper (this binary, no UI) sets
            // mirroring once we're gone.
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: exe)
            helper.arguments = ["--mirror-glasses"]
            try? helper.run()
            Log.info("Glasses will be set to mirror the main screen after quitting")
        }
        hotkeys.unregister()
    }

    /// Saves the next rendered glasses frame as a PNG in ~/Library/Logs/XRealDesk.
    func requestSnapshot() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/XRealDesk", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        compositor?.send(.snapshot(dir.appendingPathComponent("snapshot.png")))
    }

    // MARK: Reconcile

    func scheduleReconcile(after delay: TimeInterval = 0.2) {
        reconcileWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reconcile() }
        reconcileWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func reconcile() {
        reconcileWork = nil
        let gid = preview ? nil : DisplayConfigurator.findGlassesDisplay()

        if !preview {
            // Glasses taken off: leave everything paused (and, after a while, the glasses mirrored)
            // until they're put back on.
            if glassesOff, gid != nil { return }
            guard let gid else {
                if glassesDisplayID != nil {
                    Log.info("Glasses display went away")
                    noteDisplayDrop()
                }
                glassesDisplayID = nil
                glassesDisplayName = nil
                cursor.guardDisplay = nil
                // Hide immediately so a full-screen black window never lands on the laptop screen.
                compositor?.stop()
                window?.orderOut(nil)
                if !virtualDisplays.screens.isEmpty && teardownWork == nil {
                    // Grace period: brief cable glitches shouldn't shuffle all your windows around.
                    // A 2D↔3D switch takes the glasses' display away for ~10 s, so wait longer then.
                    // Still connected over USB (motion data flowing) = the glasses changing display
                    // mode or a brief blip, not an unplug: give it time to come back.
                    let stillConnected: Bool = { if case .tracking = glassesState { return true }; return false }()
                    let grace: TimeInterval = stillConnected ? 30 : 4
                    let work = DispatchWorkItem { [weak self] in
                        guard let self, self.glassesDisplayID == nil else { return }
                        Log.info("Glasses display absent for \(Int(grace))s; removing virtual screens")
                        self.stopEverything()
                    }
                    teardownWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + grace, execute: work)
                }
                return
            }
            teardownWork?.cancel()
            teardownWork = nil
            if glassesDisplayID != gid {
                Log.info("Glasses display found: \(gid) '\(DisplayConfigurator.name(of: gid))' \(CGDisplayBounds(gid))")
                arrangedKey = nil
                arrangeAttempts = 0
                extendAttempts = 0
            }
            glassesDisplayID = gid
            glassesDisplayName = DisplayConfigurator.name(of: gid)

            if DisplayConfigurator.isMirrored(gid) {
                cursor.guardDisplay = nil   // mirrored bounds are the main screen's: never guard those
                guard settings.autoExtendDisplay else { return }
                if Date() < displayUnstableUntil {
                    Log.info("Glasses display is unstable; leaving it alone for now")
                    scheduleReconcile(after: 5)
                    return
                }
                if extendAttempts < 4 {
                    extendAttempts += 1
                    DisplayConfigurator.extend(gid)
                    scheduleReconcile(after: 1.0)
                } else {
                    Log.error("Glasses display stays mirrored; set it to 'Extended' in System Settings > Displays")
                }
                return
            }
            extendAttempts = 0
        }

        ensureVirtualDisplays()

        let screen: NSScreen?
        if preview {
            screen = nil
        } else {
            screen = gid.flatMap { DisplayConfigurator.screen(for: $0) }
            if screen == nil { scheduleReconcile(after: 0.5); return }
        }
        ensureWindow(on: screen)
        cursor.guardDisplay = preview ? nil : gid
        arrangeIfNeeded(glasses: gid)
        // Captures that were paused (glasses off) or lost resume here once the screens are up.
        if !glassesOff, !virtualDisplays.screens.isEmpty, captures.count < virtualDisplays.screens.count,
           virtualDisplays.screens.allSatisfy({ CGDisplayIsOnline($0.id) != 0 }) {
            syncCaptures(restartAll: false)
        }
    }

    private func ensureVirtualDisplays() {
        if !virtualDisplays.screens.isEmpty, virtualDisplays.signature != settings.displaySignature {
            // Fewer screens: first move the windows off the screens about to go onto the ones that
            // stay (they remember their home and return when it does), then remove the screens.
            let keep = settings.screenCount
            if settings.windowMemory, keep < virtualDisplays.screens.count, evacuatedFor != settings.displaySignature,
               WindowKeeper.isTrusted {
                rememberWindows()
                evacuatedFor = settings.displaySignature
                let list = virtualScreenList
                windows.evacuate(from: list.filter { $0.index >= keep }, to: list.filter { $0.index < keep }) { [weak self] moved in
                    self?.scheduleReconcile(after: moved > 0 ? 0.3 : 0)
                }
                return
            }
            rememberWindows()
        }
        let result = virtualDisplays.sync(count: settings.screenCount, resolution: settings.resolution,
                                          hiDPI: settings.hiDPI, refreshRate: settings.refreshRate)
        if result != .unchanged { evacuatedFor = nil }   // the next shrink moves windows again
        switch result {
        case .unchanged:
            return
        case .recreated:
            stopCaptures()
            forgetTextures(nil)
            cursor.reset()
        case .remoded:
            // Same displays, new pixel size: captures must be reconfigured.
            restartCapturesAfterModes = true
            forgetTextures(nil)
            fallthrough
        case .resized:
            // Keep existing screens (and their windows); drop captures for removed ones.
            let live = Set(virtualDisplays.screens.map(\.id))
            captures.filter { !live.contains($0.displayID) }.forEach { c in
                c.stop()
                forgetTextures(c.index)
            }
            captures.removeAll { !live.contains($0.displayID) }
            pushCaptures()
        }
        activeScreenCount = virtualDisplays.screens.count
        arrangedKey = nil
        arrangeAttempts = 0
        displayGeneration += 1
        waitForDisplaysThenCapture(generation: displayGeneration, attempt: 0)
    }

    /// New virtual displays come online asynchronously. Once they're up, pin the intended mode,
    /// arrange them, then start capturing.
    private func waitForDisplaysThenCapture(generation: Int, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, generation == self.displayGeneration else { return }
            let online = self.virtualDisplays.screens.allSatisfy { CGDisplayIsOnline($0.id) != 0 }
            if !online && attempt < 20 {
                self.waitForDisplaysThenCapture(generation: generation, attempt: attempt + 1)
                return
            }
            let modesOK = self.virtualDisplays.enforceModes()
            if !modesOK && attempt < 8 {
                self.waitForDisplaysThenCapture(generation: generation, attempt: attempt + 1)
                return
            }
            self.arrangeIfNeeded(glasses: self.glassesDisplayID)
            if !online {
                // Never all online: still let window memory resume instead of staying off all session.
                Log.error("Not all glasses screens came online")
                self.restoreWindows()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, generation == self.displayGeneration, !self.glassesOff else { return }
                self.syncCaptures(restartAll: self.restartCapturesAfterModes)
                self.restartCapturesAfterModes = false
            }
        }
    }

    private func arrangeIfNeeded(glasses: CGDirectDisplayID?) {
        let ids = virtualDisplays.screens.map(\.id)
        guard !ids.isEmpty, ids.allSatisfy({ CGDisplayIsOnline($0) != 0 }) else { return }
        let glassesWidth = glasses.map { Int(CGDisplayBounds($0).width) } ?? 0
        let custom = settings.customOffsets.sorted { $0.key < $1.key }.map { "\($0.key):\(Int($0.value.x)),\(Int($0.value.y))" }.joined(separator: ";")
        let key = "\(ids)-\(glasses ?? 0)-\(glassesWidth)-\(settings.rows)-\(settings.glassesIsMain)-\(settings.placement.rawValue)-\(custom)"
        guard arrangedKey != key, arrangeAttempts < 6 else { return }
        arrangeAttempts += 1
        let origins = DisplayConfigurator.plannedOrigins(
            virtualIDs: ids, count: ids.count, rows: settings.rows,
            pointSize: virtualDisplays.screens[0].pointSize, glasses: glasses,
            mainIndex: settings.glassesIsMain ? centerPanelIndex() : nil,
            placement: settings.placement, customOffsets: settings.customOffsets)
        DisplayConfigurator.arrange(origins)
        arrangedKey = key
        lastPlannedOrigins = origins
        // WindowServer places newly attached displays asynchronously and can override us; verify and retry.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.arrangedKey == key else { return }
            if DisplayConfigurator.virtualArrangementMatches(origins, virtualIDs: ids, glasses: glasses) {
                Log.info("Display arrangement verified")
                self.restoreWindows()
                self.arrangeAttempts = 0
            } else {
                let actual = ids.map { "\($0)@\(CGDisplayBounds($0).origin)" }.joined(separator: " ")
                Log.info("Arrangement not applied yet (attempt \(self.arrangeAttempts)); actual: \(actual)")
                self.arrangedKey = nil
                if self.arrangeAttempts < 6 {
                    self.arrangeIfNeeded(glasses: self.glassesDisplayID)
                } else {
                    self.restoreWindows()   // positions won't settle; restore anyway rather than never
                }
            }
        }
    }

    private func ensureWindow(on screen: NSScreen?) {
        guard let renderer else { return }
        if window == nil {
            let w = GlassesWindow(screen: screen, preview: preview)
            w.hostView.metalLayer.device = renderer.device
            window = w
            let c = Compositor(renderer: renderer, layer: w.hostView.metalLayer, hid: hid)
            compositor = c
            // A new compositor starts without a cursor image: send it the current one again.
            cursorSignature = ""
            c.setCursorVisible(cursorVisible)
            // The display link binds to whichever screen the window is on when it starts. After a
            // move (e.g. the glasses' display dropped and came back) restart it once the window has
            // really landed, or frames get paced by the wrong display (the laptop's, at 80 Hz).
            if let o = screenChangeObserver { NotificationCenter.default.removeObserver(o) }
            screenChangeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: w, queue: .main) { [weak self, weak w] _ in
                guard let self, let w, let c = self.compositor, w.isVisible, !self.glassesOff else { return }
                Log.info("Output window moved to \(w.screen?.localizedName ?? "?"); re-syncing to its refresh rate")
                c.stop()
                c.start(fps: w.screen?.maximumFramesPerSecond ?? 120)
            }
            pushConfig()
            pushCaptures()
            c.send(.recenter(panel: centerPanelIndex()))
            startUITimer()
            Log.info(preview ? "Opened preview window" : "Opened output window on \(screen?.localizedName ?? "?")")
        } else if let screen, window?.screen != screen || window?.frame != screen.frame {
            window?.move(to: screen)
            compositor?.stop()   // re-bind the display link to the new screen
        }
        if window?.isVisible == false {
            window?.orderFrontRegardless()
        }
        compositor?.start(fps: (screen ?? window?.screen)?.maximumFramesPerSecond ?? 120)
    }

    /// Make captures match the virtual displays. Only starts what's missing unless `restartAll`.
    private func syncCaptures(restartAll: Bool) {
        guard let device = renderer?.device else { return }
        permissionGranted = CGPreflightScreenCaptureAccess()
        guard permissionGranted else {
            Log.info("Screen Recording permission not granted yet; screens will show placeholders")
            startPermissionPolling()
            return
        }
        if restartAll { stopCaptures() }
        for s in virtualDisplays.screens where !captures.contains(where: { $0.displayID == s.id }) {
            let c = DisplayCapture(displayID: s.id, index: s.index, device: device, refreshRate: settings.refreshRate)
            captures.append(c)
            c.start()
        }
        pushCaptures()
    }

    private func stopCaptures() {
        captures.forEach { $0.stop() }
        captures.removeAll()
        pushCaptures()
    }

    /// Final snapshot of which windows are on which glasses screen, taken while the screens still
    /// exist, then pause recording until they're restored.
    private func rememberWindows() {
        guard settings.windowMemory, !virtualDisplays.screens.isEmpty else { return }
        // Right after the screens came (back), windows are still where macOS dropped them: saving now
        // would overwrite your layout with the shuffle. Keep the memory as it was.
        if let r = lastRestoreAt, Date().timeIntervalSince(r) < 30 {
            windows.save()
            windows.suspended = true
            return
        }
        windows.snapshot(screens: virtualScreenList, displaysStableFor: 0)   // never forget on the way out
        windows.save()
        windows.suspended = true
    }

    private var virtualScreenList: [(index: Int, id: CGDirectDisplayID)] {
        virtualDisplays.screens.map { (index: $0.index, id: $0.id) }
    }

    private func restoreWindows() {
        lastRestoreAt = Date()
        guard settings.windowMemory else { windows.suspended = false; return }
        Log.info("Window memory: restore requested for \(virtualScreenList.count) screen(s)")
        windows.restore(screens: virtualScreenList) { [weak self] moved in
            guard let self else { return }
            // Let moved windows settle before recording positions again.
            DispatchQueue.main.asyncAfter(deadline: .now() + (moved > 0 ? 1.0 : 0)) { self.windows.suspended = false }
            if moved > 0 { self.hud("Put back \(moved) window\(moved == 1 ? "" : "s")") }
        }
    }

    /// A fresh output window and compositor (its own frame lock and display link), keeping the
    /// virtual screens and captures. Used when the renderer stalls.
    private func recreateRenderer() {
        compositor?.stop()
        compositor = nil
        if let o = screenChangeObserver { NotificationCenter.default.removeObserver(o); screenChangeObserver = nil }
        uiTimer?.invalidate()
        uiTimer = nil
        window?.orderOut(nil)
        window = nil
        scheduleReconcile()
    }

    private func stopEverything() {
        rememberWindows()
        displayGeneration += 1
        stopCaptures()
        virtualDisplays.destroyAll()
        activeScreenCount = 0
        compositor?.stop()
        compositor = nil
        uiTimer?.invalidate()
        uiTimer = nil
        renderer?.forgetAll()   // stop() waited for the render thread to exit
        if let o = screenChangeObserver { NotificationCenter.default.removeObserver(o); screenChangeObserver = nil }
        window?.orderOut(nil)
        window = nil
        arrangedKey = nil
        cursor.guardDisplay = nil
        cursor.reset()
    }

    private func systemDidWake() {
        Log.info("System woke; re-establishing glasses and capture")
        hid.reconnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.reconcile()
            if !self.virtualDisplays.screens.isEmpty, !self.glassesOff { self.syncCaptures(restartAll: true) }
        }
    }

    // MARK: Wear sensor

    /// Glasses are off your face (wear sensor). Rendering and capture are paused meanwhile.
    private var glassesOff = false
    private var glassesOffWork: DispatchWorkItem?
    /// The glasses screens were removed because the glasses stayed off.
    private var screensParkedForGlassesOff = false

    private func wornChanged(_ worn: Bool) {
        guard !preview, worn == glassesOff else { return }
        if worn { glassesPutOn() } else { glassesTakenOff() }
    }

    private func glassesTakenOff() {
        Log.info("Glasses taken off: pausing")
        glassesOff = true
        glassesOffFace = true
        compositor?.stop()
        stopCaptures()
        glassesOffWork?.cancel()
        let delay = settings.glassesOffMoveDelay
        guard delay >= 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.glassesOff, !self.virtualDisplays.screens.isEmpty else { return }
            Log.info("Glasses off for \(Int(delay)) s: moving windows to the Mac")
            self.screensParkedForGlassesOff = true
            // Removing the glasses screens hands their windows to the Mac's screen; mirroring the
            // glasses keeps the pointer from wandering onto a display nobody is looking at.
            self.stopEverything()
            if let g = self.glassesDisplayID ?? DisplayConfigurator.findGlassesDisplay() {
                DisplayConfigurator.mirror(g, of: DisplayConfigurator.homeDisplay(excluding: g))
            }
        }
        glassesOffWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func glassesPutOn() {
        Log.info("Glasses put on\(screensParkedForGlassesOff ? ": bringing the glasses screens back" : ": resuming")")
        glassesOff = false
        glassesOffFace = false
        glassesOffWork?.cancel()
        glassesOffWork = nil
        let parked = screensParkedForGlassesOff
        screensParkedForGlassesOff = false
        if parked {
            // Same path as plugging in: extend, recreate the screens, put the windows back.
            extendAttempts = 0
            scheduleReconcile()
        } else {
            if let w = window { compositor?.start(fps: w.screen?.maximumFramesPerSecond ?? 120) }
            syncCaptures(restartAll: false)
        }
        // Screens in front of you once your head has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + (parked ? 4 : 0.8)) { [weak self] in
            guard let self, !self.glassesOff else { return }
            self.focusIndex = self.centerPanelIndex()
            self.compositor?.send(.recenter(panel: self.focusIndex))
        }
    }

    private func glassesStateChanged(_ state: GlassesHIDService.State) {
        glassesState = state
        Log.info("Glasses state: \(state)")
        if case .tracking = state {} else if glassesOff {
            // Unplugged (or reconnecting) while off: the wear state is unknown now; plugging back in
            // goes through the normal path.
            glassesOff = false
            glassesOffFace = false
            screensParkedForGlassesOff = false
            glassesOffWork?.cancel()
            glassesOffWork = nil
            scheduleReconcile()   // restarts drawing and, if they were paused, the captures
        }
        if case .tracking = state {
            compositor?.send(.trackingRestarted)
        }
    }

    // MARK: Permission

    func requestAccessibilityPermission() {
        if !WindowKeeper.requestTrust() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    func requestScreenRecordingPermission() {
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
        startPermissionPolling()
    }

    private func startPermissionPolling() {
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if CGPreflightScreenCaptureAccess() {
                t.invalidate()
                self.permissionTimer = nil
                self.permissionGranted = true
                Log.info("Screen Recording permission granted")
                if !self.virtualDisplays.screens.isEmpty, !self.glassesOff { self.syncCaptures(restartAll: true) }
                // If capture still doesn't deliver after granting, macOS wants a relaunch: do it for you.
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    guard let self, !self.glassesOff else { return }
                    let failing = self.captures.contains { if case .failed = $0.status { return true }; return false }
                        || (!self.captures.isEmpty && self.captures.allSatisfy { $0.latestFrame == nil })
                    self.needsRelaunchForPermission = failing
                    if failing {
                        Log.info("Screen Recording needs a restart to take effect; restarting")
                        self.hud("Restarting XRealDesk to finish turning on Screen Recording…")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.relaunch() }
                    }
                }
            }
        }
    }

    func relaunch() {
        onBeforeRelaunch?()
        keepScreensOnQuit = true
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; exec /usr/bin/open \"$0\"", path]   // path as an argument: no quoting issues
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: Settings

    private var lastHotkeys = true

    private func settingsSnapshot() -> [String: Double] {
        ["size": settings.screenWidthDegrees, "curve": settings.curve, "tilt": settings.tiltDegrees,
         "gap": settings.gapDegrees, "brightness": settings.brightness, "sharpen": settings.sharpen,
         "focusDim": settings.focusDim, "roll": settings.rollDegrees, "stability": settings.stabilityDegrees, "prediction": settings.predictionMs, "flick": settings.flickSensitivity]
    }

    private func settingsChanged() {
        let newLayout = settings.layout()
        if newLayout != layout {
            layout = newLayout
            focusIndex = min(focusIndex, max(0, layout.panels.count - 1))
            arrangedKey = nil
            arrangeAttempts = 0
        }
        pushConfig()   // every change reaches the render thread

        cursor.gazeFollowEnabled = settings.cursorFollowsGaze
        if settings.hotkeysEnabled != lastHotkeys {
            lastHotkeys = settings.hotkeysEnabled
            settings.hotkeysEnabled ? hotkeys.register() : hotkeys.unregister()
        }

        // Live readout in the glasses while you drag a slider.
        let snap = settingsSnapshot()
        for (key, value) in snap where lastSettingsSnapshot[key] != value {
            switch key {
            case "size": hud(String(format: "Size  %.0f°", value))
            case "curve": hud(String(format: "Curve  %.0f%%", value * 100))
            case "tilt": hud(String(format: "Height  %+.0f°", value))
            case "gap": hud(String(format: "Gap  %.1f°", value))
            case "brightness": hud(String(format: "Brightness  %.0f%%", value * 100))
            case "sharpen": hud(String(format: "Sharpen  %.0f%%", value * 100))
            case "focusDim": hud(String(format: "Focus dim  %.0f%%", value * 100))
            case "roll": hud(value == 0 ? "Tilt  level" : String(format: "Tilt  %.1f° %@", abs(value), value > 0 ? "clockwise" : "counter-clockwise"))
            case "prediction": hud(String(format: "Timing  %.0f ms (screens lag → more, overshoot → less)", value))
            case "stability": hud(value < 0.005 ? "Stability  off" : String(format: "Stability  %.2f°", value))
            case "flick": hud(String(format: "Flick sensitivity  %.0f%%", value * 100))
            default: break
            }
        }
        lastSettingsSnapshot = snap

        if settings.displaySignature != virtualDisplays.signature {
            scheduleReconcile(after: 0.35)   // debounce steppers so we don't rebuild displays per click
        } else {
            arrangeIfNeeded(glasses: glassesDisplayID)
        }
    }

    // MARK: Actions

    func recenter() {
        focusIndex = centerPanelIndex()
        compositor?.send(.recenter(panel: focusIndex))
        hud("Recentered")
    }

    func cycleMode() {
        let all = TrackingMode.allCases
        let next = all[(all.firstIndex(of: settings.trackingMode)! + 1) % all.count]
        setMode(next)
    }

    func setMode(_ mode: TrackingMode) {
        let old = settings.trackingMode
        guard mode != old else { return }
        // Carry the screen you're on across modes: from anchored it's the one you're looking at.
        if old == .anchored || old == .smart { focusIndex = lastGaze ?? centerPanelIndex() }
        settings.trackingMode = mode
        pushConfig()
        // Leaving "locked to view": swing the anchored layout so the focused screen is where you look.
        compositor?.send(.focus(panel: focusIndex, moveAnchor: old == .headLocked))
        hud(mode.title)
    }

    func step(_ delta: Int) {
        guard !layout.panels.isEmpty else { return }
        let gazeBased = settings.trackingMode == .anchored || settings.trackingMode == .smart
        let current = gazeBased ? (lastGaze ?? centerPanelIndex()) : focusIndex
        focus(screen: min(max(current + delta, 0), layout.panels.count - 1))
    }

    /// Bring a screen in front of you and put the cursor on it.
    func focus(screen target: Int) {
        guard layout.panels.indices.contains(target) else { return }
        focusIndex = target
        compositor?.send(.focus(panel: target, moveAnchor: settings.trackingMode != .headLocked))
        if let id = virtualDisplays.screens.first(where: { $0.index == target })?.id {
            cursor.moveCursor(toScreen: id, now: CACurrentMediaTime())
            if settings.keyboardFollowsGaze { windows.focus(screen: target, displayID: id) }
        }
        hud("Screen \(target + 1)")
    }

    func zoom(_ delta: Double) {
        settings.screenWidthDegrees = min(max(settings.screenWidthDegrees + delta, 16), 100)
    }

    /// Screen width (degrees) at which one screen point maps to one glasses pixel: the sharpest size.
    func pixelPerfectWidthDegrees() -> Double {
        let cal = hid.calibration
        let w = Float(settings.resolution.width)
        return Double(SpatialMath.degrees(2 * atan(w / 2 / cal.focalX)))
    }

    private func handleHotkey(_ a: Hotkeys.Action) {
        switch a {
        case .recenter: recenter()
        case .toggleMode: cycleMode()
        case .previousScreen: step(-1)
        case .nextScreen: step(1)
        case .zoomIn: zoom(2)
        case .zoomOut: zoom(-2)
        case .raise: settings.tiltDegrees = min(settings.tiltDegrees + 2, 30)
        case .lower: settings.tiltDegrees = max(settings.tiltDegrees - 2, -30)
        case .moreCurve: settings.curve = min(settings.curve + 0.1, 1)
        case .lessCurve: settings.curve = max(settings.curve - 0.1, 0)
        case .controlPanel: onShowControlPanel?()
        case .rollClockwise: settings.rollDegrees = min(settings.rollDegrees + 0.5, 15)
        case .rollCounterClockwise: settings.rollDegrees = max(settings.rollDegrees - 0.5, -15)
        case .morePrediction: settings.predictionMs = min(settings.predictionMs + 2, 40)
        case .lessPrediction: settings.predictionMs = max(settings.predictionMs - 2, 0)
        case .cycleSubpixel:
            settings.subpixel = (settings.subpixel + 1) % 5
            let names = ["Off", "RGB  (1)", "BGR  (2)", "RGB, vertical  (3)", "BGR, vertical  (4)"]
            hud("Subpixel text: \(names[settings.subpixel])")
        case .toggleGazeCursor:
            settings.cursorFollowsGaze.toggle()
            hud(settings.cursorFollowsGaze ? "Cursor follows gaze: on" : "Cursor follows gaze: off")
        }
    }

    private func centerPanelIndex() -> Int {
        layout.nearest(direction: SIMD3(0, 0, -1)) ?? 0
    }

    private var cursorSignature = ""
    private var cursorVisible = true

    private func updateCursorImage() {
        guard let compositor, let cursor = NSCursor.currentSystem else { return }
        let img = cursor.image
        var rect = CGRect(origin: .zero, size: CGSize(width: img.size.width * 2, height: img.size.height * 2))
        guard let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return }
        // Cheap change detection: size, hotspot, and a sample of the pixels.
        var sample = 0
        if let data = cg.dataProvider?.data, let p = CFDataGetBytePtr(data) {
            let n = CFDataGetLength(data)
            for i in stride(from: 0, to: n, by: max(1, n / 64)) { sample = sample &* 31 &+ Int(p[i]) }
        }
        let sig = "\(img.size)-\(cursor.hotSpot)-\(cg.width)-\(sample)"
        guard sig != cursorSignature else { return }
        cursorSignature = sig
        compositor.setCursorImage(cg, hotSpot: cursor.hotSpot, size: img.size)
    }

    // MARK: Display stability

    /// If the glasses' display keeps dropping right after we reconfigure it, back off for a minute
    /// instead of looping (seen after the glasses' mode was switched by software).
    private var recentDrops: [Date] = []
    private var displayUnstableUntil = Date.distantPast

    private func noteDisplayDrop() {
        let now = Date()
        recentDrops = recentDrops.filter { now.timeIntervalSince($0) < 60 } + [now]
        if recentDrops.count >= 3 {
            displayUnstableUntil = now.addingTimeInterval(60)
            recentDrops.removeAll()
            Log.error("Glasses display dropped 3× within a minute; pausing display changes for 60 s. Replugging the glasses resets them.")
        }
    }

    /// Custom arrangement: remember where the glasses screens are right now (as arranged in
    /// System Settings → Displays) and keep them there from now on.
    func saveCurrentArrangement() {
        let home = CGDisplayBounds(DisplayConfigurator.homeDisplay(excluding: glassesDisplayID))
        var offsets: [Int: CGPoint] = [:]
        for s in virtualDisplays.screens {
            let b = CGDisplayBounds(s.id)
            offsets[s.index] = CGPoint(x: b.minX - home.minX, y: b.minY - home.minY)
        }
        settings.customOffsets = offsets
        settings.placement = .custom
        Log.info("Saved custom screen arrangement: \(offsets)")
        hud("Arrangement saved")
    }

    func openDisplaySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
    }

    /// The arrangement we last applied, to notice when macOS rearranges screens on its own later.
    private var lastPlannedOrigins: [CGDirectDisplayID: CGPoint] = [:]
    private var arrangementRepairs: [Date] = []
    private var userRearranged = false

    /// macOS sometimes re-shuffles displays after the fact (e.g. after a display change). Put the
    /// glasses screens back where they belong so the mouse moves between them and the laptop as laid
    /// out. Limited to 3 repairs a minute so we never fight macOS in a loop.
    private func checkArrangement() {
        let ids = virtualDisplays.screens.map(\.id)
        guard !ids.isEmpty, !lastPlannedOrigins.isEmpty, arrangedKey != nil, displaysStableFor > 3,
              ids.allSatisfy({ CGDisplayIsOnline($0) != 0 }) else { return }
        let arrangingInSystemSettings = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.systempreferences"
        if DisplayConfigurator.virtualArrangementMatches(lastPlannedOrigins, virtualIDs: ids, glasses: glassesDisplayID) {
            userRearranged = false
            failedRepairs = 0
            return
        }
        // You're dragging screens around in System Settings → Displays: leave them alone, and when
        // you're done, keep your layout (Custom) instead of snapping it back.
        if arrangingInSystemSettings { userRearranged = true; return }
        if userRearranged {
            userRearranged = false
            saveCurrentArrangement()
            hud("Kept your screen arrangement")
            return
        }
        let now = Date()
        arrangementRepairs = arrangementRepairs.filter { now.timeIntervalSince($0) < 60 }
        guard arrangementRepairs.count < 3 else { return }
        // Repairs that never stick (macOS keeps refusing the layout) would reshuffle displays forever.
        guard failedRepairs < 5 else { return }
        if failedRepairs == 4 { Log.error("macOS keeps refusing the planned arrangement; leaving the screens where macOS puts them") }
        failedRepairs += 1
        arrangementRepairs.append(now)
        let actual = ids.map { "\($0)@\(CGDisplayBounds($0).origin)" }.joined(separator: " ")
        Log.info("macOS moved the glasses screens (\(actual)); putting them back")
        arrangedKey = nil
        arrangeAttempts = 0
        arrangeIfNeeded(glasses: glassesDisplayID)
    }

    /// When the display setup last changed (screens appeared/disappeared/moved).
    private var lastDisplayChange = Date()
    private var displaysStableFor: TimeInterval { Date().timeIntervalSince(lastDisplayChange) }

    private func startUITimer() {
        guard uiTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)   // keeps running while sliders are dragged
        uiTimer = t
    }

    private func hud(_ text: String) {
        guard settings.showHUD else { return }
        window?.hostView.showHUD(text)
    }

    // MARK: Main-thread tick (cursor, UI readouts, tracking notices)

    /// 60 Hz on the main thread: cursor guard + gaze-follow, and publishing what the compositor
    /// reports. Rendering itself never waits for this.
    private func tick() {
        guard let compositor else { return }
        let out = compositor.output
        let now = CACurrentMediaTime()
        lastGaze = out.gaze
        let screens = virtualDisplays.screens.map { (index: $0.index, id: $0.id) }
        // Gaze only while drawing: a paused compositor's last gaze must not move the pointer or focus.
        let cursorIndex = cursor.tick(now: now, screens: screens, gazeIndex: compositor.isRunning && !glassesOff ? out.gaze : nil)
        compositor.setCursorScreen(cursorIndex)

        if live.gazeScreen != out.gaze { live.gazeScreen = out.gaze }
        if live.cursorScreen != cursorIndex { live.cursorScreen = cursorIndex }
        if simd_length(out.viewYawPitch - live.viewYawPitch) > SpatialMath.radians(0.3) { live.viewYawPitch = out.viewYawPitch }
        if abs(out.fps - live.renderFPS) > 0.5 { live.renderFPS = out.fps }
        if live.sideBySide != out.sideBySide { live.sideBySide = out.sideBySide }
        // Every couple of seconds: does each screen really run the mode the settings ask for (e.g. HiDPI
        // after switching it back on)? If not, set it again.
        if tickCount % 120 == 60, displaysStableFor > 2, !virtualDisplays.screens.isEmpty,
           virtualDisplays.screens.contains(where: { s in
               VirtualDisplayManager.pixelSize(of: s.id).map { Int($0.width) != Int(s.pixelSize.width) } ?? false
           }) {
            Log.info("A glasses screen isn't in its intended mode; setting it again")
            virtualDisplays.enforceModes()
        }
        // Capture screens near your view at full rate, the rest at a trickle (1 s grace after leaving),
        // and always at the screen's real pixel size (checked once a second).
        for c in captures {
            if tickCount % 60 == 30, let px = VirtualDisplayManager.pixelSize(of: c.displayID) {
                c.matchSize(CGSize(width: (px.width * captureScale).rounded(), height: (px.height * captureScale).rounded()))
            }
            if !out.tracking || out.nearView.contains(c.index) { lastNearView[c.index] = now }
            c.setActive(now - (lastNearView[c.index] ?? now) < 1)
        }
        let rate = hid.sampleRate
        if abs(rate - live.imuRate) > 5 { live.imuRate = rate }
        let capturing = captures.filter { $0.status == .running }.count
        if capturing != capturingCount { capturingCount = capturing }
        updateTrackingHealth(tracking: out.tracking)

        // Keyboard focus follows your eyes, but only once you've settled on the screen (0.5 s) and
        // aren't mid-typing (1 s since the last key), so a glance never steals your keystrokes.
        if let pf = pendingFocus {
            if cursorIndex != pf.screen || !settings.keyboardFollowsGaze {
                pendingFocus = nil
            } else if now - pf.since >= 0.5,
                      CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) >= 1.0 {
                windows.focus(screen: pf.screen, displayID: pf.display)
                pendingFocus = nil
            }
        }

        // Cursor for the live 120 Hz overlay: current shape (20×/s) and macOS-style hide-while-typing
        // (hidden after a keypress until the mouse moves again).
        let sinceMove = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved)
        // The shape changes as the pointer moves over things; otherwise only rarely (busy spinner).
        if tickCount % (sinceMove < 0.5 ? 3 : 30) == 0 { updateCursorImage() }
        let sinceKey = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let visible = sinceMove < sinceKey
        if visible != cursorVisible { cursorVisible = visible; compositor.setCursorVisible(visible) }

        // Watchdog: the picture in the glasses stopped updating. Record where every thread is (so the
        // cause can be found) and start a fresh renderer instead of leaving the glasses frozen.
        // Time spent paused on purpose (glasses off, renderer stopped) isn't a stall: the clock
        // starts again when rendering resumes (it once restarted the renderer as you put them on).
        if glassesOff || !compositor.isRunning || window?.isVisible != true { watchdogArmedAt = now }
        if !glassesOff, let w = window, w.isVisible, compositor.isRunning, out.lastFrameAt > 0,
           let gid = glassesDisplayID, CGDisplayIsAsleep(gid) == 0,
           now - max(out.lastFrameAt, watchdogArmedAt) > 1.5, now - lastStallRecovery > 10 {
            lastStallRecovery = now
            Log.error(String(format: "Renderer stalled (no frame for %.1f s): sampling threads, then restarting it", now - out.lastFrameAt))
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/XRealDesk")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
            let sample = Process()
            sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            sample.arguments = ["\(getpid())", "1", "-mayDie", "-file", dir.appendingPathComponent("stall-\(f.string(from: Date())).txt").path]
            try? sample.run()
            // Keep only the newest three reports.
            let old = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.hasPrefix("stall-") }.sorted().dropLast(3)
            old.forEach { try? FileManager.default.removeItem(at: dir.appendingPathComponent($0)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.recreateRenderer() }
            return
        }
        if out.needsResync, !glassesOff, let w = window, w.isVisible, now - lastResync > 3 {
            lastResync = now
            compositor.clearResyncRequest()
            compositor.stop()
            compositor.start(fps: w.screen?.maximumFramesPerSecond ?? 120)
        }

        // Self-healing: if frames stay well below the glasses' refresh rate for 10 s (e.g. the
        // display link got tied to the wrong screen), re-sync the renderer. Not sooner and at most
        // once a minute: a busy Mac (a big compile) also lowers the rate for a while, and each
        // restart costs frames of its own.
        if tickCount % 60 == 0, !glassesOff, let w = window, w.isVisible, let target = w.screen?.maximumFramesPerSecond, target > 0, out.fps > 0 {
            if out.fps < Double(target) * 0.85 {
                slowSeconds += 1
                if slowSeconds >= 10, now - lastResync > 60 {
                    lastResync = now
                    Log.info(String(format: "Rendering at %.0f fps on a %d Hz display; re-syncing", out.fps, target))
                    slowSeconds = 0
                    compositor.stop()
                    compositor.start(fps: target)
                }
            } else {
                slowSeconds = 0
            }
        }

        if tickCount % 120 == 0 { checkArrangement() }   // every 2 s

        tickCount += 1
        let screensUp = !virtualDisplays.screens.isEmpty && glassesDisplayID != nil || preview
        // Window lists are expensive and go through WindowServer (which also puts our frames on
        // the glasses), so only look after something that can change them: a click (focus, the end
        // of a drag), a modifier key (⌘-Tab, ⌘-`, window-manager shortcuts) or another app coming
        // forward. Plus a slow safety net.
        // Never while typing (a big window list held WindowServer for up to 250 ms: keystrokes lagged,
        // and modifier keys used to trigger it), and the full list only when the cheap on-screen
        // list shows the glasses' windows actually changed.
        let typing = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) < 1.5
        if screensUp, tickCount % 15 == 0, !typing {                                             // check 4×/s
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
            let since = now - lastWindowLook
            let changed = front != lastFrontPID
                || CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseUp) < since
            if changed || since > 60 {
                lastWindowLook = now
                lastFrontPID = front
                let windowsChanged = windows.noteFocus(screens: screens)
                if settings.windowMemory, windowsChanged || since > 60 || needsWindowSnapshot,
                   lastRestoreAt.map({ Date().timeIntervalSince($0) > 30 }) ?? true {
                    needsWindowSnapshot = false
                    windows.snapshot(screens: screens, displaysStableFor: displaysStableFor)
                }
            }
        }
        if screensUp, settings.windowMemory, tickCount % 1800 == 0 { windows.save() }             // every 30 s
        if tickCount % 60 == 0 {
            let trusted = WindowKeeper.isTrusted
            if trusted != accessibilityGranted {
                accessibilityGranted = trusted
                if trusted { Log.info("Accessibility granted"); restoreWindows() }
            }
        }
    }

    private func updateTrackingHealth(tracking: Bool) {
        if tracking != trackingHealthy { trackingHealthy = tracking }
        guard settings.trackingMode != .headLocked, !preview else { return }
        if !tracking && !trackingLostShown && glassesDisplayID != nil {
            trackingLostShown = true
            window?.hostView.showHUD("Head tracking unavailable\nReconnecting to the glasses…", seconds: 0)
        } else if tracking && trackingLostShown {
            trackingLostShown = false
            window?.hostView.hideHUD()
        }
    }

    /// Snapshot of everything the render thread needs from settings.
    private func compositorConfig() -> Compositor.Config {
        var c = Compositor.Config()
        c.layout = layout
        c.style = Renderer.Style(sharpen: Float(settings.sharpen), cornerRadius: Float(settings.cornerRadius),
                                 supersample: Float(settings.renderScale), lensCorrection: settings.lensCorrection,
                                 sharpDownsample: sharpDownsample, subpixel: settings.subpixel,
                                 subpixelStrength: Float(settings.subpixelStrength), white: settings.whitePoint,
                                 scanDirection: Float(settings.scanOut), direct: directRender)
        c.mode = settings.trackingMode
        c.predictionSeconds = settings.predictionMs / 1000
        c.stabilityRadians = SpatialMath.radians(Float(settings.stabilityDegrees))
        c.focusDim = Float(settings.focusDim)
        c.brightness = Float(settings.brightness)
        c.highlightCursor = settings.highlightCursorScreen
        c.followLag = Float(settings.followLag)
        c.flickSensitivity = Float(settings.flickSensitivity)
        c.smartFlick = settings.smartFlick
        c.rollRadians = SpatialMath.radians(Float(settings.rollDegrees))
        c.flat3D = !stereoDepth
        c.neckModel = settings.neckModel
        c.lateStart = lateStart
        c.presentDelay = presentDelay
        c.handoffOffset = handoffOffset
        c.followPresentation = followPresentation
        c.preview = preview
        return c
    }

    private func pushConfig() { compositor?.update(compositorConfig()) }

    private func pushCaptures() {
        compositor?.setScreens(virtualScreenList)
        compositor?.setCaptures(Dictionary(captures.map { ($0.index, $0) }, uniquingKeysWith: { _, b in b }))
    }

    private func forgetTextures(_ index: Int?) {
        if let compositor, compositor.isRunning {
            compositor.send(.forgetTextures(index))
        } else if let index {
            renderer?.forget(index: index)
        } else {
            renderer?.forgetAll()
        }
    }

    // MARK: Status text

    var statusSummary: String {
        switch glassesState {
        case .searching: return preview ? "Preview mode" : "Plug in your XREAL glasses"
        case .connecting(let n): return "Connecting to \(n)…"
        case .failed(let msg): return msg
        case .tracking(let n):
            if glassesDisplayName == nil && !preview { return "\(n): waiting for the display (USB-C video)" }
            return "\(n) · showing \(activeScreenCount) screen\(activeScreenCount == 1 ? "" : "s")"
        }
    }
}
