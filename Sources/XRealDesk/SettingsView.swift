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

struct SettingsView: View {
    @ObservedObject var app: AppController
    @ObservedObject var settings: Settings
    @ObservedObject var login: LoginItemModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StatusHeader(app: app)
                .padding(20)
            Divider()
            Form {
                Section("Layout") {
                    LayoutMap(app: app, live: app.live, settings: settings).frame(height: 170)
                    HStack {
                        ForEach(LayoutPreset.all) { p in
                            Button { settings.apply(p) } label: {
                                Label(p.title, systemImage: p.symbol).labelStyle(.titleAndIcon).font(.caption)
                            }
                        }
                    }
                    Stepper(value: $settings.screenCount, in: 1...Settings.maxScreens) {
                        LabeledContent("Number of screens", value: "\(settings.screenCount)")
                    }
                    Picker("Rows", selection: $settings.rows) {
                        Text("One row").tag(1)
                        Text("Two rows").tag(2)
                        Text("Three rows").tag(3)
                    }
                    .disabled(settings.screenCount < 2)
                    LabeledSlider(title: "Screen size", value: $settings.screenWidthDegrees, range: 16...100, step: 1,
                                  format: { String(format: "%.0f°", $0) },
                                  hint: "The glasses show about \(Int(app.deviceInfo?.calibration.fov.x ?? 39))° across. Shortcut: ⌃⌥= / ⌃⌥-")
                    Button("Sharpest size for this resolution (1:1 pixels)") {
                        settings.screenWidthDegrees = min(100, max(16, app.pixelPerfectWidthDegrees().rounded()))
                    }
                    LabeledSlider(title: "Curve", value: $settings.curve, range: 0...1, step: 0.05,
                                  format: { $0 < 0.01 ? "Flat" : String(format: "%.0f%%", $0 * 100) },
                                  hint: "0% is a flat wall; 100% wraps the screens around you. Shortcut: ⌃⌥[ / ⌃⌥]")
                    LabeledSlider(title: "Height", value: $settings.tiltDegrees, range: -30...30, step: 1,
                                  format: { String(format: "%+.0f°", $0) }, hint: "Shortcut: ⌃⌥↑ / ⌃⌥↓")
                    LabeledSlider(title: "Tilt correction", value: $settings.rollDegrees, range: -15...15, step: 0.5,
                                  format: { $0 == 0 ? "Level" : String(format: "%+.1f°", $0) },
                                  hint: "Rotates the picture if the glasses sit crooked on your face (+ clockwise). Shortcut: ⌃⌥, / ⌃⌥.")
                    LabeledSlider(title: "Gap between screens", value: $settings.gapDegrees, range: 0...10, step: 0.5,
                                  format: { String(format: "%.1f°", $0) }, hint: nil)
                }
                Section("Screens") {
                    Picker("Resolution", selection: $settings.resolutionID) {
                        ForEach(ResolutionPreset.all) { Text($0.title).tag($0.id) }
                    }
                    Toggle("HiDPI (Retina: sharper text, costs more GPU)", isOn: $settings.hiDPI)
                    Picker("Refresh rate", selection: $settings.refreshRate) {
                        Text("60 Hz").tag(60)
                        Text("120 Hz").tag(120)
                    }
                    Picker("Glasses screens sit", selection: $settings.placement) {
                        ForEach(ScreenPlacement.allCases) { Text($0.title).tag($0) }
                    }
                    Text(settings.placement == .custom
                         ? "Arrange the XRealDesk screens in System Settings → Displays, then save. XRealDesk keeps them there, even if macOS reshuffles displays."
                         : "Which edge of your laptop screen the mouse crosses to reach the glasses. XRealDesk keeps it in place automatically. Rearranging them yourself in System Settings → Displays switches to Custom and keeps your layout.")
                        .font(.caption).foregroundStyle(.secondary)
                    if settings.placement == .custom {
                        HStack {
                            Button("Open Displays Settings…") { app.openDisplaySettings() }
                            Button("Save current arrangement") { app.saveCurrentArrangement() }
                        }
                    }
                    Toggle("Make the middle glasses screen the main display", isOn: $settings.glassesIsMain)
                    Text("The main display gets the Dock and new windows. Windows move back when XRealDesk quits.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Tracking") {
                    Picker("Mode", selection: Binding(get: { settings.trackingMode }, set: { app.setMode($0) })) {
                        ForEach(TrackingMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(settings.trackingMode.detail).font(.caption).foregroundStyle(.secondary)
                    if settings.trackingMode == .smart {
                        Toggle("Flick your head quickly to drag the screens along", isOn: $settings.smartFlick)
                    }
                    if settings.trackingMode == .smart && settings.smartFlick {
                        LabeledSlider(title: "Flick sensitivity", value: $settings.flickSensitivity, range: 0...1, step: 0.05,
                                      format: { String(format: "%.0f%%", $0 * 100) },
                                      hint: "Higher: gentler flicks move the screens. Lower: only fast flicks do, so normal looking never moves them.")
                    }
                    if settings.trackingMode == .smoothFollow || settings.trackingMode == .smart {
                        LabeledSlider(title: "Follow speed", value: Binding(get: { 1.05 - settings.followLag },
                                                                             set: { settings.followLag = 1.05 - $0 }),
                                      range: 0.05...1.0, step: 0.05,
                                      format: { String(format: "%.0f%%", $0 * 100) },
                                      hint: "How quickly the screen catches up when you turn your head.")
                    }
                    Toggle("Cursor jumps to the screen you look at", isOn: $settings.cursorFollowsGaze)
                    Toggle("…and the keyboard follows (focuses the window you last used there)", isOn: $settings.keyboardFollowsGaze)
                        .disabled(!settings.cursorFollowsGaze)
                    if settings.keyboardFollowsGaze && !app.accessibilityGranted {
                        Text("Works best with Accessibility permission (see the checklist at the top).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    LabeledSlider(title: "Prediction", value: $settings.predictionMs, range: 0...40, step: 1,
                                  format: { String(format: "%.0f ms", $0) },
                                  hint: "If screens lag behind when you turn, raise this. If they overshoot, lower it.")
                    LabeledSlider(title: "Stability", value: $settings.stabilityDegrees, range: 0...0.4, step: 0.02,
                                  format: { $0 < 0.005 ? "Off" : String(format: "%.2f°", $0) },
                                  hint: "Screens ignore head wobble smaller than this (typing, breathing). Real head turns are never slowed down.")
                    Button("Recenter now") { app.recenter() }
                }
                Section("Look") {
                    LabeledSlider(title: "Brightness", value: $settings.brightness, range: 0.2...1, step: 0.05,
                                  format: { String(format: "%.0f%%", $0 * 100) },
                                  hint: "Lower is more see-through on the glasses.")
                    Picker("Render quality", selection: $settings.renderScale) {
                        Text("Standard").tag(1.0)
                        Text("High (1.5×)").tag(1.5)
                        Text("Ultra (2×)").tag(2.0)
                    }
                    Toggle("Lens correction (uses your glasses' factory calibration)", isOn: $settings.lensCorrection)


                    LabeledSlider(title: "Text sharpening", value: $settings.sharpen, range: 0...1, step: 0.05,
                                  format: { $0 < 0.01 ? "Off" : String(format: "%.0f%%", $0 * 100) }, hint: nil)
                    LabeledSlider(title: "Dim screens you're not looking at", value: $settings.focusDim, range: 0...0.8, step: 0.05,
                                  format: { $0 < 0.01 ? "Off" : String(format: "%.0f%%", $0 * 100) }, hint: nil)
                    LabeledSlider(title: "Corner rounding", value: $settings.cornerRadius, range: 0...0.06, step: 0.002,
                                  format: { $0 < 0.001 ? "Square" : String(format: "%.0f", $0 * 1000) }, hint: nil)
                    Toggle("Glow around the screen with the cursor", isOn: $settings.highlightCursorScreen)
                    Button("Reset look") { settings.resetLook() }
                }
                Section("General") {
                    Toggle("Switch the glasses to extended while XRealDesk runs (required to show your screens)", isOn: $settings.autoExtendDisplay)
                    Toggle("When XRealDesk quits, mirror the glasses to the main screen", isOn: $settings.mirrorWhenQuitting)
                    Picker("When you take the glasses off, move windows to the Mac (and back when you put them on)",
                           selection: $settings.glassesOffMoveDelay) {
                        Text("Never").tag(-1.0)
                        Text("Right away").tag(0.0)
                        Text("After 10 s").tag(10.0)
                        Text("After 30 s").tag(30.0)
                    }
                    Toggle("Put windows back on their glasses screens after restarts, unplugging or sleep", isOn: $settings.windowMemory)
                    Toggle("Keyboard shortcuts (⌃⌥ + key)", isOn: $settings.hotkeysEnabled)
                    Toggle("Show on-glasses notifications", isOn: $settings.showHUD)
                    Toggle("Show in Dock (click the icon to open the control panel)", isOn: $settings.showInDock)
                    Toggle("Launch at login", isOn: Binding(get: { login.enabled }, set: { login.set($0) }))
                    if let e = login.error { Text(e).font(.caption).foregroundStyle(.red) }
                }
                Section("Shortcuts") {
                    ShortcutRow(keys: "⌃⌥X", text: "Open the control panel")
                    ShortcutRow(keys: "⌃⌥R", text: "Recenter screens in front of you")
                    ShortcutRow(keys: "⌃⌥← / ⌃⌥→", text: "Bring the previous / next screen in front of you")
                    ShortcutRow(keys: "⌃⌥F", text: "Cycle mode: anchored → smart → follow → locked")
                    ShortcutRow(keys: "⌃⌥, / ⌃⌥.", text: "Tilt the picture counter-clockwise / clockwise")
                    ShortcutRow(keys: "⌃⌥; / ⌃⌥'", text: "Timing: less / more prediction (tune while turning your head)")
                    ShortcutRow(keys: "⌃⌥= / ⌃⌥-", text: "Bigger / smaller screens")
                    ShortcutRow(keys: "⌃⌥↑ / ⌃⌥↓", text: "Raise / lower screens")
                    ShortcutRow(keys: "⌃⌥[ / ⌃⌥]", text: "Less / more curve")
                    ShortcutRow(keys: "⌃⌥G", text: "Toggle cursor-follows-gaze")
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 560)
        .frame(minHeight: 700)
    }
}

private struct StatusHeader: View {
    @ObservedObject var app: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "eyeglasses")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("XRealDesk").font(.title2.weight(.semibold))
                    Text(app.statusSummary).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 6) {
                CheckRow(ok: glassesOK, title: "Glasses connected (USB)", detail: glassesDetail)
                CheckRow(ok: app.glassesDisplayName != nil || app.preview, title: "Glasses display",
                         detail: app.glassesDisplayName != nil
                            ? "Extended: showing your XRealDesk screens. When XRealDesk quits, the glasses go back to mirroring your main screen."
                            : "Not detected. Use a USB-C port/cable that carries video")
                CheckRow(ok: app.permissionGranted, title: "Screen Recording permission",
                         detail: app.permissionGranted ? "Granted" : "Needed to show your screens in the glasses") {
                    if !app.permissionGranted {
                        Button("Grant…") { app.requestScreenRecordingPermission() }
                    } else if app.needsRelaunchForPermission {
                        Button("Relaunch") { app.relaunch() }
                    }
                }
                CheckRow(ok: app.accessibilityGranted, title: "Accessibility permission",
                         detail: app.accessibilityGranted ? "Windows stay on their glasses screens; keyboard follows your eyes"
                                                          : "Lets XRealDesk put windows back and focus the screen you look at") {
                    if !app.accessibilityGranted {
                        Button("Grant…") { app.requestAccessibilityPermission() }
                    }
                }
                CheckRow(ok: app.trackingHealthy, title: "Head tracking",
                         detail: app.trackingHealthy ? "Tracking" : "Waiting for motion data") {
                    if app.trackingHealthy { RateLabel(live: app.live) }
                }
            }
        }
    }

