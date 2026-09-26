import AppKit
import os

/// Measures typing lag: from a key press until new pixels of any glasses screen reach XRealDesk
/// (the app redraws, macOS composes the screen, ScreenCaptureKit delivers it). Add ~25 ms from
/// capture to the glasses. Logged with the capture stats.
enum TypingLatency {
    private struct State { var pendingKey: CFTimeInterval = 0; var pendingApp = ""; var samples: [String: [Double]] = [:] }
    private static let state = OSAllocatedUnfairLock(initialState: State())
    private static var monitor: Any?

    static func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            let t = event.timestamp > 0 ? event.timestamp : CACurrentMediaTime()
            let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            state.withLock { if $0.pendingKey == 0 { $0.pendingKey = t; $0.pendingApp = app } }
        }
    }

    /// A captured frame with new pixels arrived at `arrival` (CACurrentMediaTime).
    static func frameArrived(_ arrival: CFTimeInterval) {
        state.withLock { s in
            guard s.pendingKey > 0 else { return }
            let d = arrival - s.pendingKey
            if d >= 0 && d < 1.5 { s.samples[s.pendingApp, default: []].append(d * 1000) }
            if d >= 0 || d < -1 { s.pendingKey = 0 }
        }
    }

    /// "typing (key→captured): App p50 X ms, p90 Y, max Z (n); …" since the last call, or nil.
    static func report() -> String? {
        let byApp = state.withLock { s -> [String: [Double]] in
            if s.pendingKey > 0, CACurrentMediaTime() - s.pendingKey > 1.5 { s.pendingKey = 0 }   // key that changed nothing
            defer { s.samples.removeAll(keepingCapacity: true) }
            return s.samples
        }
        guard !byApp.isEmpty else { return nil }
        return "typing (key→captured): " + byApp.sorted { $0.value.count > $1.value.count }.map { app, samples in
            let v = samples.sorted()
            return String(format: "%@ p50 %.0f ms, p90 %.0f, max %.0f (%d keys)", app as NSString,
                          v[v.count / 2], v[min(v.count - 1, v.count * 9 / 10)], v.last!, v.count)
        }.joined(separator: "; ")
    }
}
