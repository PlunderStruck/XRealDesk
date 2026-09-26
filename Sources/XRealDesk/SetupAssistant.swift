import SwiftUI
import XRCore

/// Guided setup: connect, permissions, layout, straighten & center, mouse path, done.
/// Shown on first launch and from the control panel. Every step applies live, so you see the
/// result in the glasses while you choose.
final class SetupModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case connect, permissions, layout, straighten, mouse, done
        var title: String {
            switch self {
            case .connect: return "Connect your glasses"
            case .permissions: return "Allow XRealDesk"
            case .layout: return "Choose your screens"
            case .straighten: return "Center and straighten"
            case .mouse: return "Reach them with the mouse"
            case .done: return "You're all set"
            }
        }
        var symbol: String {
            switch self {
            case .connect: return "cable.connector"
            case .permissions: return "lock.open"
            case .layout: return "rectangle.split.3x1"
            case .straighten: return "level"
            case .mouse: return "cursorarrow.motionlines"
            case .done: return "checkmark.seal"
            }
        }
    }
    @Published var step: Step = .connect
    var onFinish: () -> Void = {}
}

struct SetupAssistant: View {
    @ObservedObject var model: SetupModel
    @ObservedObject var app: AppController
    @ObservedObject var settings: Settings

    var body: some View {
        VStack(spacing: 0) {
            progress
                .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 14)
            HStack(spacing: 10) {
                Image(systemName: model.step.symbol).font(.system(size: 22, weight: .medium)).foregroundStyle(.tint)
                Text(model.step.title).font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 28)
            Group {
                switch model.step {
                case .connect: ConnectStep(app: app)
                case .permissions: PermissionsStep(app: app)
                case .layout: LayoutStep(app: app, settings: settings)
                case .straighten: StraightenStep(app: app, settings: settings)
                case .mouse: MouseStep(settings: settings)
                case .done: DoneStep(app: app, settings: settings)
                }
            }
            .padding(.horizontal, 28).padding(.top, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer.padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 620, height: 560)
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(SetupModel.Step.allCases, id: \.rawValue) { s in
                Capsule()
                    .fill(s.rawValue <= model.step.rawValue ? Color.accentColor : Color.primary.opacity(0.12))
                    .frame(height: 4)
                    .onTapGesture { model.step = s }
                    .help(s.title)
            }
        }
    }

    private var footer: some View {
        HStack {
            if model.step != .connect {
                Button("Back") { move(-1) }
            }
            Spacer()
            if let hint = nextHint {
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
            if model.step == .done {
                Button("Start using XRealDesk") { model.onFinish() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Continue") { move(1) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.large)
    }

    /// Gentle nudge when a step isn't finished (you can always continue).
    private var nextHint: String? {
        switch model.step {
        case .connect:
            if case .tracking = app.glassesState, app.glassesDisplayName != nil { return nil }
            return "You can continue and plug them in later"
        case .permissions:
            return app.permissionGranted ? nil : "Screen Recording is needed to show your screens"
        default: return nil
        }
    }

    private func move(_ delta: Int) {
        if let s = SetupModel.Step(rawValue: model.step.rawValue + delta) {
            withAnimation(.easeInOut(duration: 0.15)) { model.step = s }
        }
    }
}

// MARK: Steps

private struct ConnectStep: View {
    @ObservedObject var app: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Plug your XREAL glasses into a USB-C port on this Mac with their cable. XRealDesk finds them on its own.")
                .foregroundStyle(.secondary)
            Card(padding: 14) {
                CheckRow(usbState, "Glasses connected", usbDetail)
                Divider()
                CheckRow(displayState, "Glasses display", displayDetail)
                Divider()
                CheckRow(app.trackingHealthy ? .done : (usbState == .done ? .working : .todo),
                         "Head tracking", app.trackingHealthy ? "Following your head" : "Starts as soon as the glasses are connected")
            }
            Label("While XRealDesk runs, the glasses show your XRealDesk screens. When it quits, they go back to mirroring your Mac. There's nothing to change in System Settings.",
                  systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var usbState: CheckRow<EmptyView>.State {
        switch app.glassesState {
        case .tracking: return .done
        case .connecting: return .working
        default: return .todo
        }
    }
    private var usbDetail: String {
        switch app.glassesState {
        case .tracking: return app.deviceInfo.map { "\($0.model)\($0.firmware.isEmpty ? "" : " · firmware \($0.firmware)")" } ?? "Connected"
        case .connecting(let n): return "Connecting to \(n)…"
        case .searching: return "Waiting for the glasses. Plug them in"
        case .failed(let m): return m
        }
    }
    private var displayState: CheckRow<EmptyView>.State {
        app.glassesDisplayName != nil ? .done : (usbState == .done ? .todo : .optional)
    }
    private var displayDetail: String {
        if app.glassesDisplayName != nil { return "Showing your XRealDesk screens" }
        if usbState == .done { return "No picture yet. Use a USB-C port that carries video (not a hub without DisplayPort)" }
        return "Appears once the glasses are connected"
    }
}

struct PermissionsStep: View {
    @ObservedObject var app: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("macOS asks you to allow two things. Click Allow, flip the switch for XRealDesk in System Settings, then come back. XRealDesk notices by itself and restarts if macOS needs it to.")
                .foregroundStyle(.secondary)
            PermissionRows(app: app)
        }
    }
}

/// Screen Recording + Accessibility rows with live state and one-click actions (setup + settings).
struct PermissionRows: View {
    @ObservedObject var app: AppController

    var body: some View {
        Card(padding: 14) {
            CheckRow(app.permissionGranted && !app.needsRelaunchForPermission ? .done : .todo,
                     "Screen Recording  ·  required",
                     screenDetail) {
                if !app.permissionGranted {
                    Button("Allow…") { app.requestScreenRecordingPermission() }.buttonStyle(.borderedProminent)
                } else if app.needsRelaunchForPermission {
                    Button("Restart now") { app.relaunch() }.buttonStyle(.borderedProminent)
                }
            }
            Divider()
            CheckRow(app.accessibilityGranted ? .done : .optional,
                     "Accessibility  ·  recommended",
                     app.accessibilityGranted
                        ? "Windows go back to their glasses screens, and typing goes to the screen you look at"
                        : "Lets XRealDesk put windows back where they were and send typing to the screen you look at") {
                if !app.accessibilityGranted {
                    Button("Allow…") { app.requestAccessibilityPermission() }
                }
            }
        }
    }

    private var screenDetail: String {
        if app.needsRelaunchForPermission { return "Allowed. Restarting XRealDesk to finish…" }
        return app.permissionGranted ? "Your screens can be shown in the glasses" : "Needed to show your screens in the glasses"
    }
}

private struct LayoutStep: View {
    @ObservedObject var app: AppController
    @ObservedObject var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pick a starting point. You can fine-tune everything later from the menu bar.")
                .foregroundStyle(.secondary)
            LayoutMap(app: app, live: app.live, settings: settings).frame(height: 150)
            PresetTiles(settings: settings, columns: 6, height: 50)
            HStack(spacing: 14) {
                Stepper("Screens: \(settings.screenCount)", value: $settings.screenCount, in: 1...Settings.maxScreens)
                Picker("", selection: $settings.rows) {
                    Text("1 row").tag(1); Text("2 rows").tag(2); Text("3 rows").tag(3)
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 190)
                .disabled(settings.screenCount < 2)
                Spacer()
            }
            HStack {
                ValueSlider(symbol: "arrow.up.left.and.arrow.down.right", title: "Size", value: $settings.screenWidthDegrees,
                            range: 16...100, step: 1) { String(format: "%.0f°", $0) }
                Button("Sharpest") {
                    settings.screenWidthDegrees = min(100, max(16, app.pixelPerfectWidthDegrees().rounded()))
                }
                .help("One screen pixel per glasses pixel: the crispest text")
            }
        }
    }
}

