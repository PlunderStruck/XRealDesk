import SwiftUI
import simd
import XRCore

/// The menu-bar popover: everything you touch day to day, adjustable live while wearing the glasses.
struct ControlPanel: View {
    @ObservedObject var app: AppController
    @ObservedObject var settings: Settings
    var openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            presets
            LayoutMap(app: app, live: app.live, settings: settings)
                .frame(height: 150)
            VStack(spacing: 10) {
                HStack {
                    Label("Screens", systemImage: "rectangle.on.rectangle")
                    Spacer()
                    Stepper(value: $settings.screenCount, in: 1...Settings.maxScreens) {
                        Text("\(settings.screenCount)").monospacedDigit().frame(minWidth: 18)
                    }
                    Picker("", selection: $settings.rows) {
                        Text("1 row").tag(1)
                        Text("2 rows").tag(2)
                        Text("3 rows").tag(3)
                    }
                    .labelsHidden()
                    .frame(width: 84)
                    .disabled(settings.screenCount < 2)
                }
                PanelSlider(symbol: "arrow.up.left.and.arrow.down.right", title: "Size", value: $settings.screenWidthDegrees,
                            range: 16...100, step: 1) { String(format: "%.0f°", $0) }
                PanelSlider(symbol: "rectangle.portrait.arrowtriangle.2.outward", title: "Curve", value: $settings.curve,
                            range: 0...1, step: 0.05) { $0 < 0.01 ? "Flat" : String(format: "%.0f%%", $0 * 100) }
                PanelSlider(symbol: "arrow.up.and.down", title: "Height", value: $settings.tiltDegrees,
                            range: -30...30, step: 1) { String(format: "%+.0f°", $0) }
                PanelSlider(symbol: "rotate.right", title: "Tilt", value: $settings.rollDegrees,
                            range: -15...15, step: 0.5) { $0 == 0 ? "Level" : String(format: "%+.1f°", $0) }
                PanelSlider(symbol: "scope", title: "Stability", value: $settings.stabilityDegrees,
                            range: 0...0.4, step: 0.02) { $0 < 0.005 ? "Off" : String(format: "%.2f°", $0) }
                PanelSlider(symbol: "sun.max", title: "Brightness", value: $settings.brightness,
                            range: 0.2...1, step: 0.05) { String(format: "%.0f%%", $0 * 100) }
            }
            Picker("", selection: Binding(get: { settings.trackingMode }, set: { app.setMode($0) })) {
                ForEach(TrackingMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(settings.trackingMode.detail).font(.caption).foregroundStyle(.secondary)
            if settings.trackingMode == .smart {
                Toggle("Flick your head to reposition", isOn: $settings.smartFlick).font(.callout)
                if settings.smartFlick {
                    PanelSlider(symbol: "hand.draw", title: "Flick", value: $settings.flickSensitivity,
                                range: 0...1, step: 0.05) { String(format: "%.0f%%", $0 * 100) }
                }
            }
            if settings.trackingMode == .smoothFollow || settings.trackingMode == .smart {
                PanelSlider(symbol: "hare", title: "Follow", value: Binding(get: { 1.05 - settings.followLag },
                                                                            set: { settings.followLag = 1.05 - $0 }),
                            range: 0.05...1.0, step: 0.05) { String(format: "%.0f%%", $0 * 100) }
            }

            HStack {
                Button { app.recenter() } label: { Label("Recenter", systemImage: "scope") }
                    .keyboardShortcut("r")
                Toggle(isOn: $settings.cursorFollowsGaze) { Text("Cursor follows gaze") }
                    .toggleStyle(.checkbox)
                    .font(.callout)
                Spacer()
            }
            Divider()
            HStack {
                Button("Settings…", action: openSettings)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 380)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.deviceInfo?.model ?? "XRealDesk").font(.headline)
                Text(app.statusSummary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if app.trackingHealthy {
                FPSLabel(live: app.live)
            }
        }
    }

    private var statusColor: Color {
        if app.trackingHealthy && (app.glassesDisplayName != nil || app.preview) { return .green }
        if case .failed = app.glassesState { return .red }
        return .orange
    }

    private var presets: some View {
        let current = settings.matchingPreset
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
            ForEach(LayoutPreset.all) { p in
                Button { settings.apply(p) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: p.symbol).font(.system(size: 16))
                        Text(p.title).font(.system(size: 9.5, weight: .medium)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(current == p.id ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(current == p.id ? Color.accentColor : .clear, lineWidth: 1.2))
                }
                .buttonStyle(.plain)
                .help(p.title)
            }
        }
    }
}

struct PanelSlider: View {
    let symbol: String
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
            Text(title).frame(width: 70, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { value = step > 0 ? ($0 / step).rounded() * step : $0 }), in: range)
            Text(format(value)).monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
        }
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
