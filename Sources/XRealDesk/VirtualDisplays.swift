import AppKit
import CoreGraphics
import CVirtualDisplay

/// Creates real macOS displays (you can drag windows onto them, they get their own Spaces and menu bar)
/// that exist only while the app keeps them alive. They vanish automatically if the app quits or crashes,
/// and macOS moves their windows back to a physical screen.
final class VirtualDisplayManager {
    static let vendorID: UInt32 = 0x5844     // "XD"
    static let productBase: UInt32 = 0x4400

    struct Screen {
        let index: Int
        let display: CGVirtualDisplay
        var id: CGDirectDisplayID { display.displayID }
        var pointSize: CGSize
        var pixelSize: CGSize
    }

    /// Framebuffer headroom so resolution changes can be applied in place (windows stay put).
    static let maxPixels = (width: 7680, height: 2880)

    private(set) var screens: [Screen] = []
    private var modeSignature = ""
    private var resolution = ResolutionPreset.default
    private var hiDPI = false
    private var refreshRate = 60

    /// Same format as `Settings.displaySignature`.
    var signature: String { screens.isEmpty ? "" : "\(screens.count)-\(modeSignature)" }

    static func isVirtual(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(id) == vendorID
    }

    enum SyncResult { case unchanged, resized, remoded, recreated }

    /// Bring the set of virtual displays in line with the settings. Changing only the count adds or
    /// removes displays at the end, so windows on the screens you keep don't get shuffled.
    func sync(count: Int, resolution: ResolutionPreset, hiDPI: Bool, refreshRate: Int) -> SyncResult {
        let mode = "\(resolution.id)-\(hiDPI)-\(refreshRate)"
        if mode != modeSignature, !screens.isEmpty, fits(resolution, hiDPI: hiDPI) {
            // Change the mode of the existing displays: macOS resizes them and keeps their windows.
            self.resolution = resolution
            self.hiDPI = hiDPI
            self.refreshRate = refreshRate
            var ok = true
            for i in screens.indices {
                ok = ok && screens[i].display.apply(makeSettings())
                screens[i].pointSize = CGSize(width: resolution.width, height: resolution.height)
                screens[i].pixelSize = CGSize(width: resolution.width * (hiDPI ? 2 : 1), height: resolution.height * (hiDPI ? 2 : 1))
            }
            if ok {
                modeSignature = mode
                Log.info("Changed virtual displays to \(resolution.id)\(hiDPI ? " HiDPI" : "") @\(refreshRate)Hz in place")
                addMissingScreens(upTo: count)
                screens.removeAll { $0.index >= count }
                return .remoded
            }
            Log.error("In-place mode change failed; recreating displays")
        }
        if mode != modeSignature || screens.isEmpty {
            destroyAll()
            self.resolution = resolution
            self.hiDPI = hiDPI
            self.refreshRate = refreshRate
            modeSignature = mode
            addMissingScreens(upTo: count)
            return .recreated
        }
        let wanted = Set(0..<count)
        guard Set(screens.map(\.index)) != wanted else { return .unchanged }
        if screens.contains(where: { $0.index >= count }) {
            Log.info("Removing virtual displays \(count + 1)...")
            screens.removeAll { $0.index >= count }
        }
        addMissingScreens(upTo: count)
        return .resized
    }

    /// Creates every screen slot below `count` that doesn't exist yet (e.g. one whose creation failed
    /// earlier), keeping slots unique and in order.
    private func addMissingScreens(upTo count: Int) {
        let have = Set(screens.map(\.index))
        for i in 0..<count where !have.contains(i) {
            if let s = makeScreen(index: i) { screens.append(s) }
        }
        screens.sort { $0.index < $1.index }
    }

