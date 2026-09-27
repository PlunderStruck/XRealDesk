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
        .tint(Brand.accent)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button { app.recenter() } label: { Label("Recenter", systemImage: "scope") }
                .buttonStyle(PrimaryButtonStyle(compact: true))
                .keyboardShortcut("r")
                .help("Put the screens in front of you (⌃⌥R)")
            Button { settings.cursorFollowsGaze.toggle() } label: {
                Image(systemName: "cursorarrow.rays")
                    .foregroundStyle(settings.cursorFollowsGaze ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.secondary))
            }
            .buttonStyle(IconButtonStyle())
            .help(settings.cursorFollowsGaze ? "Cursor follows your gaze: on (⌃⌥G)" : "Cursor follows your gaze: off (⌃⌥G)")
            Button { app.startCalibration() } label: { Image(systemName: "dot.scope") }
                .buttonStyle(IconButtonStyle())
                .help("Calibrate tracking: a few short guided tasks that tune head tracking to you")
            Spacer()
            Button { openSetup(nil) } label: { Image(systemName: "wand.and.stars") }
                .buttonStyle(IconButtonStyle()).help("Setup assistant")
            Button(action: openSettings) { Image(systemName: "gearshape") }
                .buttonStyle(IconButtonStyle()).help("Settings")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(IconButtonStyle()).help("Quit XRealDesk (the glasses go back to mirroring your Mac)")
        }
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
            Button(p.action) { openSetup(p.step) }.buttonStyle(PrimaryButtonStyle(compact: true))
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
            IconBadge(symbol: "eyeglasses", size: 34)
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
        if ready {
            let n = app.activeScreenCount
            return "\(n) screen\(n == 1 ? "" : "s") · \(app.settings.trackingMode.title) mode\(live.sideBySide ? " · 3D" : "")"
        }
        return app.statusSummary
    }
}

/// Your setup in 3D: the screens on their curve around a small viewer, seen from behind and above.
/// The screen you're looking at glows, a frustum shows what the glasses show right now, and clicking
/// a screen brings it in front of you.
struct LayoutMap: View {
    let app: AppController
    @ObservedObject var live: LiveState
    @ObservedObject var settings: Settings

    private struct Projected { let index: Int; let path: Path; let center: CGPoint; let depth: Float }