private struct StraightenStep: View {
    @ObservedObject var app: AppController
    @ObservedObject var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card(padding: 14) {
                HStack(alignment: .top, spacing: 14) {
                    stepNumber(1)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Put the glasses on and look straight ahead, then recenter.").font(.body.weight(.medium))
                        HStack {
                            Button { app.recenter() } label: { Label("Recenter", systemImage: "scope") }
                                .buttonStyle(.borderedProminent)
                            Text("Anytime: ⌃⌥R").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Card(padding: 14) {
                HStack(alignment: .top, spacing: 14) {
                    stepNumber(2)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Straighten: compare the screens' edges with a straight edge in the room (a desk, a window frame).")
                            .font(.body.weight(.medium))
                        Text("Glasses often sit a little crooked on the face. Rotate until the screens look level.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button { nudge(-0.5) } label: { Image(systemName: "rotate.left") }
                            ValueSlider(symbol: "level", title: "Rotation", value: $settings.rollDegrees, range: -15...15, step: 0.5) {
                                $0 == 0 ? "Level" : String(format: "%+.1f°", $0)
                            }
                            Button { nudge(0.5) } label: { Image(systemName: "rotate.right") }
                        }
                    }
                }
            }
            Card(padding: 14) {
                HStack(alignment: .top, spacing: 14) {
                    stepNumber(3)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Set the height and curve that feel comfortable.").font(.body.weight(.medium))
                        ValueSlider(symbol: "arrow.up.and.down", title: "Height", value: $settings.tiltDegrees, range: -30...30, step: 1) {
                            String(format: "%+.0f°", $0)
                        }
                        ValueSlider(symbol: "rectangle.portrait.arrowtriangle.2.outward", title: "Curve", value: $settings.curve,
                                    range: 0...1, step: 0.05) { $0 < 0.01 ? "Flat" : String(format: "%.0f%%", $0 * 100) }
                    }
                }
            }
        }
    }

    private func nudge(_ d: Double) { settings.rollDegrees = min(15, max(-15, settings.rollDegrees + d)) }

    private func stepNumber(_ n: Int) -> some View {
        Text("\(n)").font(.callout.weight(.bold)).foregroundStyle(.white)
            .frame(width: 24, height: 24).background(Circle().fill(Color.accentColor))
    }
}

