import CoreGraphics

/// Where the glasses screens sit relative to the laptop screen in macOS's display arrangement,
/// i.e. which edge of the laptop screen the mouse crosses to reach them.
public enum ScreenPlacement: String, CaseIterable, Identifiable, Sendable {
    case above, below, left, right, custom
    public var id: String { rawValue }
}

public enum Arrangement {
    /// Top-left origins (macOS global points, y down) for the glasses screens: a grid like the one
    /// you see in the glasses (row 0 = bottom row), placed against `placement`'s side of `home`.
    /// `customOffsets` (per screen, from home's top-left) are used for `.custom`.
    public static func gridOrigins(home: CGRect, count: Int, rows: Int, screenSize: CGSize,
                                   placement: ScreenPlacement, customOffsets: [Int: CGPoint] = [:]) -> [CGPoint] {
        let cells = ScreenLayout.grid(count: max(count, 0), rows: max(rows, 1))
        let w = screenSize.width, h = screenSize.height
        let rowCount = (cells.map(\.row).max() ?? 0) + 1
        let gridH = CGFloat(rowCount) * h
        // Round the grid's corner once and step by whole screen sizes: rounding each row on its own
        // split rows by a point (macOS then treats them as separate and shoves displays around).
        let sw = w.rounded(), sh = h.rounded()
        let top: CGFloat
        switch placement {
        case .above, .custom: top = (home.minY - gridH).rounded()
        case .below: top = home.maxY.rounded()
        case .left, .right: top = (home.midY - gridH / 2).rounded()
        }
        // Custom: screens without a saved position (you added screens since saving) go in a row on top
        // of everything, so they can never overlap a saved one.
        var extraSlot = 0
        let saved = customOffsets.filter { $0.key < cells.count }.map { CGRect(x: home.minX + $0.value.x, y: home.minY + $0.value.y, width: sw, height: sh) }
        let extraTop = ((saved + [home]).map(\.minY).min() ?? home.minY) - sh
        let extraLeft = ((saved.isEmpty ? [home] : saved).min { $0.minY < $1.minY } ?? home).minX
        return cells.enumerated().map { i, c in
            let fromTop = CGFloat(rowCount - 1 - c.row)   // visual row index counted from the top
            let y = top + fromTop * sh
            let x: CGFloat
            switch placement {
            case .above, .below, .custom:
                x = (home.midX - CGFloat(c.colsInRow) * sw / 2).rounded() + CGFloat(c.col) * sw
            case .left:
                // Shorter rows hug the laptop, so every row can be reached with the mouse.
                x = home.minX.rounded() - CGFloat(c.colsInRow) * sw + CGFloat(c.col) * sw
            case .right:
                x = home.maxX.rounded() + CGFloat(c.col) * sw
            }
            if placement == .custom {
                if let o = customOffsets[i] {
                    return CGPoint(x: (home.minX + o.x).rounded(), y: (home.minY + o.y).rounded())   // your own arrangement
                }
                defer { extraSlot += 1 }
                return CGPoint(x: extraLeft.rounded() + CGFloat(extraSlot) * sw, y: extraTop.rounded())
            }
            return CGPoint(x: x, y: y)
        }
    }
}
