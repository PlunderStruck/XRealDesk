import Foundation
import Metal
import simd
import XRCore

// GPU checks of the real renderer shader (RendererShaders.source, the same code the app runs):
// it must compile, draw the right screen where you look (curved, flat, tilted, with and without the
// lens map), and never produce NaN / infinite / out-of-range pixels for any combination of picture
// settings. Renders into a float target so nothing is clamped away.

func shaderChecks() {
    print("renderer shader (GPU)")
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
        print("  skip (no Metal device)"); return
    }
    let lib: MTLLibrary
    do { lib = try device.makeLibrary(source: RendererShaders.source, options: nil) } catch {
        check(false, "shaders compile: \(error)"); return
    }
    let names = ["panelVertex", "panelFragment", "warpVertex", "warpFragment", "directFragment"]
    check(names.allSatisfy { lib.makeFunction(name: $0) != nil }, "shaders compile and every entry point exists")
    let pd = MTLRenderPipelineDescriptor()
    pd.vertexFunction = lib.makeFunction(name: "warpVertex")
    pd.fragmentFunction = lib.makeFunction(name: "directFragment")
    pd.colorAttachments[0].pixelFormat = .rgba32Float
    guard let pipe = try? device.makeRenderPipelineState(descriptor: pd) else { check(false, "direct pipeline builds"); return }


    let sd = MTLSamplerDescriptor(); sd.minFilter = .linear; sd.magFilter = .linear; sd.mipFilter = .linear
    sd.maxAnisotropy = 16; sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
    let ld = MTLSamplerDescriptor(); ld.minFilter = .linear; ld.magFilter = .linear
    ld.sAddressMode = .clampToZero; ld.tAddressMode = .clampToZero
    let smp = device.makeSamplerState(descriptor: sd)!, lin = device.makeSamplerState(descriptor: ld)!

    // Screen textures (gamma values, like the app's captures): a flat color per screen with fine
    // black/white stripes (text-like detail) and a gray marker in the middle.
    let colors: [SIMD3<UInt8>] = [SIMD3(220, 40, 40), SIMD3(40, 200, 60), SIMD3(50, 80, 230), SIMD3(230, 200, 40)]
    func screenTexture(_ c: SIMD3<UInt8>, w: Int, h: Int) -> MTLTexture {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        let t = device.makeTexture(descriptor: td)!
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            var v = c
            if y > h * 7 / 8 { v = (x / 2) % 2 == 0 ? SIMD3(0, 0, 0) : SIMD3(255, 255, 255) }      // stripes
            if abs(x - w / 2) < max(w / 40, 1), abs(y - h / 2) < max(h / 40, 1) { v = SIMD3(128, 128, 128) } // marker
            px[i] = v.z; px[i + 1] = v.y; px[i + 2] = v.x
        } }
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: px, bytesPerRow: w * 4)
        return t
    }
    let bigScreens = colors.map { screenTexture($0, w: 1600, h: 900) }     // ~2 texels per output px (HiDPI-like)
    let smallScreens = colors.map { screenTexture($0, w: 160, h: 90) }     // magnified
    let dummy = screenTexture(SIMD3(0, 0, 0), w: 1, h: 1)
    let cursor = screenTexture(SIMD3(255, 255, 255), w: 16, h: 16)

    // Identity lens map (calibration px → same px), same layout as the app's.
    let cal = SIMD2<Float>(1920, 1080), step: Float = 8
    let mw = Int(cal.x / step) + 1, mh = Int(cal.y / step) + 1
    let mdesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg32Float, width: mw, height: mh, mipmapped: false)
    let map = device.makeTexture(descriptor: mdesc)!
    var mvals = [SIMD2<Float>](repeating: .zero, count: mw * mh)
    for j in 0..<mh { for i in 0..<mw { mvals[j * mw + i] = SIMD2(Float(i) * step, Float(j) * step) } }
    map.replace(region: MTLRegionMake2D(0, 0, mw, mh), mipmapLevel: 0, withBytes: mvals, bytesPerRow: mw * 8)

    let outW = 480, outH = 270
    let od = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: outW, height: outH, mipmapped: false)
    od.usage = [.renderTarget]; od.storageMode = .shared
    let out = device.makeTexture(descriptor: od)!

    struct Scene { var layout: ScreenLayout; var yaw: Float = 0; var pitch: Float = 0; var eye = SIMD3<Float>(repeating: 0) }
    func render(_ scene: Scene, screens: [MTLTexture], lens: Bool = false, configure: (inout RendererShaders.DirectUniforms) -> Void = { _ in },
                cursorOn: Int? = nil, pipeline: MTLRenderPipelineState? = nil,
                overlay: [RendererShaders.OverlayItem] = [], hideScreens: Bool = false) -> [SIMD4<Float>] {
        let panels = Array(scene.layout.panels.prefix(8))
        var gpuPanels = panels.map { p in
            RendererShaders.DirectPanel(arcCenter: p.arcCenter, height: p.height, width: p.size.x, panelHeight: p.size.y,
                                        highlight: p.index == 0 ? 0.9 : 0, dim: p.index == 2 ? 0.5 : 0, hasTexture: 1,
                                        hasCursor: cursorOn == p.index ? 1 : 0, cursorRect: SIMD4(0.45, 0.45, 0.55, 0.55))
        }
        if gpuPanels.isEmpty { gpuPanels.append(.init(arcCenter: 0, height: 0, width: 1, panelHeight: 1, highlight: 0, dim: 0,
                                                     hasTexture: 0, hasCursor: 0, cursorRect: .zero)) }
        let head = SpatialMath.orientation(yaw: scene.yaw, pitch: scene.pitch)
        let view = simd_float4x4(head.inverse) * SpatialMath.translation(-scene.eye) * simd_float4x4(scene.layout.tiltRotation)
        let radius = scene.layout.radius.isFinite ? scene.layout.radius : 0
        var u = RendererShaders.DirectUniforms(
            invView: view.inverse, focal: SIMD2(2697, 2711), center: SIMD2(960, 547),
            toCalibrated: cal / SIMD2(Float(outW), Float(outH)), mapSize: SIMD2(Float(mw), Float(mh)), mapStep: step,
            lensOn: lens ? 1 : 0, originX: 0, radius: radius, distance: scene.layout.distance, cornerRadius: 0.018,
            sharpen: 0.35, quality: 2, panelCount: Float(panels.count))
        configure(&u)
        var items = overlay.isEmpty ? [RendererShaders.OverlayItem(a: .zero, color: .zero)] : overlay
        u.overlay = SIMD4(Float(overlay.count), hideScreens ? 1 : 0, 0, 0)
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = out; rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].storeAction = .store
        let cb = queue.makeCommandBuffer()!, enc = cb.makeRenderCommandEncoder(descriptor: rp)!
        enc.setRenderPipelineState(pipeline ?? pipe)
        enc.setFragmentSamplerState(smp, index: 0); enc.setFragmentSamplerState(lin, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<RendererShaders.DirectUniforms>.stride, index: 0)
        enc.setFragmentBytes(&gpuPanels, length: MemoryLayout<RendererShaders.DirectPanel>.stride * gpuPanels.count, index: 1)
        enc.setFragmentBytes(&items, length: MemoryLayout<RendererShaders.OverlayItem>.stride * items.count, index: 2)
        enc.setFragmentTexture(map, index: 0); enc.setFragmentTexture(cursor, index: 1)
        for i in 0..<8 { enc.setFragmentTexture(i < panels.count ? screens[panels[i].index % screens.count] : dummy, index: 2 + i) }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        var px = [SIMD4<Float>](repeating: .zero, count: outW * outH)
        out.getBytes(&px, bytesPerRow: outW * 16, from: MTLRegionMake2D(0, 0, outW, outH), mipmapLevel: 0)
        return px
    }
    // Which screen color is at a pixel (colors are linear here: compare channel ordering only).
    func screenAt(_ px: [SIMD4<Float>], x: Int, y: Int) -> Int? {
        let c = px[y * outW + x]
        guard c.x + c.y + c.z > 0.02 else { return nil }
        let order = colors.map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) }
        let v = SIMD3(c.x, c.y, c.z) / max(c.x, max(c.y, c.z))
        return order.indices.min { simd_length(v - order[$0] / order[$0].max()) < simd_length(v - order[$1] / order[$1].max()) }
    }
    // The image centre is the calibrated principal point, scaled to the output.
    let cx = Int(960.0 / 1920 * Double(outW)), cy = Int(547.0 / 1080 * Double(outH))

    print("renderer shader: world-locked session overlay")
    do {
        // A green dot 10° to the left must land where 10° left appears; the screens are hidden.
        let layout = ScreenLayout(count: 2, rows: 1, widthDegrees: 33, aspect: 16.0 / 9, gapDegrees: 1.5, curve: 0.55)
        let focalOut = 2697 * Float(outW) / 1920
        if let c = layout.surface(yawDegrees: 10, pitchDegrees: 0) {
            let dot = RendererShaders.OverlayItem.circle(c, radius: 0.02, color: SIMD4(0, 1, 0, 1))
            let px = render(Scene(layout: layout), screens: bigScreens, overlay: [dot], hideScreens: true)
            let x = cx - Int((focalOut * tan(SpatialMath.radians(10))).rounded())
            let at = px[cy * outW + x], centre = px[cy * outW + cx]
            check(at.y > 0.8 && at.x < 0.2, String(format: "dot drawn where 10° left appears (green %.2f)", at.y))
            check(centre.x + centre.y + centre.z < 0.01, "screens hidden while the session draws its own")
        } else {
            check(false, "10° left is on the layout surface")
        }
    }

    print("renderer shader: eye position (neck model)")
    do {
        // Moving the eye 5 cm right must shift a screen 1.5 m away left by atan(0.05/1.5) = 1.91°.
        let layout = ScreenLayout(count: 1, rows: 1, widthDegrees: 33, aspect: 16.0 / 9, gapDegrees: 1.5, curve: 0)
        func markerX(_ px: [SIMD4<Float>]) -> Float? {
            var sum: Float = 0, n: Float = 0
            for x in 0..<outW {
                let c = px[cy * outW + x]
                if abs(c.x - c.y) < 0.02, abs(c.y - c.z) < 0.02, c.x > 0.1, c.x < 0.4 { sum += Float(x); n += 1 }
            }
            return n > 0 ? sum / n : nil
        }
        let focalOut = 2697 * Float(outW) / 1920
        if let a = markerX(render(Scene(layout: layout), screens: bigScreens)),
           let b = markerX(render(Scene(layout: layout, eye: SIMD3(0.05, 0, 0)), screens: bigScreens)) {
            let shiftDeg = deg(atan((a - b) / focalOut))
            check(abs(shiftDeg - deg(atan(0.05 / 1.5))) < 0.1, String(format: "eye 5 cm right: screen shifts left %.2f° (expected %.2f°)", shiftDeg, deg(atan(0.05 / 1.5))))
        } else {
            check(false, "marker visible for the eye-position check")
        }
    }

    print("renderer shader: rolling scan-out compensation")
    do {
        // A 1° yaw during the scan-out: rows lit later are drawn for the head turned further, so a
        // vertical screen edge shifts by the matching amount between upper and lower rows.
        let layout = ScreenLayout(count: 1, rows: 1, widthDegrees: 33, aspect: 16.0 / 9, gapDegrees: 1.5, curve: 0)
        func leftEdge(_ px: [SIMD4<Float>], row: Int) -> Float? {
            (0..<outW).first { px[row * outW + $0].x + px[row * outW + $0].y + px[row * outW + $0].z > 0.05 }.map(Float.init)
        }
        let a: Float = SpatialMath.radians(1)
        let still = render(Scene(layout: layout), screens: bigScreens) { $0.dither = 0 }
        let comp = render(Scene(layout: layout), screens: bigScreens) { $0.dither = 0; $0.scanRows = 1080; $0.scanDir = 1; $0.scan = SIMD4(0, a, 0, 0) }
        let flipped = render(Scene(layout: layout), screens: bigScreens) { $0.dither = 0; $0.scanRows = 1080; $0.scanDir = -1; $0.scan = SIMD4(0, a, 0, 0) }
        let top = outH / 5 + 10, bottom = outH * 4 / 5 - 10
        if let s0 = leftEdge(still, row: top), let s1 = leftEdge(still, row: bottom),
           let c0 = leftEdge(comp, row: top), let c1 = leftEdge(comp, row: bottom),
           let f0 = leftEdge(flipped, row: top), let f1 = leftEdge(flipped, row: bottom) {
            let expected = 2697 * Float(outW) / 1920 * a * Float(bottom - top) / Float(outH)
            check(abs(s1 - s0) < 1.01, "no compensation: the edge is straight (\(s1 - s0) px)")
            check(abs((c1 - c0) - expected) < 1.6, String(format: "1° over the scan-out shears the edge by %.1f px (expected %.1f)", c1 - c0, expected))
            check(abs((f1 - f0) + (c1 - c0)) < 1.6, "bottom-to-top scan shears the other way")
            let mid = outH / 2
            check(leftEdge(comp, row: mid).map { abs($0 - (leftEdge(still, row: mid) ?? -99)) < 1.01 } ?? false, "the middle row (the predicted moment) doesn't move")
        } else { check(false, "screen edge visible for the scan check") }
    }

    print("renderer shader: geometry")
    var geomBad: [String] = []
    for (name, curve, tilt) in [("curved", Float(0.55), Float(0)), ("flat", 0, 0), ("wrapped", 1, 0), ("raised 12°", 0.55, 12)] {
        let layout = ScreenLayout(count: 3, rows: 1, widthDegrees: 33, aspect: 16.0 / 9, gapDegrees: 1.5, curve: curve, tiltDegrees: tilt)
        for lens in [false, true] {
            for p in layout.panels {
                // Look a bit above the screen's centre (the marker sits in the middle) at its colored area.
                let px = render(Scene(layout: layout, yaw: p.yaw, pitch: p.pitch + SpatialMath.radians(4)), screens: bigScreens, lens: lens)
                if screenAt(px, x: cx, y: cy) != p.index { geomBad.append("\(name) lens \(lens) screen \(p.index)") }
            }
        }
    }
    check(geomBad.isEmpty, "looking at each screen draws that screen in the middle of the view (curved, flat, wrapped, raised; lens on/off)\(geomBad.isEmpty ? "" : ": " + geomBad.joined(separator: ", "))")
    let side = render(Scene(layout: ScreenLayout(count: 3, rows: 1, widthDegrees: 33, aspect: 16.0 / 9, gapDegrees: 1.5, curve: 0.55)), screens: bigScreens)
    check(screenAt(side, x: 4, y: cy) == 0 && screenAt(side, x: outW - 5, y: cy) == 2,
          "looking at the middle screen, its neighbours appear on the correct sides")
    let empty = render(Scene(layout: ScreenLayout(count: 0, rows: 1, widthDegrees: 33, aspect: 16.0 / 9, gapDegrees: 1.5, curve: 0.5)), screens: bigScreens)
    check(empty.allSatisfy { $0.x == 0 && $0.y == 0 && $0.z == 0 }, "no screens: a black picture (no garbage)")
    let away = render(Scene(layout: ScreenLayout(count: 1, rows: 1, widthDegrees: 33, aspect: 16.0 / 9, gapDegrees: 1.5, curve: 0.5), yaw: .pi), screens: bigScreens)
    check(away.allSatisfy { $0.x == 0 && $0.y == 0 && $0.z == 0 }, "looking straight away from the screens: black")

    print("renderer shader: every picture setting combination")
    var combos = 0, badPixels = 0, firstBad = ""
    let layout = ScreenLayout(count: 4, rows: 2, widthDegrees: 33, aspect: 16.0 / 9, gapDegrees: 1.5, curve: 0.55)
    let whites: [SIMD4<Float>] = [SIMD4(0.7, 0.93, 1, 1), SIMD4(1, 1, 1, 1), SIMD4(1, 0.9, 0.62, 1)]
    for screens in [bigScreens, smallScreens] {
        for sharpen: Float in [0, 0.5, 1] { for subpixel: Float in [0, 1, 2, 3, 4] { for strength: Float in [0, 1] {
            for dither: Float in [0, 1] { for motion: Float in [0, 0.5, 1] { for white in whites { for quality: Float in [1, 2] {
                for lens in [false, true] {
                    combos += 1
                    let px = render(Scene(layout: layout, yaw: 0.1, pitch: 0.05), screens: screens, lens: lens, configure: { u in
                        u.sharpen = sharpen; u.subpixel = subpixel; u.subpixelStrength = strength; u.dither = dither
                        u.motion = motion; u.white = white; u.quality = quality; u.frame = Float(combos % 64)
                    }, cursorOn: 1)
                    let bad = px.filter { !($0.x.isFinite && $0.y.isFinite && $0.z.isFinite) || $0.x < 0 || $0.y < 0 || $0.z < 0
                        || $0.x > 1.0001 || $0.y > 1.0001 || $0.z > 1.0001 }.count
                    if bad > 0, firstBad.isEmpty {
                        firstBad = "sharpen \(sharpen) subpixel \(subpixel) strength \(strength) dither \(dither) motion \(motion) white \(white) quality \(quality) lens \(lens)"
                    }
                    badPixels += bad
                }
            } } } } } } }
    }
    check(badPixels == 0, "\(combos) setting combinations (sharpen, subpixel mode/strength, dither, motion, warmth, quality, lens, HiDPI/magnified): every pixel finite and in range\(firstBad.isEmpty ? "" : " — first bad: " + firstBad)")

    print("renderer shader: effects do what they claim")
    let still = render(Scene(layout: layout, yaw: 0.1, pitch: 0.05), screens: bigScreens) { $0.dither = 0; $0.subpixel = 2; $0.subpixelStrength = 1 }
    let ditherA = render(Scene(layout: layout, yaw: 0.1, pitch: 0.05), screens: bigScreens) { $0.dither = 1; $0.frame = 1; $0.subpixel = 2; $0.subpixelStrength = 1 }
    let ditherB = render(Scene(layout: layout, yaw: 0.1, pitch: 0.05), screens: bigScreens) { $0.dither = 1; $0.frame = 2; $0.subpixel = 2; $0.subpixelStrength = 1 }
    let dMean = zip(still, ditherA).map { abs($0.x - $1.x) }.reduce(0, +) / Float(still.count)
    check(dMean > 0 && dMean < 0.01, String(format: "dithering changes pixels by less than about a step on average (%.4f)", dMean))
    check(zip(ditherA, ditherB).contains { $0 != $1 }, "dithering varies from frame to frame (temporal)")
    let warm = render(Scene(layout: layout, yaw: 0.1, pitch: 0.05), screens: bigScreens) { $0.dither = 0; $0.white = SIMD4(1, 0.9, 0.62, 1) }
    let neutral = render(Scene(layout: layout, yaw: 0.1, pitch: 0.05), screens: bigScreens) { $0.dither = 0 }
    let blueDrop = zip(neutral, warm).map { $0.z - $1.z }.reduce(0, +), redDrop = zip(neutral, warm).map { $0.x - $1.x }.reduce(0, +)
    check(blueDrop > 0 && abs(redDrop) < blueDrop * 0.05, "warmth lowers blue, not red")
}
