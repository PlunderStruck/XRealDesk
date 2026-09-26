import AppKit
import CoreGraphics
import XRCore

/// Finds the glasses' physical display, switches it from mirroring to extended, and arranges the
/// virtual screens so the mouse moves between them the same way they're laid out in the glasses.
///
/// Every change uses `.forAppOnly`, so macOS reverts it automatically when the app quits or crashes:
/// the glasses go back to mirroring exactly as before.
enum DisplayConfigurator {

    static func onlineDisplays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var n: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &ids, &n) == .success else { return [] }
        return Array(ids.prefix(Int(n)))
    }

    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }

    static func name(of id: CGDirectDisplayID) -> String {
        screen(for: id)?.localizedName ?? "Display \(id)"
    }

    /// The glasses' own display: EDID vendor "MRG" (XREAL), or a screen whose name says so.
    static func findGlassesDisplay(override: CGDirectDisplayID? = nil) -> CGDirectDisplayID? {
        let online = onlineDisplays().filter { !VirtualDisplayManager.isVirtual($0) }
        if let override, online.contains(override) { return override }
        if let byVendor = online.first(where: { CGDisplayVendorNumber($0) == XRealProtocol.displayVendorNumber }) {
            return byVendor
        }
        let keywords = ["xreal", "nreal", "air 2", "air2"]
        return online.first { id in
            guard CGDisplayIsBuiltin(id) == 0 else { return false }
            let n = name(of: id).lowercased()
            return keywords.contains { n.contains($0) }
        }
    }

    static func isMirrored(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayIsInMirrorSet(id) != 0
    }

    /// Make the glasses mirror `main` (normally the laptop screen) for the rest of the login session,
    /// so when XRealDesk isn't running they show your main screen instead of an empty desktop.
    @discardableResult
    static func mirror(_ glasses: CGDirectDisplayID, of main: CGDirectDisplayID) -> Bool {
        guard glasses != main, CGDisplayMirrorsDisplay(glasses) != main else { return false }
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success, let cfg else { return false }
        CGConfigureDisplayMirrorOfDisplay(cfg, glasses, main)
        let r = CGCompleteDisplayConfiguration(cfg, .forSession)
        Log.info("Glasses display \(glasses) set to mirror display \(main): \(r.rawValue)")
        return r == .success
    }

    /// Break the mirror set containing the glasses. Returns true if a change was requested.
    @discardableResult
    static func extend(_ glasses: CGDirectDisplayID) -> Bool {
        guard isMirrored(glasses) else { return false }
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success, let cfg else { return false }
        // Either the glasses mirror another display, or others mirror the glasses.
        CGConfigureDisplayMirrorOfDisplay(cfg, glasses, kCGNullDirectDisplay)
        for other in onlineDisplays() where other != glasses && CGDisplayMirrorsDisplay(other) == glasses {
            CGConfigureDisplayMirrorOfDisplay(cfg, other, kCGNullDirectDisplay)
        }
        let r = CGCompleteDisplayConfiguration(cfg, .forAppOnly)
        Log.info("Switched glasses display \(glasses) from mirroring to extended: \(r.rawValue)")
        return r == .success
    }

    /// The physical display the virtual screens are arranged around (normally the laptop screen).
    static func homeDisplay(excluding glasses: CGDirectDisplayID?) -> CGDirectDisplayID {
        let physical = onlineDisplays().filter { !VirtualDisplayManager.isVirtual($0) && $0 != glasses }
        let main = CGMainDisplayID()
        if physical.contains(main) { return main }
        return physical.first { CGDisplayIsBuiltin($0) != 0 } ?? physical.first ?? main
    }

    /// Desired global positions (CG coordinates, y down) for every display we touch:
    /// virtual screens in a grid above the home display, the glasses' own display parked bottom-left.
    /// If `mainIndex` is set, everything is shifted so that virtual screen becomes the main display
    /// (macOS makes whichever display sits at 0,0 the main one: menu bar, Dock, new windows).
    static func plannedOrigins(virtualIDs: [CGDirectDisplayID], count: Int, rows: Int, pointSize: CGSize,
                               glasses: CGDirectDisplayID?, mainIndex: Int?,
                               placement: ScreenPlacement = .above,
                               customOffsets: [Int: CGPoint] = [:]) -> [CGDirectDisplayID: CGPoint] {
        let homeID = homeDisplay(excluding: glasses)
        let home = CGDisplayBounds(homeID)
        var out: [CGDirectDisplayID: CGPoint] = [:]
        let physical = onlineDisplays().filter { !VirtualDisplayManager.isVirtual($0) && $0 != glasses }
        for id in physical { out[id] = CGDisplayBounds(id).origin }

        // Glasses screens as a grid, same layout you see in the glasses (row 0 = bottom row),
        // placed against the chosen side of the laptop so the mouse moves across naturally.
        let cells = ScreenLayout.grid(count: count, rows: rows)
        let w = pointSize.width, h = pointSize.height
        let rowCount = (cells.map(\.row).max() ?? 0) + 1
        let maxCols = cells.map(\.colsInRow).max() ?? 1
        let gridH = CGFloat(rowCount) * h
        for (i, id) in virtualIDs.enumerated() where i < cells.count {
            let c = cells[i]
            let rowWidth = CGFloat(c.colsInRow) * w
            let fromTop = CGFloat(rowCount - 1 - c.row)   // visual row index counted from the top
            var p: CGPoint
            switch placement {
            case .above, .custom:
                p = CGPoint(x: home.midX - rowWidth / 2 + CGFloat(c.col) * w, y: home.minY - gridH + fromTop * h)
            case .below:
                p = CGPoint(x: home.midX - rowWidth / 2 + CGFloat(c.col) * w, y: home.maxY + fromTop * h)
            case .left:
                p = CGPoint(x: home.minX - CGFloat(maxCols) * w + CGFloat(c.col) * w, y: home.midY - gridH / 2 + fromTop * h)
            case .right:
                p = CGPoint(x: home.maxX + CGFloat(c.col) * w, y: home.midY - gridH / 2 + fromTop * h)
            }
            if placement == .custom, let o = customOffsets[i] {
                p = CGPoint(x: home.minX + o.x, y: home.minY + o.y)   // your own arrangement
            }
            out[id] = CGPoint(x: p.x.rounded(), y: p.y.rounded())
        }
        if let glasses {
            // Park the glasses' own display beyond everything else; the cursor guard keeps the mouse off it.
            let minX = out.values.map(\.x).min() ?? home.minX
            let gb = CGDisplayBounds(glasses)
            out[glasses] = CGPoint(x: minX - gb.width, y: home.maxY - gb.height)
        }
        if let mainIndex, mainIndex < virtualIDs.count, let pivot = out[virtualIDs[mainIndex]] {
            for (id, p) in out { out[id] = CGPoint(x: p.x - pivot.x, y: p.y - pivot.y) }
        }
        return out
    }

    /// True if the virtual displays sit where planned relative to the home display
    /// (macOS may translate the whole arrangement, so only relative positions matter).
    static func virtualArrangementMatches(_ origins: [CGDirectDisplayID: CGPoint], virtualIDs: [CGDirectDisplayID],
                                          glasses: CGDirectDisplayID?) -> Bool {
        let homeID = homeDisplay(excluding: glasses)
        guard let homePlanned = origins[homeID] else { return false }
        let homeActual = CGDisplayBounds(homeID).origin
        return virtualIDs.allSatisfy { id in
            guard let p = origins[id] else { return true }
            let b = CGDisplayBounds(id).origin
            return abs((b.x - homeActual.x) - (p.x - homePlanned.x)) <= 2
                && abs((b.y - homeActual.y) - (p.y - homePlanned.y)) <= 2
        }
    }

    /// Apply positions if they differ from the current ones. Returns true if anything changed.
    @discardableResult
    static func arrange(_ origins: [CGDirectDisplayID: CGPoint]) -> Bool {
        let needed = origins.filter { id, p in
            let b = CGDisplayBounds(id)
            return abs(b.minX - p.x) > 0.5 || abs(b.minY - p.y) > 0.5
        }
        guard !needed.isEmpty else { return false }
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success, let cfg else { return false }
        for (id, p) in origins {
            CGConfigureDisplayOrigin(cfg, id, Int32(p.x), Int32(p.y))
        }
        let r = CGCompleteDisplayConfiguration(cfg, .forAppOnly)
        Log.info("Arranged \(origins.count) displays: \(r.rawValue)")
        return r == .success
    }
}