    private func makeScreen(index i: Int) -> Screen? {
        let scale = hiDPI ? 2 : 1
        let pointW = resolution.width, pointH = resolution.height
        let pixelW = pointW * scale, pixelH = pointH * scale

        let desc = CGVirtualDisplayDescriptor()
        desc.setDispatchQueue(DispatchQueue.main)
        desc.name = "XRealDesk \(i + 1)"
        desc.maxPixelsWide = UInt32(max(pixelW, Self.maxPixels.width))
        desc.maxPixelsHigh = UInt32(max(pixelH, Self.maxPixels.height))
        // ~ 100 points per inch. Keeps macOS's default text scaling sensible.
        desc.sizeInMillimeters = CGSize(width: Double(pointW) * 0.254, height: Double(pointH) * 0.254)
        desc.vendorID = Self.vendorID
        desc.productID = Self.productBase + UInt32(i)
        desc.serialNum = UInt32(0x1000 + i)   // stable per slot so macOS remembers arrangement/Spaces
        desc.terminationHandler = { _, display in
            Log.info("Virtual display \(display.displayID) terminated by the system")
        }

        guard let display = CGVirtualDisplay(descriptor: desc) else {
            Log.error("CGVirtualDisplay init failed for screen \(i + 1)")
            return nil
        }
        if !display.apply(makeSettings()) {
            Log.error("applySettings failed for virtual display \(display.displayID)")
        }
        Log.info("Created virtual display \(i + 1): id \(display.displayID) \(pointW)x\(pointH)\(hiDPI ? " HiDPI" : "") @\(refreshRate)Hz")
        return Screen(index: i, display: display,
                      pointSize: CGSize(width: pointW, height: pointH),
                      pixelSize: CGSize(width: pixelW, height: pixelH))
    }

    private func makeSettings() -> CGVirtualDisplaySettings {
        let scale = hiDPI ? 2 : 1
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI ? 1 : 0
        var modes = [CGVirtualDisplayMode(width: UInt(resolution.width * scale), height: UInt(resolution.height * scale),
                                          refreshRate: CGFloat(refreshRate))]
        if hiDPI {
            modes.append(CGVirtualDisplayMode(width: UInt(resolution.width), height: UInt(resolution.height),
                                              refreshRate: CGFloat(refreshRate)))
        }
        settings.modes = modes
        return settings
    }

    private func fits(_ r: ResolutionPreset, hiDPI: Bool) -> Bool {
        let s = hiDPI ? 2 : 1
        return r.width * s <= Self.maxPixels.width && r.height * s <= Self.maxPixels.height
    }

    /// Make sure each virtual display runs the intended mode (HiDPI "looks like" size with 2x pixels).
    /// Returns true when every display is online and in the right mode.
    @discardableResult
    func enforceModes() -> Bool {
        var allGood = true
        for s in screens {
            guard CGDisplayIsOnline(s.id) != 0 else { allGood = false; continue }
            if let cur = CGDisplayCopyDisplayMode(s.id),
               cur.width == Int(s.pointSize.width), cur.pixelWidth == Int(s.pixelSize.width) {
                continue
            }
            let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
            let modes = (CGDisplayCopyAllDisplayModes(s.id, opts) as? [CGDisplayMode]) ?? []
            if let m = modes.first(where: { $0.width == Int(s.pointSize.width) && $0.pixelWidth == Int(s.pixelSize.width) }) {
                let r = CGDisplaySetDisplayMode(s.id, m, nil)
                Log.info("Set mode on virtual display \(s.index + 1): \(m.width)x\(m.height) (\(m.pixelWidth)px) -> \(r.rawValue)")
                if r != .success { allGood = false }
            } else {
                let list = modes.map { "\($0.width)x\($0.height)/\($0.pixelWidth)" }.joined(separator: ", ")
                Log.info("No exact mode for display \(s.index + 1); available: \(list)")
            }
        }
        return allGood
    }

    func destroyAll() {
        if !screens.isEmpty { Log.info("Removing \(screens.count) virtual display(s)") }
        screens.removeAll()   // releasing CGVirtualDisplay objects removes the displays
        modeSignature = ""
    }

    /// Current pixel size of a display (the capture size).
    static func pixelSize(of id: CGDirectDisplayID) -> CGSize? {
        guard let m = CGDisplayCopyDisplayMode(id) else { return nil }
        return CGSize(width: m.pixelWidth, height: m.pixelHeight)
    }
}