private struct MouseStep: View {
    @ObservedObject var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Which edge of your Mac's screen should the mouse cross to reach the glasses screens? XRealDesk keeps this arrangement in place, even when macOS reshuffles displays.")
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ForEach([ScreenPlacement.above, .below, .left, .right]) { p in
                    Tile(title: p.title, selected: settings.placement == p, height: 110, action: { settings.placement = p }) {
                        PlacementDiagram(placement: p).frame(width: 100, height: 70)
                    }
                }
            }
            Toggle("Make the middle glasses screen the main display (menu bar, Dock and new windows open there)",
                   isOn: $settings.glassesIsMain)
            Text("Prefer your own arrangement? Drag the XRealDesk screens in System Settings → Displays. XRealDesk switches to Custom and keeps it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct DoneStep: View {
    @ObservedObject var app: AppController
    @ObservedObject var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How should the screens behave when you move your head?").foregroundStyle(.secondary)
            ModeTiles(app: app, settings: settings, height: 66, showDetail: true)
            Text("Handy shortcuts").font(.headline).padding(.top, 4)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Shortcuts.all.prefix(5), id: \.0) { ShortcutRow(keys: $0.0, text: $0.1) }
            }
            Text("XRealDesk lives in the menu bar (the glasses icon). Click it anytime to adjust your screens.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: Shared pieces

struct PresetTiles: View {
    @ObservedObject var settings: Settings
    var columns = 6
    var height: CGFloat = 46

    var body: some View {
        let current = settings.matchingPreset
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
            ForEach(LayoutPreset.all) { p in
                Tile(title: p.title, selected: current == p.id, height: height, action: { settings.apply(p) }) {
                    Image(systemName: p.symbol).font(.system(size: 15))
                }
                .help("\(p.count) screen\(p.count == 1 ? "" : "s")")
            }
        }
    }
}

struct ModeTiles: View {
    @ObservedObject var app: AppController
    @ObservedObject var settings: Settings
    var height: CGFloat = 52
    var showDetail = false

    var body: some View {
        HStack(spacing: 8) {
            ForEach(TrackingMode.allCases) { m in
                Tile(title: m.title + (m == .smart && showDetail ? " ★" : ""), selected: settings.trackingMode == m,
                     subtitle: showDetail ? m.shortDetail : nil, height: height, action: { app.setMode(m) }) {
                    Image(systemName: m.symbol).font(.system(size: 15))
                }
                .help(m.detail)
            }
        }
    }
}
