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

    private var lastGood: CGPoint?
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

        // 1. Guard the glasses' own display.
        if let g = guardDisplay, CGDisplayBounds(g).insetBy(dx: -0.5, dy: -0.5).contains(loc) {
            let target = lastGood ?? CGPoint(x: CGDisplayBounds(CGMainDisplayID()).midX, y: CGDisplayBounds(CGMainDisplayID()).midY)
            warp(to: target, now: now)
            return nil
        }
        lastGood = loc

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

    func moveCursor(toScreen id: CGDirectDisplayID, now: TimeInterval) {
        let b = CGDisplayBounds(id)
        warp(to: CGPoint(x: b.midX, y: b.midY), now: now)
    }

    func reset() {
        savedPositions.removeAll()
        candidate = nil
        lastGood = nil
    }

    private func warp(to p: CGPoint, now: TimeInterval) {
        CGWarpMouseCursorPosition(p)
        // Re-associate immediately so the mouse doesn't freeze for ~250 ms after the warp.
        CGAssociateMouseAndMouseCursorPosition(1)
        lastPos = p
        lastGood = p
        suppressUntil = now + 0.05
    }
}
