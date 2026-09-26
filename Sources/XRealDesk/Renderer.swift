import ImageIO
import Metal
import os
import QuartzCore
import simd
import XRCore

/// Draws the virtual screens as curved, textured panels, in two passes:
///  1. Panels → an offscreen, supersampled "ideal" (pinhole) image with a margin around it.
///     Each panel is a 64-segment strip bent onto the layout cylinder. Captured frames are
///     mipmapped: magnified areas use Catmull-Rom bicubic (crisp text), minified areas trilinear +
///     16x anisotropic; everything gamma-correct (sRGB). Optional clamped sharpening.
///  2. Ideal image → the glasses, warped through the glasses' factory lens-distortion map so every
///     pixel lands where the optics expect it (correct, world-locked geometry to the edges), and
///     downsampled from the supersampled image.
final class Renderer {
    struct PanelDraw {
        var index: Int
        var panel: ScreenLayout.Panel
        var frame: DisplayCapture.Frame?
        var highlight: Float
        var dim: Float
        /// Mouse cursor on this panel: (u0, v0, u1, v1) in panel UV (v top → bottom).
        var cursorRect: SIMD4<Float>? = nil
    }

    struct Style {
        var sharpen: Float = 0.35
        var cornerRadius: Float = 0.018
        /// Offscreen render scale (1 = off, 1.5, 2).
        var supersample: Float = 2
        /// Warp through the factory lens-distortion map (if the glasses provide one).
        var lensCorrection = true
        /// Shrink the supersampled image with a Catmull-Rom filter instead of one bilinear tap.
        var sharpDownsample = true
        /// Single-pass renderer: each glasses pixel is traced through the lens map onto the screens
        /// and filtered once (instead of drawing a 2x image and warping it).
        var direct = true
    }

    /// Pinhole intrinsics of the glasses' image, in `calibrated` pixel units.
    struct Intrinsics {
        var focal: SIMD2<Float>
        var center: SIMD2<Float>
        var calibrated: SIMD2<Float>
    }

    private struct WarpUniforms {
        var outputSize: SIMD2<Float>     // drawable px
        var toCalibrated: SIMD2<Float>   // drawable px → calibration px
        var mapStep: Float               // lookup map spacing (calibration px)
        var margin: Float                // eye-image margin (drawable px)
        var mapSize: SIMD2<Float>
        var eyeSize: SIMD2<Float>        // eye image size (drawable px, incl. margin)
        var lensOn: Float
        var originX: Float = 0           // this eye's left edge in the output (px)
        var filter: Float = 0            // 1 = Catmull-Rom downsample
        /// Downsample kernel scale (texels). 0.75 × the supersample factor: measured on rendered text
        /// against sub-pixel shifts, 1.5 at 2× keeps ~99% of a bilinear tap's edge sharpness with
        /// 4–5× less shimmer; wider is steadier but softer.
        var kernelWidth: Float = 1
    }

    /// One rendered view: the whole output in normal mode, or one eye's half in side-by-side 3D.
    struct EyeView {
        var intrinsics: Intrinsics
        /// Layout frame → this eye's camera.
        var view: simd_float4x4
        /// Lens map: 0 = both-eye average (normal mode), 1 = left eye, 2 = right eye.
        var map: Int
    }

    private struct Uniforms {
        var viewProj: simd_float4x4
        var arcCenter: Float
        var height: Float
        var width: Float
        var panelHeight: Float
        var radius: Float        // 0 = flat
        var distance: Float
        var cornerRadius: Float
        var highlight: Float
        var hasTexture: Float
        var dim: Float
        var sharpen: Float
        var segments: Float
        var pixelScale: Float            // eye pixels per output pixel (supersample factor)
        var mode: Float = 0              // 0 = screen panel, 1 = cursor
        var uvMin = SIMD2<Float>(0, 0)
        var uvMax = SIMD2<Float>(1, 1)
        var pad2 = SIMD2<Float>(0, 0)
    }

