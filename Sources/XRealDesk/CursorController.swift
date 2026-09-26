import AppKit
import CoreGraphics

/// Two jobs, both run every rendered frame:
///  1. Guard: the glasses' physical display is our render surface, so keep the mouse off it.
///  2. Gaze follow: when you look at another virtual screen and settle there, the cursor jumps to it
///     (back to where you last left it on that screen). Never while dragging or while you're moving the mouse.
final class CursorController {
    var guardDisplay: CGDirectDisplayID?
    var gazeFollowEnabled = true
    var dwellSeconds: Double = 0.22
    /// Called after the cursor jumps to a screen because you looked at it (index, display).
    var onGazeSwitch: ((Int, CGDirectDisplayID) -> Void)?

    private var guardWarps = 0
    private var guardWindowStart: TimeInterval = 0
    private var lastPos: CGPoint?
    private var lastMouseMove: TimeInterval = 0
    private var suppressUntil: TimeInterval = 0
    private var candidate: Int?
    private var candidateSince: TimeInterval = 0
    private var savedPositions: [Int: CGPoint] = [:]   // relative 0...1 per screen

    /// - Returns: index of the virtual screen currently containing the cursor, if any.
    @discardableResult
    func tick(now: TimeInterval, screens: [(index: Int, id: CGDirectDisplayID)], gazeIndex: Int?) -> Int? {
        guard let loc = CGEvent(source: nil)?.location else { return nil }

        if let last = lastPos, hypot(last.x - loc.x, last.y - loc.y) > 0.5, now > suppressUntil {
            lastMouseMove = now
        }
        lastPos = loc

        // 1. Guard the glasses' own display. Only while it's a display of its own: when mirrored,
        // its bounds are the main screen's, and guarding them would pin the pointer in place.
        // The glasses display acts as a wall: the pointer goes to the nearest point on a real screen.
        // (Not to a remembered "last good" spot: after displays are rearranged that spot can lie
        // inside the glasses display, and the pointer froze, warped back into it 60 times a second.)
        if let g = guardDisplay, CursorController.guardable(g), CGDisplayBounds(g).insetBy(dx: -0.5, dy: -0.5).contains(loc),
           let target = CursorController.nearestPoint(to: loc, excluding: g) {
            warp(to: target, now: now)
            guardWarps += 1
            if now - guardWindowStart >= 1 {
                if guardWarps > 20 {
                    Log.error("Cursor guard acted \(guardWarps)× in 1 s: pointer \(loc), glasses display \(CGDisplayBounds(g)), sent to \(target)")
                }
                guardWarps = 0
                guardWindowStart = now
            }
            return nil
        }

        let cursorIndex = screens.first { CGDisplayBounds($0.id).contains(loc) }?.index

        // 2. Gaze follow.
        guard gazeFollowEnabled, let cursorIndex, let gazeIndex, gazeIndex != cursorIndex,
              NSEvent.pressedMouseButtons == 0, now - lastMouseMove > 0.15,
              let from = screens.first(where: { $0.index == cursorIndex }),
              let to = screens.first(where: { $0.index == gazeIndex }) else {
            candidate = nil
            return cursorIndex
        }
        if candidate != gazeIndex {
            candidate = gazeIndex
            candidateSince = now
            return cursorIndex
        }
        guard now - candidateSince >= dwellSeconds else { return cursorIndex }

        let fb = CGDisplayBounds(from.id)
        savedPositions[cursorIndex] = CGPoint(x: (loc.x - fb.minX) / fb.width, y: (loc.y - fb.minY) / fb.height)
        let rel = savedPositions[gazeIndex] ?? CGPoint(x: 0.5, y: 0.5)
        let tb = CGDisplayBounds(to.id)
        let target = CGPoint(x: tb.minX + rel.x * tb.width, y: tb.minY + rel.y * tb.height)
        warp(to: target, now: now)
        candidate = nil
        onGazeSwitch?(gazeIndex, to.id)
        return gazeIndex
    }

    /// The glasses display is extended and doesn't overlap any other display.
    static func guardable(_ g: CGDirectDisplayID) -> Bool {
        guard CGDisplayIsInMirrorSet(g) == 0 else { return false }
        let b = CGDisplayBounds(g)
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        return !ids.prefix(Int(n)).contains { $0 != g && CGDisplayBounds($0).intersects(b) }
    }

    /// Closest point to `p` on any active display other than `excluded` (1 pt inside its edge).
    static func nearestPoint(to p: CGPoint, excluding excluded: CGDirectDisplayID) -> CGPoint? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        var best: (CGPoint, CGFloat)?
        for id in ids.prefix(Int(n)) where id != excluded {
            let b = CGDisplayBounds(id).insetBy(dx: 1, dy: 1)
            guard b.width > 0, b.height > 0 else { continue }
            let q = CGPoint(x: min(max(p.x, b.minX), b.maxX), y: min(max(p.y, b.minY), b.maxY))
            let d = hypot(q.x - p.x, q.y - p.y)
            if best == nil || d < best!.1 { best = (q, d) }
        }
        return best?.0
    }

    func moveCursor(toScreen id: CGDirectDisplayID, now: TimeInterval) {
        let b = CGDisplayBounds(id)
        warp(to: CGPoint(x: b.midX, y: b.midY), now: now)
    }

    func reset() {
        savedPositions.removeAll()
        candidate = nil
    }

    private func warp(to p: CGPoint, now: TimeInterval) {
        CGWarpMouseCursorPosition(p)
        // Re-associate immediately so the mouse doesn't freeze for ~250 ms after the warp.
        CGAssociateMouseAndMouseCursorPosition(1)
        lastPos = p
        suppressUntil = now + 0.05
    }
}
