import AppKit
import ApplicationServices
import CoreGraphics

// Maps an Accessibility window element to its CGWindowID. Private but long-stable; used by every
// macOS window manager (Rectangle, AltTab, yabai…).
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

// Creates an Accessibility element from an app's remote token. The normal window list only covers
// the current Space; full-screen windows live in Spaces of their own, and this is how window
// managers (AltTab…) reach them.
@_silgen_name("_AXUIElementCreateWithRemoteToken")
private func _AXUIElementCreateWithRemoteToken(_ token: CFData) -> Unmanaged<AXUIElement>?

/// Two jobs:
///  1. Window memory: remembers which windows live on which glasses screen (and where), and puts
///     them back whenever the screens return: after a restart, unplug/replug, sleep or a
///     resolution change. Windows you drag off the glasses yourself are forgotten, never fought.
///  2. Keyboard focus follows your eyes: when the cursor jumps to the screen you look at, the
///     window you were last using on that screen gets keyboard focus.
///
/// Reading window positions needs no permission. Moving/raising other apps' windows needs
/// Accessibility; without it, focus falls back to activating the app.
final class WindowKeeper {

    struct Entry: Codable {
        var windowID: UInt32
        var pid: Int32
        var bundleID: String?
        var title: String?
        var screen: Int
        /// Frame relative to its screen (0…1), so it survives resolution changes.
        var rx, ry, rw, rh: Double
        var updated: Date
        /// In native full screen (its own Space) on that screen.
        var fullScreen: Bool? = nil
    }