    private var glassesOK: Bool {
        if case .tracking = app.glassesState { return true }
        return false
    }

    private var glassesDetail: String {
        switch app.glassesState {
        case .tracking:
            if let i = app.deviceInfo { return "\(i.model)\(i.firmware.isEmpty ? "" : " · fw \(i.firmware)")" }
            return "Connected"
        case .connecting(let n): return "Connecting to \(n)…"
        case .searching: return "Plug the glasses into a USB-C port"
        case .failed(let m): return m
        }
    }
}

private struct CheckRow<Accessory: View>: View {
    let ok: Bool
    let title: String
    let detail: String
    @ViewBuilder var accessory: Accessory

    init(ok: Bool, title: String, detail: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.ok = ok; self.title = title; self.detail = detail; self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            accessory
        }
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    let hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { value }, set: { value = step > 0 ? ($0 / step).rounded() * step : $0 }), in: range)
            if let hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

private struct ShortcutRow: View {
    let keys: String
    let text: String
    var body: some View {
        HStack {
            Text(keys).font(.system(.body, design: .rounded).weight(.semibold)).frame(width: 120, alignment: .leading)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

private struct RateLabel: View {
    @ObservedObject var live: LiveState
    var body: some View {
        Text(String(format: "%.0f Hz sensor · %.0f fps", live.imuRate, live.renderFPS))
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
    }
}
