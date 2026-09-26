import SwiftUI
import ServiceManagement
import XRCore

/// Login-item state. (A plain ObservableObject: the Command Line Tools toolchain lacks the
/// SwiftUI macro plugin that newer SDKs use for @State.)
final class LoginItemModel: ObservableObject {
    @Published var enabled = SMAppService.mainApp.status == .enabled
    @Published var error: String?

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = "Couldn't change login item: \(error.localizedDescription). Move XRealDesk to /Applications first."
        }
        enabled = SMAppService.mainApp.status == .enabled
    }
}

final class SettingsNav: ObservableObject { @Published var tab = 0 }

struct SettingsView: View {
    @ObservedObject var nav: SettingsNav
    @ObservedObject var app: AppController
    @ObservedObject var settings: Settings
    @ObservedObject var login: LoginItemModel
    var openSetup: (SetupModel.Step?) -> Void = { _ in }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsView.pages, id: \.id) { page in
                    SidebarRow(page: page, selected: nav.tab == page.id) { nav.tab = page.id }
                }
                Spacer()
            }
            .padding(.horizontal, 10).padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .navigationSplitViewColumnWidth(min: 180, ideal: 190, max: 220)
        } detail: {
            Group {
                switch nav.tab {
                case 1: screens
                case 2: tracking
                case 3: picture
                case 4: shortcuts
                default: general
                }
            }
            .navigationTitle(SettingsView.pages.first { $0.id == nav.tab }?.title ?? "General")
        }
        .frame(width: 760, height: 620)
        .tint(Brand.accent)
    }

    struct Page { let id: Int; let title: String; let symbol: String; let colors: [Color] }

    /// Sidebar entry drawn by hand, so the selection uses the brand color, not the system accent.
    struct SidebarRow: View {
        let page: Page
        let selected: Bool
        let action: () -> Void
        @StateObject private var hover = HoverState()

        var body: some View {
            Button(action: action) {
                HStack(spacing: 10) {
                    IconBadge(symbol: page.symbol, colors: page.colors, size: 24)
                    Text(page.title).font(.system(size: 13, weight: selected ? .semibold : .medium))
                    Spacer()
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Brand.accent.opacity(0.28)) : AnyShapeStyle(Color.primary.opacity(hover.on ? 0.06 : 0))))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover.on = $0 }
        }
    }
    static let pages: [Page] = [
        Page(id: 0, title: "General", symbol: "gearshape.fill", colors: [Color(white: 0.62), Color(white: 0.45)]),
        Page(id: 1, title: "Screens", symbol: "rectangle.split.3x1.fill", colors: [Brand.indigo, Brand.cyan]),
        Page(id: 2, title: "Tracking", symbol: "move.3d", colors: [Color(red: 1, green: 0.62, blue: 0.2), Color(red: 1, green: 0.42, blue: 0.2)]),
        Page(id: 3, title: "Picture", symbol: "sparkles", colors: [Color(red: 0.75, green: 0.4, blue: 1), Color(red: 0.55, green: 0.3, blue: 0.95)]),
        Page(id: 4, title: "Shortcuts", symbol: "command", colors: [Color(red: 0.3, green: 0.8, blue: 0.55), Color(red: 0.15, green: 0.65, blue: 0.45)]),
    ]

    // MARK: General

    private var general: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    PanelHeader(app: app, live: app.live)
                }
                HStack {
                    Button { openSetup(nil) } label: { Label("Setup assistant…", systemImage: "wand.and.stars") }
                    Spacer()
                    if settings.isRecommended {
                        Label("Using recommended settings", systemImage: "checkmark.seal.fill")
                            .font(.callout).foregroundStyle(.green)
                    } else {
                        Button { settings.applyRecommended() } label: { Label("Use recommended settings", systemImage: "star") }
                            .help("HiDPI, Smart mode, 120 Hz, best picture and tracking. Keeps your screen layout.")
                    }
                }
            }
            Section("Permissions") {
                PermissionRows(app: app)
                    .listRowInsets(EdgeInsets())
            }
            Section("When…") {
                Picker("You take the glasses off", selection: $settings.glassesOffMoveDelay) {
                    Text("Just pause").tag(-1.0)
                    Text("Move windows to the Mac right away").tag(0.0)
                    Text("Move windows to the Mac after 10 s").tag(10.0)
                    Text("Move windows to the Mac after 30 s").tag(30.0)
                }
                Toggle("Put windows back on their glasses screens after restarts, unplugging or sleep", isOn: $settings.windowMemory)
                Toggle("XRealDesk quits: set the glasses back to mirroring your Mac", isOn: $settings.mirrorWhenQuitting)
            }
            Section("App") {
                Toggle("Launch at login", isOn: Binding(get: { login.enabled }, set: { login.set($0) }))
                if let e = login.error { Text(e).font(.caption).foregroundStyle(.red) }
                Toggle("Show in the Dock (click the icon for the control panel)", isOn: $settings.showInDock)
                Toggle("Messages in the glasses (recentered, size, …)", isOn: $settings.showHUD)
                Toggle("Keyboard shortcuts (⌃⌥ + key)", isOn: $settings.hotkeysEnabled)
                Toggle("Switch the glasses to extended while XRealDesk runs (needed to show your screens)", isOn: $settings.autoExtendDisplay)
                Toggle("Diagnostic log (for troubleshooting; otherwise only errors are saved)", isOn: $settings.diagnosticLog)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Screens

    private var screens: some View {
        Form {
            Section("Layout") {
                LayoutMap(app: app, live: app.live, settings: settings).frame(height: 150)
                PresetTiles(settings: settings, columns: 6, height: 44)
                Stepper("Number of screens: \(settings.screenCount)", value: $settings.screenCount, in: 1...Settings.maxScreens)
                Picker("Rows", selection: $settings.rows) {
                    Text("One").tag(1); Text("Two").tag(2); Text("Three").tag(3)
                }
                .pickerStyle(.segmented)
                .disabled(settings.screenCount < 2)
                HStack {
                    ValueSlider(symbol: "arrow.up.left.and.arrow.down.right", title: "Size", value: $settings.screenWidthDegrees,
                                range: 16...100, step: 1) { String(format: "%.0f°", $0) }
                    Button("Sharpest") { settings.screenWidthDegrees = min(100, max(16, app.pixelPerfectWidthDegrees().rounded())) }
                        .help("One screen pixel per glasses pixel: the crispest text")
                }
                ValueSlider(symbol: "rectangle.portrait.arrowtriangle.2.outward", title: "Curve", value: $settings.curve,
                            range: 0...1, step: 0.05) { $0 < 0.01 ? "Flat" : String(format: "%.0f%%", $0 * 100) }
                ValueSlider(symbol: "arrow.up.and.down", title: "Height", value: $settings.tiltDegrees,
                            range: -30...30, step: 1) { String(format: "%+.0f°", $0) }
                ValueSlider(symbol: "arrow.left.and.right", title: "Gap", value: $settings.gapDegrees,
                            range: 0...10, step: 0.5) { String(format: "%.1f°", $0) }
            }
            Section("Each screen") {
                Picker("Resolution", selection: $settings.resolutionID) {
                    ForEach(ResolutionPreset.all) { Text($0.title).tag($0.id) }
                }
                Toggle("HiDPI: much sharper text (recommended)", isOn: $settings.hiDPI)
                Picker("Refresh rate", selection: $settings.refreshRate) {
                    Text("60 Hz").tag(60); Text("120 Hz").tag(120)
                }
                .pickerStyle(.segmented)
            }
            Section("Mouse and main display") {
                HStack(spacing: 8) {
                    ForEach(ScreenPlacement.allCases) { p in
                        Tile(title: p.title.replacingOccurrences(of: " laptop", with: ""), selected: settings.placement == p,
                             height: 64, action: { settings.placement = p }) {
                            PlacementDiagram(placement: p).frame(width: 60, height: 36)
                        }
                    }
                }
                Text(settings.placement == .custom
                     ? "Arrange the XRealDesk screens in System Settings → Displays, then save. XRealDesk keeps them there."
                     : "The edge of your Mac's screen the mouse crosses to reach the glasses. XRealDesk keeps it in place.")
                    .font(.caption).foregroundStyle(.secondary)
                if settings.placement == .custom {
                    HStack {
                        Button("Open Displays Settings…") { app.openDisplaySettings() }
                        Button("Save current arrangement") { app.saveCurrentArrangement() }
                    }
                }
                Toggle("Make the middle glasses screen the main display", isOn: $settings.glassesIsMain)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Tracking

    private var tracking: some View {
        Form {
            Section("Mode") {
                ModeTiles(app: app, settings: settings, height: 60, showDetail: true)
                Text(settings.trackingMode.detail).font(.caption).foregroundStyle(.secondary)
                if settings.trackingMode == .smart {
                    Toggle("A quick flick of your head drags the screens along", isOn: $settings.smartFlick)
                    if settings.smartFlick {
                        ValueSlider(symbol: "hand.draw", title: "Flick", value: $settings.flickSensitivity, range: 0...1, step: 0.05) {
                            String(format: "%.0f%%", $0 * 100)
                        }
                    }
                }
                if settings.trackingMode == .smoothFollow || settings.trackingMode == .smart {
                    ValueSlider(symbol: "hare", title: "Follow", value: Binding(get: { 1.05 - settings.followLag },
                                                                               set: { settings.followLag = 1.05 - $0 }),
                                range: 0.05...1.0, step: 0.05) { String(format: "%.0f%%", $0 * 100) }
                }
                Button { app.recenter() } label: { Label("Recenter now  (⌃⌥R)", systemImage: "scope") }
            }
            Section("Your eyes drive the Mac") {
                Toggle("The cursor jumps to the screen you look at", isOn: $settings.cursorFollowsGaze)
                Toggle("Typing goes to the window you last used on that screen", isOn: $settings.keyboardFollowsGaze)
                    .disabled(!settings.cursorFollowsGaze)
            }
            Section("Straighten") {
                ValueSlider(symbol: "level", title: "Rotation", value: $settings.rollDegrees, range: -15...15, step: 0.5) {
                    $0 == 0 ? "Level" : String(format: "%+.1f°", $0)
                }
                Text("If the glasses sit crooked on your face, rotate the picture until the screens look level (⌃⌥, and ⌃⌥.).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                DisclosureGroup("Advanced tuning") {
                    ValueSlider(symbol: "timer", title: "Prediction", value: $settings.predictionMs, range: 0...40, step: 1) {
                        String(format: "%.0f ms", $0)
                    }
                    Text("Screens lag behind when you turn: raise it. They overshoot: lower it. Recommended: 14 ms.")
                        .font(.caption).foregroundStyle(.secondary)
                    ValueSlider(symbol: "scope", title: "Stability", value: $settings.stabilityDegrees, range: 0...0.4, step: 0.02) {
                        $0 < 0.005 ? "Off" : String(format: "%.2f°", $0)
                    }
                    Text("Screens ignore head wobble smaller than this (typing, breathing). Recommended: 0.03°.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Picture

    private var picture: some View {
        Form {
            Section("Picture") {
                ValueSlider(symbol: "sun.max", title: "Brightness", value: $settings.brightness, range: 0.2...1, step: 0.05) {
                    String(format: "%.0f%%", $0 * 100)
                }
                Picker("Quality", selection: $settings.renderScale) {
                    Text("Standard").tag(1.0); Text("High").tag(1.5); Text("Ultra").tag(2.0)
                }
                .pickerStyle(.segmented)
                Toggle("Lens correction (your glasses' factory calibration)", isOn: $settings.lensCorrection)
                ValueSlider(symbol: "wand.and.rays", title: "Sharpen", value: $settings.sharpen, range: 0...1, step: 0.05) {
                    $0 < 0.01 ? "Off" : String(format: "%.0f%%", $0 * 100)
                }
            }
            Section("Focus") {
                ValueSlider(symbol: "circle.lefthalf.filled", title: "Dim others", value: $settings.focusDim, range: 0...0.8, step: 0.05) {
                    $0 < 0.01 ? "Off" : String(format: "%.0f%%", $0 * 100)
                }
                Toggle("Glow around the screen with the cursor", isOn: $settings.highlightCursorScreen)
                ValueSlider(symbol: "app", title: "Corners", value: $settings.cornerRadius, range: 0...0.06, step: 0.002) {
                    $0 < 0.001 ? "Square" : String(format: "%.0f", $0 * 1000)
                }
                Button("Reset picture") { settings.resetLook() }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Shortcuts

    private var shortcuts: some View {
        Form {
            Section("Keyboard shortcuts") {
                ForEach(Shortcuts.all, id: \.0) { ShortcutRow(keys: $0.0, text: $0.1) }
            }
            Section("Glasses buttons") {
                ShortcutRow(keys: "Brightness +/−", text: "Glasses brightness (tap)")
                ShortcutRow(keys: "Hold +  3 s", text: "3D side-by-side mode on / off (60 Hz)")
            }
        }
        .formStyle(.grouped)
    }
}
