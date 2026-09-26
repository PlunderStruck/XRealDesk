import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let preview = CommandLine.arguments.contains("--preview")
    private lazy var app = AppController(preview: preview)
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var panelWindow: NSPanel?
    private let quickMenu = NSMenu()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "eyeglasses", accessibilityDescription: "XRealDesk")
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        quickMenu.delegate = self
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: ControlPanel(app: app, settings: app.settings, openSettings: { [weak self] in
                self?.popover.performClose(nil)
                self?.showSettings()
            }))

        app.onShowControlPanel = { [weak self] in self?.showControlPanel() }
        app.start()
        buildMainMenu()
        applyDockPolicy()
        app.settings.$showInDock.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.applyDockPolicy() } }
            .store(in: &cancellables)

        // Reflect health in the menu bar icon.
        app.$trackingHealthy.combineLatest(app.$glassesDisplayName)
            .receive(on: RunLoop.main)
            .sink { [weak self] healthy, display in
                guard let self else { return }
                self.statusItem?.button?.appearsDisabled = !(healthy && display != nil) && !self.preview
            }
            .store(in: &cancellables)

        // Scripting hook: show Settings on glasses screen N ("com.xrealdesk.showSettingsOn", object "N").
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.xrealdesk.showSettingsOn"),
                                                            object: nil, queue: .main) { [weak self] note in
            guard let self, let n = (note.object as? String).flatMap(Int.init) else { return }
            self.showSettings()
            if let screen = NSScreen.screens.first(where: { $0.localizedName == "XRealDesk \(n)" }), let w = self.settingsWindow {
                w.setFrameOrigin(NSPoint(x: screen.frame.midX - w.frame.width / 2, y: screen.frame.midY - w.frame.height / 2))
            }
        }

        // Diagnostics: render the control panel and settings window to PNGs in ~/Library/Logs/XRealDesk.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.xrealdesk.dumpUI"),
                                                            object: nil, queue: .main) { [weak self] _ in
            self?.dumpUI()
        }

        let firstRun = !UserDefaults.standard.bool(forKey: "didOnboard")
        if firstRun || !app.permissionGranted || preview {
            UserDefaults.standard.set(true, forKey: "didOnboard")
            showSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        app.shutdown()
    }

    /// Clicking the Dock icon opens the control panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControlPanel()
        return true
    }

    private func applyDockPolicy() {
        NSApp.setActivationPolicy(app.settings.showInDock ? .regular : .accessory)
        if app.settings.showInDock, let icon = NSImage(named: "AppIcon") ?? Bundle.main.image(forResource: "AppIcon") {
            NSApp.applicationIconImage = icon
        }
    }

    /// Menu in the top menu bar while XRealDesk is the active app.
    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "XRealDesk")
        appMenu.addItem(withTitle: "About XRealDesk", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(showSettingsAction), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide XRealDesk", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit XRealDesk", #selector(quit), key: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let glassesItem = NSMenuItem()
        let glassesMenu = NSMenu(title: "Glasses")
        glassesMenu.delegate = self   // rebuilt on open, same content as the right-click menu
        glassesItem.submenu = glassesMenu
        main.addItem(glassesItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    /// Popover under the menu-bar icon if it's visible; otherwise (icon hidden behind the notch,
    /// or opened from the Dock / ⌃⌥X) a floating panel near the mouse.
    func showControlPanel() {
        if let button = statusItem?.button, let w = button.window,
           w.occlusionState.contains(.visible), let screen = w.screen,
           screen.frame.contains(w.frame.origin), !NSApp.isActive || panelWindow?.isVisible != true {
            if popover.isShown { popover.performClose(nil); return }
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            return
        }
        if panelWindow == nil {
            let host = NSHostingController(rootView: ControlPanel(app: app, settings: app.settings, openSettings: { [weak self] in
                self?.panelWindow?.orderOut(nil)
                self?.showSettings()
            }))
            let p = NSPanel(contentViewController: host)
            p.title = "XRealDesk"
            p.styleMask = [.titled, .closable, .utilityWindow, .nonactivatingPanel]
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panelWindow = p
        }
        guard let p = panelWindow else { return }
        if p.isVisible && p.isKeyWindow { p.orderOut(nil); return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            let size = p.frame.size
            p.setFrameOrigin(NSPoint(x: min(max(mouse.x - size.width / 2, vf.minX), vf.maxX - size.width),
                                     y: min(max(mouse.y - size.height - 20, vf.minY), vf.maxY - size.height)))
        }
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusItem?.menu = quickMenu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc private func showControlPanelAction() {
        showControlPanel()
    }

    // MARK: Right-click menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: app.statusSummary, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(item("Control Panel…  ⌃⌥X", #selector(showControlPanelAction), key: "k"))
        menu.addItem(item("Recenter  ⌃⌥R", #selector(recenter)))
        let mode = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        for m in TrackingMode.allCases {
            let mi = item(m.title, #selector(setMode(_:)))
            mi.representedObject = m.rawValue
            mi.state = app.settings.trackingMode == m ? .on : .off
            modeMenu.addItem(mi)
        }
        mode.submenu = modeMenu
        menu.addItem(mode)
        let layouts = NSMenuItem(title: "Layout", action: nil, keyEquivalent: "")
        let layoutMenu = NSMenu()
        for p in LayoutPreset.all {
            let mi = item(p.title, #selector(applyPreset(_:)))
            mi.representedObject = p.id
            mi.image = NSImage(systemSymbolName: p.symbol, accessibilityDescription: nil)
            mi.state = app.settings.matchingPreset == p.id ? .on : .off
            layoutMenu.addItem(mi)
        }
        layouts.submenu = layoutMenu
        menu.addItem(layouts)
        let gaze = item("Cursor Follows Gaze", #selector(toggleGaze))
        gaze.state = app.settings.cursorFollowsGaze ? .on : .off
        menu.addItem(gaze)
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(showSettingsAction), key: ","))
        menu.addItem(item("Show Log", #selector(showLog)))
        menu.addItem(item("Save Glasses Snapshot", #selector(snapshot)))
        menu.addItem(.separator())
        menu.addItem(item("Quit XRealDesk", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func recenter() { app.recenter() }
    @objc private func setMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let m = TrackingMode(rawValue: raw) { app.setMode(m) }
    }
    @objc private func applyPreset(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String, let p = LayoutPreset.all.first(where: { $0.id == id }) {
            app.settings.apply(p)
        }
    }
    @objc private func toggleGaze() { app.settings.cursorFollowsGaze.toggle() }
    @objc private func showSettingsAction() { showSettings() }
    @objc private func snapshot() { app.requestSnapshot() }
    @objc private func showLog() { NSWorkspace.shared.open(Log.fileURL) }
    @objc private func quit() { NSApp.terminate(nil) }

    private func dumpUI() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/XRealDesk")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let host = NSHostingView(rootView: ControlPanel(app: app, settings: app.settings, openSettings: {}))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let offscreen = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        offscreen.contentView = host
        offscreen.appearance = NSAppearance(named: .darkAqua)
        offscreen.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        offscreen.orderFrontRegardless()
        showSettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            func save(_ view: NSView?, _ name: String) {
                guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
            }
            save(host, "ui-control-panel.png")
            save(self?.settingsWindow?.contentView, "ui-settings.png")
            offscreen.orderOut(nil)
            Log.info("Saved UI renders to \(dir.path)")
        }
    }

    private func showSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(app: app, settings: app.settings, login: LoginItemModel()))
            let w = NSWindow(contentViewController: host)
            w.title = "XRealDesk"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 560, height: 820))
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

// Helper mode, run by the app as it quits: wait for it to exit, then set the glasses to mirror the
// main screen for the session (their normal state when XRealDesk isn't running).
if CommandLine.arguments.contains("--mirror-glasses") {
    let quittingApp = getppid()   // the instance that's quitting (captured before it exits)
    Thread.sleep(forTimeInterval: 2.0)
    // XRealDesk relaunched meanwhile: it has already set the glasses up; mirroring now would pull
    // them out from under it.
    let relaunched = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        .contains { $0.processIdentifier != getpid() && $0.processIdentifier != quittingApp && !$0.isTerminated }
    if !relaunched, let g = DisplayConfigurator.findGlassesDisplay() {
        DisplayConfigurator.mirror(g, of: DisplayConfigurator.homeDisplay(excluding: g))
    }
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