    static let segments = 64
    /// Extra ideal-image border (drawable px) so the distortion warp never samples outside it.
    static let margin: Float = 32

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let warpPipeline: MTLRenderPipelineState
    private let directPipeline: MTLRenderPipelineState
    private let dummyTexture: MTLTexture
    private var cursorGammaTexture: MTLTexture?
    private var mipGamma: [Int: MTLTexture] = [:]
    private let sampler: MTLSamplerState
    private let linearSampler: MTLSamplerState
    private var eyeTextures: [MTLTexture?] = [nil, nil]
    /// The same eye images read without sRGB decoding, so the final shrink blends in gamma space.
    private var eyeGammaViews: [MTLTexture?] = [nil, nil]
    private var cursorTexture: MTLTexture?
    private var mapTextures: [MTLTexture?] = [nil, nil, nil]   // average, left, right
    private var mapInfo = (w: 1, h: 1, step: Float(8))
    private let gpuLock = OSAllocatedUnfairLock(initialState: (sum: 0.0, max: 0.0, n: 0, last: 0.0))
    /// Diagnostics (render thread): how long the last frame waited for a free GPU slot (ms).
    private(set) var lastWaitMs = 0.0
    /// GPU time of the most recently completed frame (ms).
    var lastGPUMs: Double { gpuLock.withLock { $0.last } }
    private var mipTextures: [Int: (texture: MTLTexture, seq: UInt64)] = [:]
    private let inFlight = DispatchSemaphore(value: 3)

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        self.device = device
        guard let q = device.makeCommandQueue() else { return nil }
        queue = q
        do {
            let lib = try device.makeLibrary(source: Renderer.shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: "panelVertex")
            desc.fragmentFunction = lib.makeFunction(name: "panelFragment")
            let ca = desc.colorAttachments[0]!
            ca.pixelFormat = pixelFormat
            ca.isBlendingEnabled = true
            ca.sourceRGBBlendFactor = .one
            ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
            ca.sourceAlphaBlendFactor = .one
            ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
            let wd = MTLRenderPipelineDescriptor()
            wd.vertexFunction = lib.makeFunction(name: "warpVertex")
            wd.fragmentFunction = lib.makeFunction(name: "warpFragment")
            wd.colorAttachments[0].pixelFormat = pixelFormat
            warpPipeline = try device.makeRenderPipelineState(descriptor: wd)
            let dd = MTLRenderPipelineDescriptor()
            dd.vertexFunction = lib.makeFunction(name: "warpVertex")
            dd.fragmentFunction = lib.makeFunction(name: "directFragment")
            dd.colorAttachments[0].pixelFormat = pixelFormat
            directPipeline = try device.makeRenderPipelineState(descriptor: dd)
        } catch {
            Log.error("Metal pipeline: \(error)")
            return nil
        }
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.mipFilter = .linear
        sd.maxAnisotropy = 16
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        guard let s = device.makeSamplerState(descriptor: sd) else { return nil }
        sampler = s
        let ld = MTLSamplerDescriptor()
        ld.minFilter = .linear
        ld.magFilter = .linear
        ld.sAddressMode = .clampToZero
        ld.tAddressMode = .clampToZero
        guard let l = device.makeSamplerState(descriptor: ld) else { return nil }
        linearSampler = l
        let dt = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        dt.usage = [.shaderRead]
        guard let dummy = device.makeTexture(descriptor: dt) else { return nil }
        dummyTexture = dummy
    }

    /// Install the glasses' lens-distortion maps (render thread): both-eye average, left, right.
    func setDistortion(average: DistortionGrid?, left: DistortionGrid?, right: DistortionGrid?, calibrated: SIMD2<Float>) {
        let step: Float = 8
        mapTextures = [average, left, right].map { grid -> MTLTexture? in
            guard let grid else { return nil }
            let m = grid.uniformMap(width: Int(calibrated.x), height: Int(calibrated.y), step: step)
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg32Float, width: m.w, height: m.h, mipmapped: false)
            td.usage = [.shaderRead]
            guard let tex = device.makeTexture(descriptor: td) else { return nil }
            var values = m.values
            tex.replace(region: MTLRegionMake2D(0, 0, m.w, m.h), mipmapLevel: 0, withBytes: &values,
                        bytesPerRow: m.w * MemoryLayout<SIMD2<Float>>.stride)
            mapInfo = (m.w, m.h, step)
            return tex
        }
        Log.info("Lens correction maps installed: \(mapTextures.filter { $0 != nil }.count) of 3")
    }

    /// Upload the current mouse cursor image (render thread).
    func setCursorImage(_ image: CGImage?) {
        guard let image else { cursorTexture = nil; cursorGammaTexture = nil; return }
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        // The context may only use the buffer while it's pinned.
        let drawn = bytes.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: w, height: h, mipmapped: true)
        td.usage = [.shaderRead, .pixelFormatView]
        guard let tex = device.makeTexture(descriptor: td), let cb = queue.makeCommandBuffer(),
              let blit = cb.makeBlitCommandEncoder() else { return }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: bytes, bytesPerRow: w * 4)
        blit.generateMipmaps(for: tex)
        blit.endEncoding()
        cb.commit()
        cursorTexture = tex
        cursorGammaTexture = tex.makeTextureView(pixelFormat: .bgra8Unorm)
    }

    /// Average / worst GPU time per frame since the last call (ms).
    func takeGPUTimes() -> (avg: Double, max: Double) {
        gpuLock.withLock { g in
            defer { g = (0, 0, 0, g.last) }
            return (g.n > 0 ? g.sum / Double(g.n) : 0, g.max)
        }
    }

    func forget(index: Int) { mipTextures[index] = nil; mipGamma[index] = nil }
    func forgetAll() { mipTextures.removeAll(); mipGamma.removeAll() }

    /// Frame statistics since the last `takeStats()`.
    struct Stats { var rendered = 0; var skippedBusy = 0 }
    private var stats = Stats()
    func takeStats() -> Stats { defer { stats = Stats() }; return stats }

    /// Draws one frame into `drawable` (supplied by the display link). Render thread only.
    /// Returns false if the frame was skipped because the GPU is behind.
    @discardableResult
    func render(drawable: CAMetalDrawable, eyes: [EyeView], layout: ScreenLayout,
                panels: [PanelDraw], style: Style, snapshotTo snapshotURL: URL? = nil) -> Bool {
        // If the GPU falls behind, skip the frame rather than queueing latency.
        let waitStart = CACurrentMediaTime()
        let got = !eyes.isEmpty && eyes.count <= 2 && inFlight.wait(timeout: .now() + .milliseconds(8)) == .success
        lastWaitMs = (CACurrentMediaTime() - waitStart) * 1000
        guard got else {
            stats.skippedBusy += 1
            return false
        }
        guard let cb = queue.makeCommandBuffer() else {
            inFlight.signal()
            return false
        }
        stats.rendered += 1
        cb.label = "XRealDesk frame"

        let out = SIMD2<Float>(Float(drawable.texture.width) / Float(eyes.count), Float(drawable.texture.height))
        let ss = min(max(style.supersample, 1), 2)

        // 1. Screen textures. A screen drawn at about its own resolution (the usual case) is sampled
        //    straight from the captured frame. Only screens drawn clearly smaller (or at a steep
        //    angle on a flat layout) get a mipmapped copy: copying and mipmapping every new
        //    3200x1800 frame of every screen was the biggest GPU cost while content changed.
        var retained: [DisplayCapture.Frame] = []
        var textures: [Int: MTLTexture] = [:]
        var gammaTextures: [Int: MTLTexture] = [:]
        let pxPerRadian = eyes[0].intrinsics.focal.x * out.x / eyes[0].intrinsics.calibrated.x * ss
        var fresh: [(Int, DisplayCapture.Frame)] = []
        for p in panels {
            guard let f = p.frame else {
                if let t = mipTextures[p.index]?.texture { textures[p.index] = t; gammaTextures[p.index] = mipGamma[p.index] }
                continue
            }
            // Direct renderer: drawn at glasses resolution and filtered in the shader up to ~3 texels per
            // pixel. Two-pass: drawn at the supersampled resolution, mipmaps needed beyond ~1.15.
            let drawnWidth = 2 * atan(p.panel.size.x / 2 / layout.distance) * pxPerRadian / (style.direct ? ss : 1)
            if layout.curve >= 0.5, Float(f.texture.width) < drawnWidth * (style.direct ? 2.8 : 1.15) {
                textures[p.index] = f.texture
                gammaTextures[p.index] = f.gammaTexture
                retained.append(f)
            } else if mipTextures[p.index]?.seq != f.seq {
                fresh.append((p.index, f))
            } else if let t = mipTextures[p.index]?.texture {
                textures[p.index] = t
                gammaTextures[p.index] = mipGamma[p.index]
            }
        }
        if !fresh.isEmpty, let blit = cb.makeBlitCommandEncoder() {
            for (index, frame) in fresh {
                let src = frame.texture
                var dst = mipTextures[index]?.texture
                if dst == nil || dst!.width != src.width || dst!.height != src.height {
                    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: src.width,
                                                                      height: src.height, mipmapped: true)
                    td.storageMode = .private
                    td.usage = [.shaderRead, .pixelFormatView]
                    dst = device.makeTexture(descriptor: td)
                    mipGamma[index] = dst?.makeTextureView(pixelFormat: .bgra8Unorm)
                }
                guard let dst else { continue }
                blit.copy(from: src, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                          sourceSize: MTLSize(width: src.width, height: src.height, depth: 1),
                          to: dst, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
                blit.generateMipmaps(for: dst)
                mipTextures[index] = (dst, frame.seq)
                textures[index] = dst
                gammaTextures[index] = mipGamma[index]
                retained.append(frame)
            }
            blit.endEncoding()
        }

        let size = SIMD2<Float>(Float(drawable.texture.width), Float(drawable.texture.height))
        if style.direct {
            encodeDirect(cb, target: drawable.texture, size: size, eyes: eyes, layout: layout, panels: panels,
                         textures: gammaTextures, style: style)
        } else {
            encodeTwoPass(cb, target: drawable.texture, size: size, eyes: eyes, layout: layout, panels: panels,
                          textures: textures, style: style)
        }

        // Optional: the same frame into a readable texture, saved as PNG (diagnostics); with the direct
        // renderer also the two-pass result of the same frame, for comparison.
        if let snapshotURL {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: drawable.texture.width,
                                                              height: drawable.texture.height, mipmapped: false)
            td.usage = [.renderTarget]
            td.storageMode = .shared
            if let snapshot = device.makeTexture(descriptor: td) {
                if style.direct {
                    encodeDirect(cb, target: snapshot, size: size, eyes: eyes, layout: layout, panels: panels,
                                 textures: gammaTextures, style: style)
                } else {
                    encodeTwoPass(cb, target: snapshot, size: size, eyes: eyes, layout: layout, panels: panels,
                                  textures: textures, style: style)
                }
                cb.addCompletedHandler { _ in Renderer.writePNG(snapshot, to: snapshotURL) }
            }
            if style.direct, let other = device.makeTexture(descriptor: td) {
                encodeTwoPass(cb, target: other, size: size, eyes: eyes, layout: layout, panels: panels, textures: textures, style: style)
                let url = snapshotURL.deletingPathExtension().appendingPathExtension("2pass.png")
                cb.addCompletedHandler { _ in Renderer.writePNG(other, to: url) }
            }
        }
        cb.present(drawable)
        let sem = inFlight
        let gpu = gpuLock
        cb.addCompletedHandler { cb in
            _ = retained   // keep captured IOSurfaces alive until the GPU copy finished
            let ms = (cb.gpuEndTime - cb.gpuStartTime) * 1000
            if ms > 0 && ms < 1000 { gpu.withLock { $0.sum += ms; $0.max = max($0.max, ms); $0.n += 1; $0.last = ms } }
            sem.signal()
        }
        cb.commit()
        return true
    }

    /// The original renderer: panels → 2x "ideal" image per eye → lens warp + shrink.
    private func encodeTwoPass(_ cb: MTLCommandBuffer, target: MTLTexture, size: SIMD2<Float>, eyes: [EyeView],
                               layout: ScreenLayout, panels: [PanelDraw], textures: [Int: MTLTexture], style: Style) {
        // Per eye: panels → supersampled ideal image (with margin), over black (transparent on the optics).
        let out = SIMD2<Float>(size.x / Float(eyes.count), size.y)   // each eye's share of the output
        let ss = min(max(style.supersample, 1), 2)
        let m = Renderer.margin
        let eyeSize = out + 2 * m
        let eyePx = SIMD2<Int>(Int((eyeSize.x * ss).rounded()), Int((eyeSize.y * ss).rounded()))
        var warps: [(eye: MTLTexture, map: MTLTexture?, uniforms: WarpUniforms)] = []
        for (i, e) in eyes.enumerated() {
            if eyeTextures[i] == nil || eyeTextures[i]!.width != eyePx.x || eyeTextures[i]!.height != eyePx.y {
                let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: eyePx.x, height: eyePx.y, mipmapped: false)
                td.usage = [.renderTarget, .shaderRead, .pixelFormatView]
                td.storageMode = .private
                eyeTextures[i] = device.makeTexture(descriptor: td)
                eyeGammaViews[i] = eyeTextures[i]?.makeTextureView(pixelFormat: .bgra8Unorm)
            }
            guard let eye = eyeTextures[i], let eyeGamma = eyeGammaViews[i] else { continue }
            let scale = out / e.intrinsics.calibrated
            let projection = SpatialMath.projection(focal: e.intrinsics.focal * scale, center: e.intrinsics.center * scale + m,
                                                    calibrated: eyeSize, viewport: eyeSize)
            let viewProj = projection * e.view * simd_float4x4(layout.tiltRotation)
            encodePanels(cb, target: eye, viewProj: viewProj, layout: layout, panels: panels, textures: textures,
                         style: style, pixelScale: ss)
            let map = mapTextures[min(max(e.map, 0), 2)] ?? mapTextures[0]
            warps.append((eyeGamma, map, WarpUniforms(outputSize: out, toCalibrated: e.intrinsics.calibrated / out,
                                                 mapStep: mapInfo.step, margin: m,
                                                 mapSize: SIMD2(Float(mapInfo.w), Float(mapInfo.h)), eyeSize: eyeSize,
                                                 lensOn: (style.lensCorrection && map != nil) ? 1 : 0,
                                                 originX: out.x * Float(i), filter: style.sharpDownsample ? 1 : 0,
                                                 kernelWidth: min(max(0.75 * Float(eyePx.x) / eyeSize.x, 1), 1.5))))
        }

        // 3. Ideal images → glasses, each through its lens map, into its part of the output.
        encodeWarp(cb, target: target, warps: warps)

    }

    private struct DirectPanel {
        var arcCenter: Float, height: Float, width: Float, panelHeight: Float
        var highlight: Float, dim: Float, hasTexture: Float, hasCursor: Float
        var cursorRect: SIMD4<Float>
    }

    private struct DirectUniforms {
        var invView: simd_float4x4
        var focal: SIMD2<Float>, center: SIMD2<Float>
        var toCalibrated: SIMD2<Float>, mapSize: SIMD2<Float>
        var mapStep: Float, lensOn: Float, originX: Float, radius: Float
        var distance: Float, cornerRadius: Float, sharpen: Float, quality: Float
        var panelCount: Float, pad0: Float = 0, pad1: Float = 0, pad2: Float = 0
    }

    /// Single pass: every glasses pixel → lens map → ray → curved screen wall → one filtered sample.
    private func encodeDirect(_ cb: MTLCommandBuffer, target: MTLTexture, size: SIMD2<Float>, eyes: [EyeView],
                              layout: ScreenLayout, panels: [PanelDraw], textures: [Int: MTLTexture], style: Style) {
        let out = SIMD2<Float>(size.x / Float(eyes.count), size.y)
        let slots = Array(panels.prefix(8))
        var gpuPanels = slots.map { p in
            DirectPanel(arcCenter: p.panel.arcCenter, height: p.panel.height, width: p.panel.size.x, panelHeight: p.panel.size.y,
                        highlight: p.highlight, dim: p.dim, hasTexture: textures[p.index] == nil ? 0 : 1,
                        hasCursor: p.cursorRect == nil || cursorGammaTexture == nil ? 0 : 1, cursorRect: p.cursorRect ?? .zero)
        }
        if gpuPanels.isEmpty { gpuPanels.append(DirectPanel(arcCenter: 0, height: 0, width: 1, panelHeight: 1, highlight: 0, dim: 0,
                                                            hasTexture: 0, hasCursor: 0, cursorRect: .zero)) }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.setRenderPipelineState(directPipeline)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.setFragmentSamplerState(linearSampler, index: 1)
        enc.setFragmentBytes(&gpuPanels, length: MemoryLayout<DirectPanel>.stride * gpuPanels.count, index: 1)
        enc.setFragmentTexture(cursorGammaTexture ?? dummyTexture, index: 1)
        for i in 0..<8 {
            let t = i < slots.count ? textures[slots[i].index] : nil
            enc.setFragmentTexture(t ?? dummyTexture, index: 2 + i)
        }
        let radius = layout.radius.isFinite ? layout.radius : 0
        for (i, e) in eyes.enumerated() {
            let map = mapTextures[min(max(e.map, 0), 2)] ?? mapTextures[0]
            var u = DirectUniforms(invView: (e.view * simd_float4x4(layout.tiltRotation)).inverse,
                                   focal: e.intrinsics.focal, center: e.intrinsics.center,
                                   toCalibrated: e.intrinsics.calibrated / out,
                                   mapSize: SIMD2(Float(mapInfo.w), Float(mapInfo.h)), mapStep: mapInfo.step,
                                   lensOn: (style.lensCorrection && map != nil) ? 1 : 0, originX: out.x * Float(i),
                                   radius: radius, distance: layout.distance, cornerRadius: style.cornerRadius,
                                   sharpen: style.sharpen, quality: style.supersample, panelCount: Float(slots.count))
            enc.setViewport(MTLViewport(originX: Double(u.originX), originY: 0, width: Double(out.x), height: Double(out.y), znear: 0, zfar: 1))
            enc.setFragmentBytes(&u, length: MemoryLayout<DirectUniforms>.stride, index: 0)
            enc.setFragmentTexture(map ?? dummyTexture, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        enc.endEncoding()
    }

    private func encodeWarp(_ cb: MTLCommandBuffer, target: MTLTexture,
                            warps: [(eye: MTLTexture, map: MTLTexture?, uniforms: WarpUniforms)]) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.setRenderPipelineState(warpPipeline)
        enc.setFragmentSamplerState(linearSampler, index: 0)
        for w in warps {
            var u = w.uniforms
            enc.setViewport(MTLViewport(originX: Double(u.originX), originY: 0, width: Double(u.outputSize.x),
                                        height: Double(u.outputSize.y), znear: 0, zfar: 1))
            enc.setFragmentBytes(&u, length: MemoryLayout<WarpUniforms>.stride, index: 0)
            enc.setFragmentTexture(w.eye, index: 0)
            enc.setFragmentTexture(w.map, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        enc.endEncoding()
    }

    private func encodePanels(_ cb: MTLCommandBuffer, target: MTLTexture, viewProj: simd_float4x4, layout: ScreenLayout,
                              panels: [PanelDraw], textures: [Int: MTLTexture], style: Style, pixelScale: Float) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentSamplerState(sampler, index: 0)
        let radius = layout.radius.isFinite ? layout.radius : 0
        for p in panels {
            let tex = textures[p.index]
            var u = Uniforms(viewProj: viewProj, arcCenter: p.panel.arcCenter, height: p.panel.height,
                             width: p.panel.size.x, panelHeight: p.panel.size.y, radius: radius,
                             distance: layout.distance, cornerRadius: style.cornerRadius, highlight: p.highlight,
                             hasTexture: tex == nil ? 0 : 1, dim: p.dim, sharpen: style.sharpen,
                             segments: Float(Renderer.segments), pixelScale: pixelScale)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setFragmentTexture(tex, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 2 * (Renderer.segments + 1))
        }
        // Live mouse cursor on top, bent onto the same curved surface as its screen.
        if let cursorTexture, let p = panels.first(where: { $0.cursorRect != nil }), let r = p.cursorRect {
            var u = Uniforms(viewProj: viewProj, arcCenter: p.panel.arcCenter, height: p.panel.height,
                             width: p.panel.size.x, panelHeight: p.panel.size.y, radius: radius,
                             distance: layout.distance, cornerRadius: 0, highlight: 0, hasTexture: 1, dim: 0,
                             sharpen: 0, segments: 4, pixelScale: pixelScale, mode: 1,
                             uvMin: SIMD2(r.x, r.y), uvMax: SIMD2(r.z, r.w))
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setFragmentTexture(cursorTexture, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 10)
        }
        enc.endEncoding()
    }

    private static func writePNG(_ tex: MTLTexture, to url: URL) {
        let w = tex.width, h = tex.height, rowBytes = w * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * h)
        tex.getBytes(&bytes, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        Log.info("Saved snapshot to \(url.path)")
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4x4 viewProj;
        float arcCenter;
        float height;
        float width;
        float panelHeight;
        float radius;
        float distance;
        float cornerRadius;
        float highlight;
        float hasTexture;
        float dim;
        float sharpen;
        float segments;
        float pixelScale;
        float mode;
        float2 uvMin;
        float2 uvMax;
        float2 pad2;
    };

    struct VOut {
        float4 position [[position]];
        float2 uv;
    };

    // Catmull-Rom bicubic via 9 bilinear taps (level 0).
    float3 catmullRom(texture2d<float> tex, sampler s, float2 uv, float2 texSize) {
        float2 samplePos = uv * texSize;
        float2 t1 = floor(samplePos - 0.5) + 0.5;
        float2 f = samplePos - t1;
        float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
        float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
        float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
        float2 w3 = f * f * (-0.5 + 0.5 * f);
        float2 w12 = w1 + w2;
        float2 t0 = (t1 - 1.0) / texSize, t3 = (t1 + 2.0) / texSize, t12 = (t1 + w2 / w12) / texSize;
        float3 r = 0;
        r += tex.sample(s, float2(t0.x,  t0.y),  level(0)).rgb * w0.x  * w0.y;
        r += tex.sample(s, float2(t12.x, t0.y),  level(0)).rgb * w12.x * w0.y;
        r += tex.sample(s, float2(t3.x,  t0.y),  level(0)).rgb * w3.x  * w0.y;
        r += tex.sample(s, float2(t0.x,  t12.y), level(0)).rgb * w0.x  * w12.y;
        r += tex.sample(s, float2(t12.x, t12.y), level(0)).rgb * w12.x * w12.y;
        r += tex.sample(s, float2(t3.x,  t12.y), level(0)).rgb * w3.x  * w12.y;
        r += tex.sample(s, float2(t0.x,  t3.y),  level(0)).rgb * w0.x  * w3.y;
        r += tex.sample(s, float2(t12.x, t3.y),  level(0)).rgb * w12.x * w3.y;
        r += tex.sample(s, float2(t3.x,  t3.y),  level(0)).rgb * w3.x  * w3.y;
        return clamp(r, 0.0, 1.0);
    }

    float crWeight(float x) {
        x = abs(x);
        if (x < 1.0) return (1.5 * x - 2.5) * x * x + 1.0;
        if (x < 2.0) return ((-0.5 * x + 2.5) * x - 4.0) * x + 2.0;
        return 0.0;
    }

    // Shrink the supersampled eye image onto one output pixel with a Catmull-Rom kernel (`scale`
    // texels per kernel unit, ≤ 1.5, so 6x6 texels cover it). A single bilinear tap's result depends
    // on where it lands between texels, and that phase drifts as the head moves: text shimmers.
    // Clamped to the range of the texels within one kernel unit, so edges get no halos. Reads are
    // gamma-encoded (see warpFragment). Fixed size and unrolled: 3x faster than a dynamic loop.
    float3 downsample(texture2d<float> eye, float2 uv, float scale) {
        float2 size = float2(eye.get_width(), eye.get_height());
        float2 p = uv * size - 0.5;
        float2 base = floor(p);
        float2 f = p - base;
        float wx[6], wy[6];
        #pragma unroll
        for (int k = 0; k < 6; k++) { wx[k] = crWeight((float(k - 2) - f.x) / scale); wy[k] = crWeight((float(k - 2) - f.y) / scale); }
        int2 b = int2(base) - 2, hiIdx = int2(size) - 1;
        float3 acc = 0.0, lo = 1.0, hi = 0.0;
        #pragma unroll
        for (int j = 0; j < 6; j++) {
            int ty = clamp(b.y + j, 0, hiIdx.y);
            float3 row = 0.0;
            #pragma unroll
            for (int i = 0; i < 6; i++) {
                float3 c = eye.read(uint2(clamp(b.x + i, 0, hiIdx.x), ty)).rgb;
                row += c * wx[i];
                if (i >= 1 && i <= 4 && j >= 1 && j <= 4 && abs(float(i - 2) - f.x) <= scale && abs(float(j - 2) - f.y) <= scale) { lo = min(lo, c); hi = max(hi, c); }
            }
            acc += row * wy[j];
        }
        float sx = 0.0, sy = 0.0;
        for (int k = 0; k < 6; k++) { sx += wx[k]; sy += wy[k]; }
        return clamp(acc / max(sx * sy, 1e-4), lo, hi);
    }

    // --- Final pass: ideal image → glasses, through the lens-distortion map.
    struct WarpUniforms {
        float2 outputSize;
        float2 toCalibrated;
        float mapStep;
        float margin;
        float2 mapSize;
        float2 eyeSize;
        float lensOn;
        float originX;
        float filter;
        float kernelWidth;
    };

    struct WOut { float4 position [[position]]; };

    vertex WOut warpVertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);   // full-screen triangle
        WOut o;
        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        return o;
    }

    fragment float4 warpFragment(WOut in [[stage_in]], constant WarpUniforms& w [[buffer(0)]],
                                 texture2d<float> eye [[texture(0)]], texture2d<float> map [[texture(1)]],
                                 sampler s [[sampler(0)]]) {
        float2 p = in.position.xy - float2(w.originX, 0.0);   // pixel centre within this eye's image
        float2 ideal = p;
        if (w.lensOn > 0.5) {
            float2 pc = p * w.toCalibrated;              // calibration px
            float2 muv = (pc / w.mapStep + 0.5) / w.mapSize;
            ideal = map.sample(s, muv).xy / w.toCalibrated;
        }
        float2 uv = (ideal + w.margin) / w.eyeSize;
        // `eye` is read gamma-encoded: shrinking in gamma space keeps text as heavy as it is on a
        // real screen. In linear light, light-on-dark text came out ~5% heavier (a glow) and
        // dark-on-light ~9% thinner (measured against the same text drawn natively at 1x).
        float3 c = w.filter < 0.5 ? eye.sample(s, uv).rgb : downsample(eye, uv, w.kernelWidth);
        return float4(select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045), 1.0);
    }

    // Strip of `segments` columns bent onto the layout cylinder.
    vertex VOut panelVertex(uint vid [[vertex_id]], constant Uniforms& u [[buffer(0)]]) {
        float col = float(vid >> 1);
        bool top = (vid & 1) == 1;
        float uLocal = col / u.segments;
        float vLocal = top ? 0.0 : 1.0;
        float uCoord = mix(u.uvMin.x, u.uvMax.x, uLocal);
        float vCoord = mix(u.uvMin.y, u.uvMax.y, vLocal);
        float s = u.arcCenter + (uCoord - 0.5) * u.width;
        float y = u.height + (0.5 - vCoord) * u.panelHeight;
        float3 p;
        if (u.radius > 0.0) {
            float theta = s / u.radius;
            p = float3(u.radius * sin(theta), y, (u.radius - u.distance) - u.radius * cos(theta));
        } else {
            p = float3(s, y, -u.distance);
        }
        VOut o;
        o.position = u.viewProj * float4(p, 1.0);
        o.uv = u.mode > 0.5 ? float2(uLocal, vLocal) : float2(uCoord, vCoord);
        return o;
    }

    fragment float4 panelFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                                  texture2d<float> tex [[texture(0)]], sampler smp [[sampler(0)]]) {
        if (u.mode > 0.5) {
            return tex.sample(smp, in.uv);   // cursor: premultiplied RGBA
        }
        // Rounded-rectangle mask in panel units (height = 1).
        float aspect = u.width / u.panelHeight;
        float2 size = float2(aspect, 1.0);
        float2 p = (in.uv - 0.5) * size;
        float2 q = abs(p) - (size * 0.5 - u.cornerRadius);
        float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - u.cornerRadius;
        float aa = max(fwidth(d), 1e-5);
        float alpha = 1.0 - smoothstep(-aa, aa, d);
        if (alpha <= 0.0) discard_fragment();

        float3 color;
        if (u.hasTexture > 0.5) {
            // Footprint of one output pixel on the screen texture (texels). < 1 = magnified.
            float2 texSize = float2(tex.get_width(), tex.get_height());
            float2 dxT = dfdx(in.uv) * texSize, dyT = dfdy(in.uv) * texSize;
            float footprint = max(length(dxT), length(dyT)) * u.pixelScale;
            float3 c = tex.sample(smp, in.uv).rgb;
            if (footprint < 1.2) {
                // Magnified / ~1:1: Catmull-Rom bicubic keeps text edges crisp between pixels.
                float3 bc = catmullRom(tex, smp, in.uv, texSize);
                c = mix(bc, c, smoothstep(0.9, 1.2, footprint));
            }
            if (u.sharpen > 0.001) {
                // Unsharp mask sized to one output pixel's footprint on the texture.
                float2 dx = dfdx(in.uv) * u.pixelScale, dy = dfdy(in.uv) * u.pixelScale;
                float3 n = tex.sample(smp, in.uv + dy).rgb;
                float3 so = tex.sample(smp, in.uv - dy).rgb;
                float3 e = tex.sample(smp, in.uv + dx).rgb;
                float3 w = tex.sample(smp, in.uv - dx).rgb;
                float3 blur = (n + so + e + w) * 0.25;
                float3 mn = min(c, min(min(n, so), min(e, w)));
                float3 mx = max(c, max(max(n, so), max(e, w)));
                c = clamp(c + (c - blur) * (u.sharpen * 1.6), mn, mx);   // clamped: no halos
            }
            color = c;
        } else {
            // Placeholder while the screen is starting: dim panel with a subtle grid.
            float2 g = abs(fract(in.uv * float2(16.0, 9.0)) - 0.5);
            float line = 1.0 - smoothstep(0.46, 0.5, max(g.x, g.y));
            color = mix(float3(0.10, 0.11, 0.13), float3(0.05, 0.055, 0.065), line);
        }
        color *= (1.0 - u.dim);

        // Accent ring on the screen that has the cursor.
        // ~1.5 px at typical sizes, independent of panel resolution (aa is one pixel in panel units).
        float bw = 1.5 * aa * u.pixelScale;
        float ring = smoothstep(-bw - aa, -bw, d);
        color = mix(color, float3(0.30, 0.62, 1.0), ring * u.highlight * 0.85);

        return float4(color * alpha, alpha);
    }

    // --- Direct renderer: glasses pixel → lens map → ray → curved screen wall → one filtered sample.
    struct DPanel { float arcCenter; float height; float width; float panelHeight;
                    float highlight; float dim; float hasTexture; float hasCursor; float4 cursorRect; };
    struct DUniforms {
        float4x4 invView;
        float2 focal; float2 center;
        float2 toCalibrated; float2 mapSize;
        float mapStep; float lensOn; float originX; float radius;
        float distance; float cornerRadius; float sharpen; float quality;
        float panelCount; float pad0; float pad1; float pad2;
    };

    // Eye-local output pixel → point on the layout surface: (arc length, height). false = no hit.
    bool surfaceAt(float2 px, constant DUniforms& u, texture2d<float> map, sampler lin, thread float2& sy) {
        float2 pc = px * u.toCalibrated;
        float2 ideal = pc;
        if (u.lensOn > 0.5) ideal = map.sample(lin, (pc / u.mapStep + 0.5) / u.mapSize).xy;
        float3 dcam = float3((ideal.x - u.center.x) / u.focal.x, (u.center.y - ideal.y) / u.focal.y, -1.0);
        float3 o = (u.invView * float4(0.0, 0.0, 0.0, 1.0)).xyz;
        float3 d = normalize((u.invView * float4(dcam, 0.0)).xyz);
        if (u.radius > 0.0) {
            float c = u.radius - u.distance;          // cylinder axis: x = 0, z = c
            float oz = o.z - c;
            float a = d.x * d.x + d.z * d.z;
            float b = 2.0 * (o.x * d.x + oz * d.z);
            float cc = o.x * o.x + oz * oz - u.radius * u.radius;
            float disc = b * b - 4.0 * a * cc;
            if (disc < 0.0 || a < 1e-8) return false;
            float t = (-b + sqrt(disc)) / (2.0 * a);
            if (t <= 0.0) return false;
            float3 p = o + t * d;
            sy = float2(atan2(p.x, c - p.z) * u.radius, p.y);
        } else {
            if (d.z > -1e-5) return false;
            float t = (-u.distance - o.z) / d.z;
            sy = (o + t * d).xy;
        }
        return true;
    }

    float2 panelUV(DPanel p, float2 sy) {
        return float2((sy.x - p.arcCenter) / p.width + 0.5, 0.5 - (sy.y - p.height) / p.panelHeight);
    }

    // Catmull-Rom shrink, kernel `scale` texels per unit (1..1.5): 6x6 texels, clamped to the texels
    // within one unit (no halos).
    float3 crShrink(texture2d<float> tex, float2 uv, float scale) {
        float2 size = float2(tex.get_width(), tex.get_height());
        float2 p = uv * size - 0.5;
        float2 base = floor(p);
        float2 f = p - base;
        float wx[6], wy[6];
        for (int k = 0; k < 6; k++) { wx[k] = crWeight((float(k - 2) - f.x) / scale); wy[k] = crWeight((float(k - 2) - f.y) / scale); }
        int2 b = int2(base) - 2, hiIdx = int2(size) - 1;
        float3 acc = 0.0, lo = 1.0, hi = 0.0;
        for (int j = 0; j < 6; j++) {
            int ty = clamp(b.y + j, 0, hiIdx.y);
            float3 row = 0.0;
            for (int i = 0; i < 6; i++) {
                float3 c = tex.read(uint2(clamp(b.x + i, 0, hiIdx.x), ty)).rgb;
                row += c * wx[i];
                if (i >= 1 && i <= 4 && j >= 1 && j <= 4 && abs(float(i - 2) - f.x) <= scale && abs(float(j - 2) - f.y) <= scale) {
                    lo = min(lo, c); hi = max(hi, c);
                }
            }
            acc += row * wy[j];
        }
        float sx = 0.0, sy = 0.0;
        for (int k = 0; k < 6; k++) { sx += wx[k]; sy += wy[k]; }
        return clamp(acc / max(sx * sy, 1e-4), lo, hi);
    }

    // One screen sample, filtered for how many texels this pixel covers (gamma-space values).
    float3 shadeScreen(texture2d<float> tex, sampler smp, float2 uv, float2 duvx, float2 duvy, float sharpen, float quality) {
        float2 texSize = float2(tex.get_width(), tex.get_height());
        float footprint = max(length(duvx * texSize), length(duvy * texSize));
        float3 c;
        if (quality < 1.25) {
            c = tex.sample(smp, uv, gradient2d(duvx, duvy)).rgb;
        } else if (footprint < 1.2) {
            float3 bc = catmullRom(tex, smp, uv, texSize);
            float3 bl = tex.sample(smp, uv, level(0)).rgb;
            c = mix(bc, bl, smoothstep(0.9, 1.2, footprint));
        } else if (footprint < 3.2) {
            c = crShrink(tex, uv, clamp(footprint * 0.75, 1.0, 1.5));
        } else {
            c = tex.sample(smp, uv, gradient2d(duvx, duvy)).rgb;
        }
        if (sharpen > 0.001 && footprint < 3.2) {
            float3 n = tex.sample(smp, uv + duvy, level(0)).rgb;
            float3 so = tex.sample(smp, uv - duvy, level(0)).rgb;
            float3 e = tex.sample(smp, uv + duvx, level(0)).rgb;
            float3 w = tex.sample(smp, uv - duvx, level(0)).rgb;
            float3 blur = (n + so + e + w) * 0.25;
            float3 mn = min(c, min(min(n, so), min(e, w)));
            float3 mx = max(c, max(max(n, so), max(e, w)));
            c = clamp(c + (c - blur) * (sharpen * 1.6), mn, mx);
        }
        return c;
    }

    float3 toLinear(float3 c) { return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045); }

    fragment float4 directFragment(WOut in [[stage_in]], constant DUniforms& u [[buffer(0)]], constant DPanel* panels [[buffer(1)]],
                                   texture2d<float> map [[texture(0)]], texture2d<float> cursor [[texture(1)]],
                                   array<texture2d<float>, 8> screens [[texture(2)]],
                                   sampler smp [[sampler(0)]], sampler lin [[sampler(1)]]) {
        float2 px = in.position.xy - float2(u.originX, 0.0);
        float2 sy, syx, syy;
        if (!surfaceAt(px, u, map, lin, sy)) return float4(0.0, 0.0, 0.0, 1.0);
        bool hx = surfaceAt(px + float2(1.0, 0.0), u, map, lin, syx);
        bool hy = surfaceAt(px + float2(0.0, 1.0), u, map, lin, syy);
        int n = min(int(u.panelCount), 8);
        for (int i = 0; i < n; i++) {
            DPanel p = panels[i];
            float2 uv = panelUV(p, sy);
            if (uv.x < -0.02 || uv.y < -0.02 || uv.x > 1.02 || uv.y > 1.02) continue;
            float2 duvx = hx ? panelUV(p, syx) - uv : float2(0.0);
            float2 duvy = hy ? panelUV(p, syy) - uv : float2(0.0);
            // Rounded-rectangle mask in panel units (height = 1), antialiased over one pixel.
            float2 size = float2(p.width / p.panelHeight, 1.0);
            float2 q = abs((uv - 0.5) * size) - (size * 0.5 - u.cornerRadius);
            float dist = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - u.cornerRadius;
            float aa = max(max(length(duvx * size), length(duvy * size)), 1e-5);
            float alpha = 1.0 - smoothstep(-0.5 * aa, 0.5 * aa, dist);
            if (alpha <= 0.0) continue;
            float3 color;
            if (p.hasTexture > 0.5) {
                color = shadeScreen(screens[i], smp, clamp(uv, 0.0, 1.0), duvx, duvy, u.sharpen, u.quality);
            } else {
                float2 g = abs(fract(uv * float2(16.0, 9.0)) - 0.5);
                float line = 1.0 - smoothstep(0.46, 0.5, max(g.x, g.y));
                color = mix(float3(0.35, 0.37, 0.40), float3(0.25, 0.26, 0.28), line);   // gamma values of the old placeholder
            }
            if (p.hasCursor > 0.5) {
                float2 rs = p.cursorRect.zw - p.cursorRect.xy;
                float2 cuv = (uv - p.cursorRect.xy) / rs;
                if (all(cuv >= 0.0) && all(cuv <= 1.0)) {
                    float4 cc = cursor.sample(smp, cuv, gradient2d(duvx / rs, duvy / rs));   // premultiplied
                    color = cc.rgb + color * (1.0 - cc.a);
                }
            }
            // Dimming and the accent ring in linear light, exactly like the two-pass renderer
            // (dimming in gamma space came out far darker at the same setting).
            float3 lin = toLinear(color) * (1.0 - p.dim);
            float ring = smoothstep(-2.5 * aa, -1.5 * aa, dist);   // ~1.5 px, on the screen with the cursor
            lin = mix(lin, float3(0.30, 0.62, 1.0), ring * p.highlight * 0.85);
            return float4(lin * alpha, 1.0);
        }
        return float4(0.0, 0.0, 0.0, 1.0);
    }
    """
}
