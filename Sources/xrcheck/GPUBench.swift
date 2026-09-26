import Foundation
import Metal
import simd
import XRCore

/// GPU cost of one glasses frame (1920×1080, sRGB like the app's drawable) for each picture
/// setting, with the user's layout: `xrcheck gpubench`. Median of 60 frames each.
func gpuBench() {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
          let lib = try? device.makeLibrary(source: RendererShaders.source, options: nil) else { print("no Metal"); return }
    let pd = MTLRenderPipelineDescriptor()
    pd.vertexFunction = lib.makeFunction(name: "warpVertex")
    pd.fragmentFunction = lib.makeFunction(name: "directFragment")
    pd.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
    let pipe = try! device.makeRenderPipelineState(descriptor: pd)
    let sd = MTLSamplerDescriptor(); sd.minFilter = .linear; sd.magFilter = .linear; sd.mipFilter = .linear
    sd.maxAnisotropy = 16; sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
    let ld = MTLSamplerDescriptor(); ld.minFilter = .linear; ld.magFilter = .linear
    ld.sAddressMode = .clampToZero; ld.tAddressMode = .clampToZero
    let smp = device.makeSamplerState(descriptor: sd)!, lin = device.makeSamplerState(descriptor: ld)!

    var rng = SplitMix(seed: 3)
    func screen(w: Int, h: Int) -> MTLTexture {   // text-like: dark glyph-ish noise on light rows
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        let t = device.makeTexture(descriptor: td)!
        var px = [UInt8](repeating: 240, count: w * h * 4)
        for y in 0..<h where (y / 24) % 2 == 0 { for x in 0..<w where rng.uniform() < 0.3 {
            let i = (y * w + x) * 4; px[i] = 20; px[i + 1] = 20; px[i + 2] = 20
        } }
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: px, bytesPerRow: w * 4)
        return t
    }
    // Like the app's captures: IOSurface-backed textures are stored linearly (row by row), not in
    // the GPU's tiled layout.
    func linear(_ t: MTLTexture) -> MTLTexture {
        let bpr = (t.width * 4 + 255) / 256 * 256
        let buf = device.makeBuffer(length: bpr * t.height, options: .storageModeShared)!
        var px = [UInt8](repeating: 0, count: t.width * t.height * 4)
        t.getBytes(&px, bytesPerRow: t.width * 4, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
        for y in 0..<t.height { px.withUnsafeBytes { src in
            (buf.contents() + y * bpr).copyMemory(from: src.baseAddress! + y * t.width * 4, byteCount: t.width * 4)
        } }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: t.width, height: t.height, mipmapped: false)
        td.storageMode = .shared; td.usage = .shaderRead
        return buf.makeTexture(descriptor: td, offset: 0, bytesPerRow: bpr)!
    }
    let hi = [screen(w: 3200, h: 1800), screen(w: 3200, h: 1800)]
    let hiLinear = hi.map(linear)
    let lo = [screen(w: 1600, h: 900), screen(w: 1600, h: 900)]
    let cursor = screen(w: 16, h: 16)
    let cal = SIMD2<Float>(1920, 1080), step: Float = 8
    let mw = Int(cal.x / step) + 1, mh = Int(cal.y / step) + 1
    let map = device.makeTexture(descriptor: .texture2DDescriptor(pixelFormat: .rg32Float, width: mw, height: mh, mipmapped: false))!
    var mvals = [SIMD2<Float>](repeating: .zero, count: mw * mh)
    for j in 0..<mh { for i in 0..<mw { mvals[j * mw + i] = SIMD2(Float(i) * step, Float(j) * step) } }
    map.replace(region: MTLRegionMake2D(0, 0, mw, mh), mipmapLevel: 0, withBytes: mvals, bytesPerRow: mw * 8)
    let od = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: 1920, height: 1080, mipmapped: false)
    od.usage = [.renderTarget]; od.storageMode = .private
    let out = device.makeTexture(descriptor: od)!

    let layout = ScreenLayout(count: 2, rows: 1, widthDegrees: 33, aspect: 16.0 / 9, gapDegrees: 0.5, curve: 1)
    let panels = layout.panels.map { p in
        RendererShaders.DirectPanel(arcCenter: p.arcCenter, height: p.height, width: p.size.x, panelHeight: p.size.y,
                                    highlight: p.index == 0 ? 1 : 0, dim: 0, hasTexture: 1, hasCursor: 0, cursorRect: .zero)
    }
    // Looking at the seam between the two screens: both fill half the view.
    let view = simd_float4x4(SpatialMath.orientation(yaw: 0, pitch: 0).inverse) * simd_float4x4(layout.tiltRotation)

    func time(_ name: String, screens: [MTLTexture], _ configure: (inout RendererShaders.DirectUniforms) -> Void) {
        var u = RendererShaders.DirectUniforms(
            invView: view.inverse, focal: SIMD2(2697, 2711), center: SIMD2(960, 547),
            toCalibrated: SIMD2(1, 1), mapSize: SIMD2(Float(mw), Float(mh)), mapStep: step,
            lensOn: 1, originX: 0, radius: layout.radius.isFinite ? layout.radius : 0, distance: layout.distance,
            cornerRadius: 0.018, sharpen: 0.8, quality: 2, panelCount: Float(panels.count),
            subpixel: 1, subpixelStrength: 1, frame: 0, motion: 0, dither: 1)
        configure(&u)
        var gp = panels
        var ms: [Double] = []
        for f in 0..<70 {
            u.frame = Float(f)
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = out; rp.colorAttachments[0].loadAction = .dontCare; rp.colorAttachments[0].storeAction = .store
            let cb = queue.makeCommandBuffer()!, enc = cb.makeRenderCommandEncoder(descriptor: rp)!
            enc.setRenderPipelineState(pipe)
            enc.setFragmentSamplerState(smp, index: 0); enc.setFragmentSamplerState(lin, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<RendererShaders.DirectUniforms>.stride, index: 0)
            enc.setFragmentBytes(&gp, length: MemoryLayout<RendererShaders.DirectPanel>.stride * gp.count, index: 1)
            enc.setFragmentTexture(map, index: 0); enc.setFragmentTexture(cursor, index: 1)
            for i in 0..<8 { enc.setFragmentTexture(screens[i % screens.count], index: 2 + i) }
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
            if f >= 10 { ms.append((cb.gpuEndTime - cb.gpuStartTime) * 1000) }
        }
        ms.sort()
        print(String(format: "  %-52@ %5.2f ms median, %5.2f p90", name as NSString, ms[ms.count / 2], ms[ms.count * 9 / 10]))
    }
    print("GPU per glasses frame, 2 screens, 33°, curve 1 (your layout):")
    time("HiDPI LINEAR (like captures), yours, still", screens: hiLinear) { _ in }
    time("HiDPI LINEAR, yours, turning", screens: hiLinear) { $0.motion = 1 }
    time("HiDPI LINEAR, yours, easing", screens: hiLinear) { $0.motion = 0.5 }
    time("HiDPI LINEAR, quality 1, still", screens: hiLinear) { $0.quality = 1; $0.subpixel = 0 }
    time("HiDPI, subpixel + sharpen 0.8 (yours), still", screens: hi) { _ in }
    time("HiDPI, yours, turning (motion 1)", screens: hi) { $0.motion = 1 }
    time("HiDPI, yours, easing (motion 0.5)", screens: hi) { $0.motion = 0.5 }
    time("HiDPI, no subpixel, sharpen 0.8, still", screens: hi) { $0.subpixel = 0 }
    time("HiDPI, no subpixel, no sharpen, still", screens: hi) { $0.subpixel = 0; $0.sharpen = 0 }
    time("HiDPI, subpixel, no sharpen, still", screens: hi) { $0.sharpen = 0 }
    time("HiDPI, yours, no dither", screens: hi) { $0.dither = 0 }
    time("HiDPI, quality 1 (hardware filter), still", screens: hi) { $0.quality = 1; $0.subpixel = 0 }
    time("HiDPI, quality 1, turning", screens: hi) { $0.quality = 1; $0.subpixel = 0; $0.motion = 1 }
    time("1x, yours, still", screens: lo) { _ in }
    time("1x, yours, turning", screens: lo) { $0.motion = 1 }
    time("lens off (cost of the lens map), yours", screens: hi) { $0.lensOn = 0 }
}
