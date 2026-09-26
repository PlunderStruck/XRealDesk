import AppKit
import Carbon.HIToolbox

/// System-wide hotkeys via Carbon (works without Accessibility permission).
final class Hotkeys {
    enum Action: UInt32, CaseIterable {
        case recenter = 1, toggleMode, previousScreen, nextScreen, zoomIn, zoomOut, toggleGazeCursor,
             raise, lower, moreCurve, lessCurve, controlPanel, rollClockwise, rollCounterClockwise,
             morePrediction, lessPrediction, cycleSubpixel

        var keyCode: Int {
            switch self {
            case .recenter: return kVK_ANSI_R
            case .toggleMode: return kVK_ANSI_F
            case .previousScreen: return kVK_LeftArrow
            case .nextScreen: return kVK_RightArrow
            case .zoomIn: return kVK_ANSI_Equal
            case .zoomOut: return kVK_ANSI_Minus
            case .toggleGazeCursor: return kVK_ANSI_G
            case .raise: return kVK_UpArrow
            case .lower: return kVK_DownArrow
            case .moreCurve: return kVK_ANSI_RightBracket
            case .lessCurve: return kVK_ANSI_LeftBracket
            case .controlPanel: return kVK_ANSI_X
            case .rollClockwise: return kVK_ANSI_Period
            case .rollCounterClockwise: return kVK_ANSI_Comma
            case .morePrediction: return kVK_ANSI_Quote
            case .lessPrediction: return kVK_ANSI_Semicolon
            case .cycleSubpixel: return kVK_ANSI_T
            }
        }

        var label: String {
            switch self {
            case .recenter: return "⌃⌥R"
            case .toggleMode: return "⌃⌥F"
            case .previousScreen: return "⌃⌥←"
            case .nextScreen: return "⌃⌥→"
            case .zoomIn: return "⌃⌥="
            case .zoomOut: return "⌃⌥-"
            case .toggleGazeCursor: return "⌃⌥G"
            case .raise: return "⌃⌥↑"
            case .lower: return "⌃⌥↓"
            case .moreCurve: return "⌃⌥]"
            case .lessCurve: return "⌃⌥["
            case .controlPanel: return "⌃⌥X"
            case .rollClockwise: return "⌃⌥."
            case .rollCounterClockwise: return "⌃⌥,"
            case .morePrediction: return "⌃⌥'"
            case .lessPrediction: return "⌃⌥;"
            case .cycleSubpixel: return "⌃⌥T"
            }
        }
    }

    var handler: ((Action) -> Void)?
    private var refs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?

    func register() {
        unregister()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, ctx in
            guard let event, let ctx else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let me = Unmanaged<Hotkeys>.fromOpaque(ctx).takeUnretainedValue()
            if let action = Action(rawValue: id.id) { me.handler?(action) }
            return noErr
        }, 1, &spec, ctx, &eventHandler)

        let mods = UInt32(controlKey | optionKey)
        for action in Action.allCases {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x5852_444B), id: action.rawValue)   // 'XRDK'
            let status = RegisterEventHotKey(UInt32(action.keyCode), mods, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) } else { Log.info("Hotkey \(action.label) unavailable (\(status))") }
        }
    }

    func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
    }
}