    private(set) var entries: [UInt32: Entry] = [:]
    /// Window you were last using on each screen.
    private var lastFocused: [Int: CGWindowID] = [:]
    /// While screens are being torn down / restored, positions are in flux: don't record them.
    var suspended = false
    private let axQueue = DispatchQueue(label: "XRealDesk.windows", qos: .userInitiated)
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let storeKey = "windowMemory.entries"

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt (once per app signature) pointing at Accessibility settings.
    @discardableResult
    static func requestTrust() -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    }

    init() { load() }

    // MARK: Window list (no permission needed)

    struct LiveWindow {
        let id: CGWindowID
        let pid: pid_t
        let bounds: CGRect
        let title: String?
        let onScreen: Bool
    }

    /// Normal app windows, front to back.
    private func liveWindows(onScreenOnly: Bool) -> [LiveWindow] {
        let opts: CGWindowListOption = onScreenOnly ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionAll, .excludeDesktopElements]
        let list = (CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]) ?? []
        return list.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let wd = b["Width"], let ht = b["Height"],
                  wd >= 80, ht >= 60,
                  // Untitled strips (browser popups, toolbars, infobars) aren't real windows to remember.
                  !(((w[kCGWindowName as String] as? String) ?? "").isEmpty && ht < 200),
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01 else { return nil }
            return LiveWindow(id: id, pid: pid, bounds: CGRect(x: x, y: y, width: wd, height: ht),
                              title: w[kCGWindowName as String] as? String,
                              onScreen: (w[kCGWindowIsOnscreen as String] as? Bool) ?? false)
        }
    }

    private static func screenIndex(of rect: CGRect, screens: [(index: Int, id: CGDirectDisplayID)]) -> Int? {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        return screens.first { CGDisplayBounds($0.id).contains(c) }?.index
    }

    // MARK: 1. Memory

    /// Windows seen on the glasses in the previous snapshot, and when that was.
    private var onGlassesLastSnapshot = Set<UInt32>()
    private var lastSnapshotTime = Date.distantPast

    /// Record where windows are. Call periodically while the glasses screens are up.
    /// - Parameter displaysStableFor: seconds since the last display change. A window only counts
    ///   as "you moved it off the glasses" (and is forgotten) when displays have been stable, so
    ///   windows macOS shuffled around during a display change are remembered and put back.
    func snapshot(screens: [(index: Int, id: CGDirectDisplayID)], displaysStableFor: TimeInterval) {
        guard !suspended, !screens.isEmpty else { return }
        let now = Date()
        // Nothing about the displays changed since the previous snapshot (snapshots are now rare:
        // only when the glasses' windows change), so a window that left the glasses was moved by you.
        let continuous = displaysStableFor > now.timeIntervalSince(lastSnapshotTime)
        let live = liveWindows(onScreenOnly: false)
        let liveIDs = Set(live.map(\.id))
        let presentScreens = Set(screens.map(\.index))
        var seen = Set<UInt32>()
        for w in live {
            guard let i = WindowKeeper.screenIndex(of: w.bounds, screens: screens),
                  let s = screens.first(where: { $0.index == i }) else { continue }
            // A window whose own screen is gone for now (fewer screens) is only visiting: it keeps
            // its home and goes back when that screen returns.
            if let old = entries[w.id], !presentScreens.contains(old.screen) {
                entries[w.id]?.updated = now
                seen.insert(w.id)
                continue
            }
            let sb = CGDisplayBounds(s.id)
            let bundle = entries[w.id]?.bundleID ?? NSRunningApplication(processIdentifier: w.pid)?.bundleIdentifier
            let full = abs(w.bounds.minX - sb.minX) < 1 && abs(w.bounds.minY - sb.minY) < 1
                && abs(w.bounds.width - sb.width) < 1 && abs(w.bounds.height - sb.height) < 1
            entries[w.id] = Entry(windowID: w.id, pid: w.pid, bundleID: bundle, title: w.title, screen: i,
                                  rx: (w.bounds.minX - sb.minX) / sb.width, ry: (w.bounds.minY - sb.minY) / sb.height,
                                  rw: w.bounds.width / sb.width, rh: w.bounds.height / sb.height, updated: now,
                                  fullScreen: full)
            seen.insert(w.id)
        }
        // Forget windows that were closed, or that you dragged off the glasses yourself: it was on
        // the glasses a moment ago, its screen is still there, and no display change happened.
        // Anything else (screens recreated, display glitches) is macOS moving it, so remember it.
        for (id, e) in entries where !seen.contains(id) {
            if !liveIDs.contains(id) {
                if NSRunningApplication(processIdentifier: e.pid) != nil { entries[id] = nil }   // closed
            } else if presentScreens.contains(e.screen), continuous, onGlassesLastSnapshot.contains(id),
                      displaysStableFor > 5 {
                entries[id] = nil   // moved off by the user
            }
        }
        onGlassesLastSnapshot = seen
        lastSnapshotTime = now
        // Old entries from apps that quit long ago.
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        entries = entries.filter { $0.value.updated > cutoff }
    }

    func save() {
        if let data = try? JSONEncoder().encode(Array(entries.values)) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let list = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        entries = Dictionary(list.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Move remembered windows that aren't on the glasses back to their screens.
    func restore(screens: [(index: Int, id: CGDirectDisplayID)], completion: @escaping (Int) -> Void) {
        guard WindowKeeper.isTrusted else {
            if !entries.isEmpty { Log.info("Window memory: \(entries.count) window(s) to restore, but Accessibility isn't granted") }
            completion(0)
            return
        }
        let live = liveWindows(onScreenOnly: false)
        var jobs: [(entry: Entry, target: CGRect, current: LiveWindow?)] = []
        var skippedNoScreen = 0, skippedAlreadyThere = 0
        for e in entries.values {
            guard let s = screens.first(where: { $0.index == e.screen }) else { skippedNoScreen += 1; continue }
            let sb = CGDisplayBounds(s.id)
            var target = CGRect(x: sb.minX + e.rx * sb.width, y: sb.minY + e.ry * sb.height,
                                width: e.rw * sb.width, height: e.rh * sb.height)
            // Keep it on the screen even if the saved frame came from a larger resolution.
            target.size.width = min(target.width, sb.width)
            target.size.height = min(target.height, sb.height)
            target.origin.x = min(max(target.minX, sb.minX), sb.maxX - target.width)
            target.origin.y = min(max(target.minY, sb.minY), sb.maxY - target.height)
            let current = live.first { $0.id == e.windowID }
            // Only skip a window that's on its own screen: after the screens are recreated, macOS
            // often drops windows back onto glasses screens, just not the right ones.
            if let current, WindowKeeper.screenIndex(of: current.bounds, screens: screens) == e.screen { skippedAlreadyThere += 1; continue }
            jobs.append((e, target, current))
        }
        Log.info("Window memory: \(entries.count) remembered, \(jobs.count) to put back (\(skippedAlreadyThere) already on the glasses, \(skippedNoScreen) for screens that don't exist now)")
        guard !jobs.isEmpty else { completion(0); return }
        axQueue.async { [weak self] in
            guard let self else { return }
            var moved = 0
            var unmatched: [UInt32] = []
            var taken = Set<CGWindowID>()
            for job in jobs {
                if let win = self.axWindow(for: job.entry, live: job.current != nil, taken: taken) {
                    var id: CGWindowID = 0
                    if _AXUIElementGetWindow(win, &id) == .success { taken.insert(id) }
                    self.move(win, to: job.target, fullScreen: job.entry.fullScreen == true)
                    moved += 1
                } else {
                    unmatched.append(job.entry.windowID)
                }
            }
            DispatchQueue.main.async {
                // Windows we can't find any more (app restarted and title changed, closed…) are dropped.
                for id in unmatched where NSRunningApplication(processIdentifier: self.entries[id]?.pid ?? 0) == nil {
                    self.entries[id] = nil
                }
                Log.info("Window memory: restored \(moved) window(s) to the glasses")
                completion(moved)
            }
        }
    }

    /// Fewer screens: move the windows of the screens about to go onto the ones that stay (screen
    /// k → k mod remaining, same place and size relative to the screen) before macOS scatters them
    /// onto the Mac. They keep their home screen in memory and go back when it returns.
    /// Full-screen windows can't be moved; macOS relocates their Space, and restore brings them back.
    func evacuate(from leaving: [(index: Int, id: CGDirectDisplayID)], to staying: [(index: Int, id: CGDirectDisplayID)],
                  completion: @escaping (Int) -> Void) {
        guard WindowKeeper.isTrusted, !leaving.isEmpty, !staying.isEmpty else { completion(0); return }
        let live = liveWindows(onScreenOnly: false)
        var jobs: [(pid: pid_t, id: CGWindowID, target: CGRect)] = []
        for w in live {
            guard let i = WindowKeeper.screenIndex(of: w.bounds, screens: leaving),
                  let from = leaving.first(where: { $0.index == i }) else { continue }
            let fb = CGDisplayBounds(from.id)
            if abs(w.bounds.width - fb.width) < 1 && abs(w.bounds.height - fb.height) < 1 && abs(w.bounds.minY - fb.minY) < 1 { continue }
            let to = staying[i % staying.count]
            let tb = CGDisplayBounds(to.id)
            var r = CGRect(x: tb.minX + (w.bounds.minX - fb.minX) / fb.width * tb.width,
                           y: tb.minY + (w.bounds.minY - fb.minY) / fb.height * tb.height,
                           width: min(w.bounds.width / fb.width * tb.width, tb.width),
                           height: min(w.bounds.height / fb.height * tb.height, tb.height))
            r.origin.x = min(max(r.minX, tb.minX), tb.maxX - r.width)
            r.origin.y = min(max(r.minY, tb.minY), tb.maxY - r.height)
            jobs.append((w.pid, w.id, r))
        }
        guard !jobs.isEmpty else { completion(0); return }
        axQueue.async { [weak self] in
            guard let self else { return }
            var moved = 0
            for j in jobs {
                if let win = self.axWindow(pid: j.pid, windowID: j.id) { self.move(win, to: j.target); moved += 1 }
            }
            DispatchQueue.main.async {
                Log.info("Window memory: moved \(moved) window(s) off the screens being removed")
                completion(moved)
            }
        }
    }

    /// Test hook: move every remembered window onto `display` (as macOS does when screens vanish).
    func debugEvict(to display: CGDirectDisplayID, completion: @escaping () -> Void) {
        let list = Array(entries.values)
        let b = CGDisplayBounds(display)
        let trusted = WindowKeeper.isTrusted
        axQueue.async { [weak self] in
            guard let self else { return }
            var report: [String] = []
            for (i, e) in list.enumerated() {
                let wins = self.axWindows(pid: e.pid)
                if let w = self.axWindow(for: e, live: true) {
                    let r = self.move(w, to: CGRect(x: b.minX + 40 + CGFloat(i) * 30, y: b.minY + 60 + CGFloat(i) * 30,
                                                    width: min(800, b.width - 100), height: min(500, b.height - 120)))
                    report.append("\(e.bundleID ?? "?")#\(e.windowID): moved (\(r))")
                } else {
                    report.append("\(e.bundleID ?? "?")#\(e.windowID): no AX match among \(wins.count) window(s)")
                }
            }
            Log.info("Test evict (trusted \(trusted)): " + report.joined(separator: "; "))
            DispatchQueue.main.async(execute: completion)
        }
    }

    /// Test hook: move a specific window to `rect` (global coordinates). Reports the AX result.
    func debugPlace(pid: pid_t, windowID: CGWindowID, rect: CGRect, completion: @escaping (String) -> Void) {
        axQueue.async { [weak self] in
            guard let self else { return }
            let result: String
            if let w = self.axWindow(pid: pid, windowID: windowID) {
                result = "\(self.move(w, to: rect).rawValue)"
            } else {
                result = "no AX window (of \(self.axWindows(pid: pid).count))"
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Where a window currently is (global coordinates), if it exists.
    func currentFrame(of id: CGWindowID) -> CGRect? {
        liveWindows(onScreenOnly: false).first { $0.id == id }?.bounds
    }

    /// Test hook: frontmost on-screen window id of an app.
    func frontWindowID(pid: pid_t) -> CGWindowID? {
        liveWindows(onScreenOnly: true).first { $0.pid == pid }?.id
    }

    // MARK: 2. Keyboard focus follows your eyes

    /// Remember which window you're using on which screen. Uses the cheap on-screen window list
    /// (~3 ms). Returns whether the windows on the glasses changed (moved, resized, opened, closed)
    /// since the last call: only then is the full (all-Spaces) list worth fetching for memory —
    /// that one can hold WindowServer for up to a quarter second with many windows open.
    @discardableResult
    func noteFocus(screens: [(index: Int, id: CGDirectDisplayID)]) -> Bool {
        let live = liveWindows(onScreenOnly: true)
        var sig = Hasher()
        for w in live where WindowKeeper.screenIndex(of: w.bounds, screens: screens) != nil {
            sig.combine(w.id); sig.combine(Int(w.bounds.minX)); sig.combine(Int(w.bounds.minY))
            sig.combine(Int(w.bounds.width)); sig.combine(Int(w.bounds.height))
        }
        let signature = sig.finalize()
        let changed = signature != lastGlassesSignature
        lastGlassesSignature = signature
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, front != ownPID,
           let w = live.first(where: { $0.pid == front }),
           let i = WindowKeeper.screenIndex(of: w.bounds, screens: screens) {
            lastFocused[i] = w.id
        }
        return changed
    }
    private var lastGlassesSignature = 0

    /// Give keyboard focus to the window you last used on `screen` (or its frontmost window).
    func focus(screen: Int, displayID: CGDirectDisplayID) {
        let live = liveWindows(onScreenOnly: true)
        let bounds = CGDisplayBounds(displayID)
        let onScreen = live.filter { bounds.contains(CGPoint(x: $0.bounds.midX, y: $0.bounds.midY)) }
        guard let target = onScreen.first(where: { $0.id == lastFocused[screen] }) ?? onScreen.first else { return }
        // Already focused? (frontmost app, and its frontmost window is this one)
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid,
           live.first(where: { $0.pid == target.pid })?.id == target.id { return }
        let trusted = WindowKeeper.isTrusted
        axQueue.async { [weak self] in
            guard let self else { return }
            if trusted, let win = self.axWindow(pid: target.pid, windowID: target.id) {
                AXUIElementPerformAction(win, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
            }
            DispatchQueue.main.async {
                NSRunningApplication(processIdentifier: target.pid)?.activate()
            }
        }
        lastFocused[screen] = target.id
    }

    // MARK: Accessibility helpers (axQueue)

    private func axApp(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)   // a hung app must not stall us
        return app
    }

    private func axWindows(pid: pid_t) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp(pid), kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [] }
        return list
    }

    private func axWindow(pid: pid_t, windowID: CGWindowID) -> AXUIElement? {
        let match: (AXUIElement) -> Bool = { w in
            var id: CGWindowID = 0
            return _AXUIElementGetWindow(w, &id) == .success && id == windowID
        }
        return axWindows(pid: pid).first(where: match) ?? axWindowsAllSpaces(pid: pid).first(where: match)
    }

    /// Every window of an app, including ones in other Spaces (full screen), found by walking the
    /// app's element tokens. Slower; only used when the normal list doesn't have the window.
    private func axWindowsAllSpaces(pid: pid_t) -> [AXUIElement] {
        var found: [AXUIElement] = []
        var token = Data(count: 20)
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid.littleEndian) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: UInt32(0x636f_636f).littleEndian) { Data($0) })
        let deadline = Date().addingTimeInterval(0.2)
        for element: UInt64 in 0..<1000 {
            if element % 50 == 0, Date() > deadline { break }
            token.replaceSubrange(12..<20, with: withUnsafeBytes(of: element.littleEndian) { Data($0) })
            guard let el = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue() else { continue }
            AXUIElementSetMessagingTimeout(el, 0.1)
            var role: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role) == .success,
               (role as? String) == kAXWindowRole as String {
                found.append(el)
            }
        }
        return found
    }

    /// Find the live AX window for a memory entry: same window ID if the app is still the same
    /// process, otherwise same app (bundle) + same title.
    /// `taken`: windows already matched to another entry in this batch (two "zsh" Terminals must
    /// go to two different windows, not the first one twice).
    private func axWindow(for e: Entry, live: Bool, taken: Set<CGWindowID> = []) -> AXUIElement? {
        if live, let w = axWindow(pid: e.pid, windowID: e.windowID) { return w }
        guard let bundle = e.bundleID, let title = e.title, !title.isEmpty else { return nil }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundle) {
            for w in axWindows(pid: app.processIdentifier) {
                var id: CGWindowID = 0
                if _AXUIElementGetWindow(w, &id) == .success, taken.contains(id) { continue }
                var t: CFTypeRef?
                if AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t) == .success, (t as? String) == title {
                    return w
                }
            }
        }
        return nil
    }

    /// Diagnostics, moves nothing: for every remembered window, where it is now and whether it can
    /// be found again (by window ID, or by app + title).
    func report(screens: [(index: Int, id: CGDirectDisplayID)]) {
        let live = liveWindows(onScreenOnly: false)
        let trusted = WindowKeeper.isTrusted
        Log.info("Window memory report: \(entries.count) remembered, \(live.count) live windows, Accessibility \(trusted)")
        for e in entries.values.sorted(by: { $0.screen < $1.screen }) {
            let current = live.first { $0.id == e.windowID }
            let now = current.flatMap { WindowKeeper.screenIndex(of: $0.bounds, screens: screens) }
            let app = e.bundleID ?? "pid \(e.pid)"
            let alive = NSRunningApplication(processIdentifier: e.pid) != nil
            axQueue.async { [weak self] in
                guard let self else { return }
                let byID = trusted && self.axWindow(pid: e.pid, windowID: e.windowID) != nil
                let byTitle = trusted && self.axWindow(for: e, live: false) != nil
                Log.info("  \(app) '\((e.title ?? "").prefix(40))' #\(e.windowID): remembered screen \(e.screen + 1), now \(now.map { "screen \($0 + 1)" } ?? (current == nil ? "not listed" : "off the glasses")), process \(alive ? "running" : "gone"), found by ID \(byID), by title \(byTitle)")
            }
        }
    }

    /// Moves a window that should end up in native full screen: leave full screen (a window can't
    /// be moved while it has its own Space), move it onto the right screen, enter full screen there.
    @discardableResult
    private func move(_ win: AXUIElement, to r: CGRect, fullScreen: Bool) -> AXError {
        let key = "AXFullScreen" as CFString
        func isFull() -> Bool {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(win, key, &v) == .success && (v as? Bool) == true
        }
        if isFull() {
            AXUIElementSetAttributeValue(win, key, kCFBooleanFalse)
            for _ in 0..<30 where isFull() { Thread.sleep(forTimeInterval: 0.05) }
            Thread.sleep(forTimeInterval: 0.6)   // the exit animation finishes after the flag flips
        }
        let result = move(win, to: r)
        if fullScreen {
            Thread.sleep(forTimeInterval: 0.2)
            AXUIElementSetAttributeValue(win, key, kCFBooleanTrue)
        }
        return result
    }

    /// Returns the AXError of the final position set (for diagnostics).
    @discardableResult
    private func move(_ win: AXUIElement, to r: CGRect) -> AXError {
        var minimized: CFTypeRef?
        if AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &minimized) == .success,
           (minimized as? Bool) == true { return .success }
        var origin = r.origin, size = r.size
        var result = AXError.failure
        if let pos = AXValueCreate(.cgPoint, &origin) { result = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, pos) }
        if let sz = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sz) }
        // Some apps clamp the position before the size fits; set it again.
        if let pos = AXValueCreate(.cgPoint, &origin) { result = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, pos) }
        return result
    }
}
