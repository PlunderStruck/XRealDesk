import XRCore
import SwiftUI

/// Shared look for the control panel, setup assistant and settings: soft cards, SF Symbols,
/// one accent colour, values shown next to every slider.

struct Card<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }
}

/// Slider row: icon, title, slider, live value.
struct ValueSlider: View {
    let symbol: String
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var titleWidth: CGFloat = 74
    let format: (Double) -> String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title).frame(width: titleWidth, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { value = step > 0 ? ($0 / step).rounded() * step : $0 }), in: range)
                .controlSize(.small)
            Text(format(value))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
        }
    }
}

final class HoverState: ObservableObject { @Published var on = false }

/// Selectable tile with an icon and a title (presets, modes, placements).
struct Tile<Icon: View>: View {
    let title: String
    let selected: Bool
    var subtitle: String? = nil
    var height: CGFloat = 54
    let action: () -> Void
    @ViewBuilder var icon: Icon
    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                icon.foregroundStyle(selected ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.primary.opacity(0.85)))
                Text(title).font(.system(size: 11, weight: selected ? .semibold : .medium)).lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let subtitle {
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity, minHeight: height)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(selected ? Brand.accent.opacity(0.16) : Color.primary.opacity(hover.on ? 0.09 : 0.045)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(selected ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.primary.opacity(hover.on ? 0.16 : 0.07)),
                              lineWidth: selected ? 1.5 : 1))
            .scaleEffect(hover.on && !selected ? 1.02 : 1)
            .animation(.easeOut(duration: 0.12), value: hover.on)
            .animation(.easeOut(duration: 0.18), value: selected)
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
    }
}

/// A colored dot and a short status text.
struct StatusPill: View {
    enum Tone { case good, working, problem }
    let tone: Tone
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption.weight(.medium)).lineLimit(1)
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.14)))
    }

    private var color: Color {
        switch tone {
        case .good: return .green
        case .working: return .orange
        case .problem: return .red
        }
    }
}

/// Checklist row: state icon, title + detail, optional action.
struct CheckRow<Accessory: View>: View {
    enum State { case done, todo, optional, working }
    let state: State
    let title: String
    let detail: String
    @ViewBuilder var accessory: Accessory

    init(_ state: State, _ title: String, _ detail: String, @ViewBuilder accessory: () -> Accessory) {
        self.state = state; self.title = title; self.detail = detail; self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle().fill(iconColor.opacity(0.16)).frame(width: 30, height: 30)
                if state == .working {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: icon).font(.system(size: 13, weight: .bold)).foregroundStyle(iconColor)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            accessory
        }
    }

    private var icon: String {
        switch state {
        case .done: return "checkmark"
        case .todo: return "exclamationmark"
        case .optional: return "minus"
        case .working: return ""
        }
    }

    private var iconColor: Color {
        switch state {
        case .done: return .green
        case .todo: return .orange
        case .optional: return .secondary
        case .working: return .secondary
        }
    }
}

extension CheckRow where Accessory == EmptyView {
    init(_ state: State, _ title: String, _ detail: String) {
        self.init(state, title, detail) { EmptyView() }
    }
}

/// Tiny diagram of the Mac's screen and the glasses screens for a placement.
struct PlacementDiagram: View {
    let placement: ScreenPlacement
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let mac = CGSize(width: w * 0.34, height: h * 0.34)
            let glass = CGSize(width: w * 0.26, height: h * 0.22)
            let center = CGPoint(x: w / 2, y: h / 2)
            let macCenter: CGPoint = {
                switch placement {
                case .above: return CGPoint(x: center.x, y: center.y + h * 0.17)
                case .below: return CGPoint(x: center.x, y: center.y - h * 0.17)
                case .left: return CGPoint(x: center.x + w * 0.2, y: center.y)
                case .right: return CGPoint(x: center.x - w * 0.2, y: center.y)
                case .custom: return center
                }
            }()
            let glassCenters: [CGPoint] = {
                switch placement {
                case .above: return [-1, 1].map { CGPoint(x: center.x + $0 * glass.width * 0.55, y: macCenter.y - mac.height / 2 - glass.height / 2 - 3) }
                case .below: return [-1, 1].map { CGPoint(x: center.x + $0 * glass.width * 0.55, y: macCenter.y + mac.height / 2 + glass.height / 2 + 3) }
                case .left: return [-1, 1].map { CGPoint(x: macCenter.x - mac.width / 2 - glass.width / 2 - 3, y: center.y + $0 * glass.height * 0.55) }
                case .right: return [-1, 1].map { CGPoint(x: macCenter.x + mac.width / 2 + glass.width / 2 + 3, y: center.y + $0 * glass.height * 0.55) }
                case .custom: return []
                }
            }()
            ZStack {
                if placement == .custom {
                    Image(systemName: "hand.draw").font(.system(size: 18)).foregroundStyle(.secondary)
                } else {
                    RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.35))
                        .frame(width: mac.width, height: mac.height).position(macCenter)
                    ForEach(0..<glassCenters.count, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2).fill(Brand.gradient)
                            .frame(width: glass.width, height: glass.height).position(glassCenters[i])
                    }
                }
            }
        }
    }
}