    var body: some View {
        GeometryReader { geo in
            let scene = Self.scene(layout: settings.layout(), view: live.viewYawPitch,
                                   fov: SIMD2(Float(app.deviceInfo?.calibration.fov.x ?? 39.2), Float(app.deviceInfo?.calibration.fov.y ?? 22.5)),
                                   size: geo.size)
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.09), Color(white: 0.03)], startPoint: .top, endPoint: .bottom))
                Canvas { ctx, _ in
                    // Floor glow under the viewer.
                    let floor = CGRect(x: scene.viewer.x - scene.unit * 1.6, y: scene.viewer.y - scene.unit * 0.35,
                                       width: scene.unit * 3.2, height: scene.unit * 0.7)
                    ctx.fill(Path(ellipseIn: floor), with: .radialGradient(Gradient(colors: [Brand.indigo.opacity(0.35), .clear]),
                                                                          center: scene.viewer, startRadius: 0, endRadius: scene.unit * 1.6))
                    // What the glasses show right now.
                    if let f = scene.frustum {
                        var rays = Path()
                        for c in f.corners { rays.move(to: scene.viewer); rays.addLine(to: c) }
                        ctx.stroke(rays, with: .color(Brand.cyan.opacity(0.18)), lineWidth: 1)
                        ctx.fill(f.quad, with: .color(Brand.cyan.opacity(0.07)))
                    }
                    for p in scene.panels {
                        let gazed = live.gazeScreen == p.index
                        let cursor = live.cursorScreen == p.index
                        if gazed {
                            var glow = ctx
                            glow.addFilter(.blur(radius: 10))
                            glow.fill(p.path, with: .color(Brand.cyan.opacity(0.55)))
                        }
                        ctx.fill(p.path, with: gazed
                                 ? .linearGradient(Gradient(colors: [Brand.indigo.opacity(0.95), Brand.cyan.opacity(0.85)]),
                                                   startPoint: p.center.applying(.init(translationX: 0, y: -40)),
                                                   endPoint: p.center.applying(.init(translationX: 0, y: 40)))
                                 : .linearGradient(Gradient(colors: [Color(white: 0.34), Color(white: 0.2)]),
                                                   startPoint: p.center.applying(.init(translationX: 0, y: -40)),
                                                   endPoint: p.center.applying(.init(translationX: 0, y: 40))))
                        ctx.stroke(p.path, with: .color(cursor ? .white.opacity(0.95) : .white.opacity(0.22)), lineWidth: cursor ? 1.6 : 0.8)
                        ctx.draw(Text("\(p.index + 1)").font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white.opacity(gazed ? 1 : 0.8)), at: p.center)
                    }
                    if let f = scene.frustum {
                        ctx.stroke(f.quad, with: .color(Brand.cyan.opacity(0.9)), style: StrokeStyle(lineWidth: 1.3, dash: [4, 3]))
                    }
                    // The viewer.
                    let head = CGRect(x: scene.viewer.x - 5, y: scene.viewer.y - 5, width: 10, height: 10)
                    ctx.fill(Path(ellipseIn: head.insetBy(dx: -3, dy: -3)), with: .color(Brand.cyan.opacity(0.25)))
                    ctx.fill(Path(ellipseIn: head), with: .color(.white))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { point in
                if let hit = scene.panels.reversed().first(where: { $0.path.contains(point) }) { app.focus(screen: hit.index) }
            }
        }
        .help("Your screens in 3D. The glowing one is where you're looking; the dashed frame is what the glasses show. Click a screen to bring it in front of you.")
    }

    private struct Scene {
        var panels: [Projected]
        var viewer: CGPoint
        var unit: CGFloat
        var frustum: (corners: [CGPoint], quad: Path)?
    }

    /// Perspective camera behind and above the viewer, fitted to the view.
    private static func scene(layout: ScreenLayout, view: SIMD2<Float>, fov: SIMD2<Float>, size: CGSize) -> Scene {
        let d = layout.distance
        let eye = SIMD3<Float>(0, d * 0.75, d * 1.55)
        let target = SIMD3<Float>(0, 0, -d * 0.8)
        let f = simd_normalize(target - eye)
        let r = simd_normalize(simd_cross(f, SIMD3(0, 1, 0)))
        let u = simd_cross(r, f)
        let tilt = layout.tiltRotation
        func cam(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let v = tilt.act(p) - eye
            return SIMD3(simd_dot(v, r), simd_dot(v, u), simd_dot(v, f))
        }
        func flat(_ c: SIMD3<Float>) -> SIMD2<Float> { SIMD2(c.x / max(c.z, 0.05), c.y / max(c.z, 0.05)) }
        // Panel outlines: bent top and bottom edges.
        var outlines: [(Int, [SIMD2<Float>], Float)] = []
        for p in layout.panels {
            var pts: [SIMD2<Float>] = []
            var depth: Float = 0
            let steps = 10
            for i in 0...steps {
                let s = p.arcCenter + (Float(i) / Float(steps) - 0.5) * p.size.x
                let c = cam(layout.point(arc: s, height: p.height + p.size.y / 2)); pts.append(flat(c)); depth += c.z
            }
            for i in (0...steps).reversed() {
                let s = p.arcCenter + (Float(i) / Float(steps) - 0.5) * p.size.x
                let c = cam(layout.point(arc: s, height: p.height - p.size.y / 2)); pts.append(flat(c)); depth += c.z
            }
            outlines.append((p.index, pts, depth / Float(pts.count)))
        }
        let viewer2 = flat(cam(.zero))
        // Frustum of the glasses' view: 4 corner rays out to the screen distance.
        let dir: (Float, Float) -> SIMD3<Float> = { yaw, pitch in
            SIMD3(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))
        }
        let yaw = view.x, pitch = view.y
        let hx = tan(SpatialMath.radians(fov.x) / 2), hy = tan(SpatialMath.radians(fov.y) / 2)
        let fwd = dir(yaw, pitch), right = simd_normalize(simd_cross(fwd, SIMD3(0, 1, 0))), up = simd_cross(right, fwd)
        let corners3 = [(-1, 1), (1, 1), (1, -1), (-1, -1)].map { (sx: Float, sy: Float) -> SIMD3<Float> in
            simd_normalize(fwd + right * (sx * hx) + up * (sy * hy)) * d
        }
        // The view is measured in the untilted layout frame; cam() applies the tilt, like the panels.
        let frustum2 = corners3.map { flat(cam($0)) }

        var all = outlines.flatMap { $0.1 } + [viewer2] + frustum2
        if all.isEmpty { all = [.zero] }
        let minX = all.map(\.x).min()!, maxX = all.map(\.x).max()!
        let minY = all.map(\.y).min()!, maxY = all.map(\.y).max()!
        let pad: CGFloat = 16
        let scale = min((size.width - 2 * pad) / CGFloat(max(maxX - minX, 1e-3)), (size.height - 2 * pad) / CGFloat(max(maxY - minY, 1e-3)))
        let ox = (size.width - CGFloat(maxX - minX) * scale) / 2, oy = (size.height - CGFloat(maxY - minY) * scale) / 2
        let toView: (SIMD2<Float>) -> CGPoint = { q in
            CGPoint(x: ox + CGFloat(q.x - minX) * scale, y: oy + CGFloat(maxY - q.y) * scale)
        }
        let panels = outlines.sorted { $0.2 > $1.2 }.map { (index, pts, depth) -> Projected in
            var path = Path()
            path.addLines(pts.map(toView))
            path.closeSubpath()
            let c = pts.reduce(SIMD2<Float>(0, 0), +) / Float(pts.count)
            return Projected(index: index, path: path, center: toView(c), depth: depth)
        }
        var quad = Path()
        quad.addLines(frustum2.map(toView))
        quad.closeSubpath()
        let unit = CGFloat(layout.panels.first.map { $0.size.x } ?? 1) * scale / CGFloat(max(d * 1.5, 0.1))
        return Scene(panels: panels, viewer: toView(viewer2), unit: max(unit * 0.35, 18),
                     frustum: (frustum2.map(toView), quad))
    }
}

struct FPSLabel: View {
    @ObservedObject var live: LiveState
    var body: some View {
        Text(String(format: "%.0f fps", live.renderFPS))
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
    }
}
