import SwiftUI
import simd
import XRCore

/// The menu-bar popover: status, layout and the few controls you touch day to day, live while
/// wearing the glasses. Everything else is in Settings; first-time setup in the setup assistant.
struct ControlPanel: View {
    @ObservedObject var app: AppController
    @ObservedObject var settings: Settings
    var openSettings: () -> Void
    var openSetup: (SetupModel.Step?) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(app: app, live: app.live)
            if let problem { problemBanner(problem) }
            Card(padding: 10) {
                LayoutMap(app: app, live: app.live, settings: settings)
                    .frame(height: 128)
                PresetTiles(settings: settings, columns: 6, height: 38)
                HStack(spacing: 10) {
                    Stepper(value: $settings.screenCount, in: 1...Settings.maxScreens) {
                        Label("\(settings.screenCount) screen\(settings.screenCount == 1 ? "" : "s")", systemImage: "rectangle.on.rectangle")
                            .monospacedDigit()
                    }
                    Spacer()
                    Picker("", selection: $settings.rows) {
                        Text("1 row").tag(1); Text("2").tag(2); Text("3").tag(3)
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 128)
                    .disabled(settings.screenCount < 2)
                }
                .font(.callout)
            }
            Card(padding: 12) {
                ValueSlider(symbol: "arrow.up.left.and.arrow.down.right", title: "Size", value: $settings.screenWidthDegrees,
                            range: 16...100, step: 1) { String(format: "%.0f°", $0) }
                ValueSlider(symbol: "rectangle.portrait.arrowtriangle.2.outward", title: "Curve", value: $settings.curve,
                            range: 0...1, step: 0.05) { $0 < 0.01 ? "Flat" : String(format: "%.0f%%", $0 * 100) }
                ValueSlider(symbol: "arrow.up.and.down", title: "Height", value: $settings.tiltDegrees,
                            range: -30...30, step: 1) { String(format: "%+.0f°", $0) }
                ValueSlider(symbol: "sun.max", title: "Brightness", value: $settings.brightness,
                            range: 0.2...1, step: 0.05) { String(format: "%.0f%%", $0 * 100) }
            }
            Card(padding: 10) {
                ModeTiles(app: app, settings: settings, height: 40)
                Text(settings.trackingMode.detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(14)
        .frame(width: 380)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button { app.recenter() } label: { Label("Recenter", systemImage: "scope") }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("r")
                .help("Put the screens in front of you (⌃⌥R)")
            Toggle(isOn: $settings.cursorFollowsGaze) {
                Image(systemName: "cursorarrow.rays")
            }
            .toggleStyle(.button)
            .help("Cursor jumps to the screen you look at (⌃⌥G)")
            Spacer()
            Button { openSetup(nil) } label: { Image(systemName: "wand.and.stars") }
                .help("Setup assistant")
            Button(action: openSettings) { Image(systemName: "gearshape") }
                .help("Settings")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .help("Quit XRealDesk (the glasses go back to mirroring your Mac)")
        }
        .controlSize(.large)
    }

    private struct Problem { let icon: String; let text: String; let action: String; let step: SetupModel.Step }

    private var problem: Problem? {
        if app.preview { return nil }
        if case .searching = app.glassesState {
            return Problem(icon: "cable.connector", text: "Plug in your XREAL glasses", action: "Help", step: .connect)
        }
        if case .failed(let m) = app.glassesState {
            return Problem(icon: "exclamationmark.triangle", text: m, action: "Help", step: .connect)
        }
        if !app.permissionGranted || app.needsRelaunchForPermission {
            return Problem(icon: "lock", text: "Allow Screen Recording to show your screens", action: "Allow", step: .permissions)
        }
        if case .tracking = app.glassesState, app.glassesDisplayName == nil {
            return Problem(icon: "display.trianglebadge.exclamationmark", text: "No picture from the glasses yet", action: "Help", step: .connect)
        }
        return nil
    }

    private func problemBanner(_ p: Problem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: p.icon).foregroundStyle(.orange)
            Text(p.text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(p.action) { openSetup(p.step) }.buttonStyle(.borderedProminent).controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.12)))
    }
}