extension TrackingMode {
    var symbol: String {
        switch self {
        case .anchored: return "pin"
        case .smart: return "sparkles"
        case .smoothFollow: return "figure.walk"
        case .headLocked: return "lock"
        }
    }
    var shortDetail: String {
        switch self {
        case .anchored: return "Fixed in space"
        case .smart: return "Follows past the edge"
        case .smoothFollow: return "Glides after you"
        case .headLocked: return "Moves with your head"
        }
    }
}

struct ShortcutRow: View {
    let keys: String
    let text: String
    var body: some View {
        HStack(spacing: 12) {
            Text(keys)
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
                .frame(width: 118, alignment: .leading)
            Text(text).foregroundStyle(.secondary)
            Spacer()
        }
    }
}

enum Shortcuts {
    static let all: [(String, String)] = [
        ("⌃⌥X", "Open the control panel"),
        ("⌃⌥R", "Recenter the screens in front of you"),
        ("⌃⌥← / →", "Bring the previous / next screen in front of you"),
        ("⌃⌥F", "Cycle mode: anchored, smart, follow, locked"),
        ("⌃⌥= / -", "Bigger / smaller screens"),
        ("⌃⌥↑ / ↓", "Raise / lower the screens"),
        ("⌃⌥[ / ]", "Less / more curve"),
        ("⌃⌥, / .", "Straighten: rotate the picture"),
        ("⌃⌥G", "Cursor follows your gaze on / off"),
        ("⌃⌥T", "Subpixel text: off, RGB, BGR, vertical RGB, vertical BGR"),
    ]
}

// MARK: Brand

enum Brand {
    static let indigo = Color(red: 0.38, green: 0.42, blue: 1.0)
    static let cyan = Color(red: 0.20, green: 0.80, blue: 0.98)
    /// The accent: sliders, toggles, selection.
    static let accent = Color(red: 0.33, green: 0.55, blue: 1.0)
    static let gradient = LinearGradient(colors: [indigo, cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Frosted background (NSVisualEffectView), like Control Center.
struct Glass: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

/// Rounded-square colored icon, like System Settings' sidebar.
struct IconBadge: View {
    let symbol: String
    var colors: [Color] = [Brand.indigo, Brand.cyan]
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.52, weight: .semibold)).foregroundStyle(.white))
            .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
    }
}

/// Big soft-glowing icon for the setup assistant.
struct HeroIcon: View {
    let symbol: String
    var body: some View {
        ZStack {
            Circle().fill(Brand.gradient).frame(width: 64, height: 64).blur(radius: 22).opacity(0.55)
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Brand.gradient)
                .frame(width: 60, height: 60)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 1))
                .overlay(Image(systemName: symbol).font(.system(size: 26, weight: .semibold)).foregroundStyle(.white))
                .shadow(color: Brand.indigo.opacity(0.45), radius: 10, y: 4)
        }
        .frame(width: 80, height: 80)
    }
}

/// The gradient capsule button used for the main action on each surface.
struct PrimaryButtonStyle: ButtonStyle {
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 12 : 18).padding(.vertical, compact ? 6 : 8)
            .background(Capsule().fill(Brand.gradient))
            .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1))
            .shadow(color: Brand.indigo.opacity(configuration.isPressed ? 0.15 : 0.35), radius: configuration.isPressed ? 2 : 6, y: 2)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Quiet round icon button (footer actions).
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .frame(width: 30, height: 30)
            .background(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.07)))
            .contentShape(Circle())
    }
}