/// Device, status and frame rate.
struct PanelHeader: View {
    @ObservedObject var app: AppController
    @ObservedObject var live: LiveState

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.15)).frame(width: 34, height: 34)
                Image(systemName: "eyeglasses").font(.system(size: 16, weight: .semibold)).foregroundStyle(.tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(app.deviceInfo?.model ?? "XRealDesk").font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            StatusPill(tone: tone, text: pill)
        }
    }

    private var ready: Bool { app.trackingHealthy && (app.glassesDisplayName != nil || app.preview) && app.permissionGranted }

    private var tone: StatusPill.Tone {
        if app.glassesOffFace { return .working }
        if ready { return .good }
        if case .failed = app.glassesState { return .problem }
        return .working
    }

    private var pill: String {
        if app.glassesOffFace { return "Paused" }
        if ready { return live.sideBySide ? "3D · \(Int(live.renderFPS.rounded())) fps" : "\(Int(live.renderFPS.rounded())) fps" }
        switch app.glassesState {
        case .searching: return "Not connected"
        case .connecting: return "Connecting"
        case .failed: return "Problem"
        case .tracking: return "Starting"
        }
    }

    private var subtitle: String {
        if app.glassesOffFace { return "Glasses off: paused until you put them on" }
        return app.statusSummary
    }
}

/// Front view of the screen layout in angles: where each screen is, which one you're looking at,
/// which has the cursor, and the glasses' field of view. Click a screen to bring it in front of you.
struct LayoutMap: View {
    let app: AppController
    @ObservedObject var live: LiveState
    @ObservedObject var settings: Settings

    private struct Box { let index: Int; let rect: CGRect }

    var body: some View {
        GeometryReader { geo in
            let layout = settings.layout()
            let boxes = Self.boxes(layout)
            let fov = CGSize(width: CGFloat(app.deviceInfo?.calibration.fov.x ?? 39.2),
                             height: CGFloat(app.deviceInfo?.calibration.fov.y ?? 22.5))
            let view = CGPoint(x: CGFloat(-SpatialMath.degrees(live.viewYawPitch.x)),
                               y: CGFloat(SpatialMath.degrees(live.viewYawPitch.y)))
            let fovRect = CGRect(x: view.x - fov.width / 2, y: view.y - fov.height / 2, width: fov.width, height: fov.height)
            let bounds = boxes.reduce(fovRect) { $0.union($1.rect) }.insetBy(dx: -4, dy: -4)
            let scale = min(geo.size.width / bounds.width, geo.size.height / bounds.height)
            let origin = CGPoint(x: (geo.size.width - bounds.width * scale) / 2, y: (geo.size.height - bounds.height * scale) / 2)
            let toView: (CGRect) -> CGRect = { r in
                CGRect(x: origin.x + (r.minX - bounds.minX) * scale,
                       y: origin.y + (bounds.maxY - r.maxY) * scale,
                       width: r.width * scale, height: r.height * scale)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.85))
                ForEach(boxes, id: \.index) { b in
                    let r = toView(b.rect)
                    let gazed = live.gazeScreen == b.index
                    RoundedRectangle(cornerRadius: 3)
                        .fill(gazed ? Color.accentColor.opacity(0.55) : Color.white.opacity(0.16))
                        .overlay(RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(live.cursorScreen == b.index ? Color.accentColor : Color.white.opacity(0.25),
                                          lineWidth: live.cursorScreen == b.index ? 2 : 1))
                        .overlay(Text("\(b.index + 1)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white))
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                        .onTapGesture { app.focus(screen: b.index) }
                }
                let f = toView(fovRect)
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.white.opacity(live.imuRate > 100 ? 0.85 : 0.3), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .frame(width: f.width, height: f.height)
                    .position(x: f.midX, y: f.midY)
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .help("Click a screen to bring it in front of you. The dashed box is what the glasses show.")
    }

    /// Angular bounding boxes (degrees; x right, y up) of each panel as seen from the viewer.
    private static func boxes(_ layout: ScreenLayout) -> [Box] {
        layout.panels.map { p in
            var minX = CGFloat.infinity, maxX = -CGFloat.infinity, minY = CGFloat.infinity, maxY = -CGFloat.infinity
            for su in stride(from: -0.5 as Float, through: 0.5, by: 0.25) {
                for sv in [-0.5 as Float, 0.5] {
                    let pt = layout.point(arc: p.arcCenter + su * p.size.x, height: p.height + sv * p.size.y)
                    let yaw = CGFloat(SpatialMath.degrees(atan2(-pt.x, -pt.z)))
                    let pitch = CGFloat(SpatialMath.degrees(atan2(pt.y, simd_length(SIMD2(pt.x, pt.z)))))
                    minX = min(minX, -yaw); maxX = max(maxX, -yaw)
                    minY = min(minY, pitch); maxY = max(maxY, pitch)
                }
            }
            return Box(index: p.index, rect: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
        }
    }
}

struct FPSLabel: View {
    @ObservedObject var live: LiveState
    var body: some View {
        Text(String(format: "%.0f fps", live.renderFPS))
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
    }
}
