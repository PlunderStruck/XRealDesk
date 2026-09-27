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
        /// Subpixel rendering: 0 off, 1 RGB left→right, 2 BGR, 3 RGB top→bottom, 4 BGR top→bottom.
        var subpixel = 0
        /// 0 = soft (blended with neighbouring subpixels, fewer fringes) … 1 = each channel samples
        /// exactly its own subpixel (sharpest, most color at edges).
        var subpixelStrength: Float = 0.5
        /// White-point multipliers (linear light) from the Warmth setting.
        var white = SIMD3<Float>(1, 1, 1)
        /// Rolling scan-out compensation: 0 off, +1 the display lights rows top to bottom, -1 bottom to top.
        var scanDirection: Float = 0
        /// Temporal dithering before the 8-bit output: no banding in dark gradients.
        var dither = true
        /// Blend from the sharpest filters to the calmest while the picture moves (no edge crawl).
        var motionAdaptive = true
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
    private var motion: Float = 0          // 0 still … 1 moving (render thread)
    private var scanRotation = SIMD3<Float>(repeating: 0)   // eye-frame head rotation over one scan-out
    private var frameIndex: UInt32 = 0
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
            let lib = try device.makeLibrary(source: RendererShaders.source, options: nil)
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
                panels: [PanelDraw], style: Style, motion: Float = 0, scan: SIMD3<Float> = .zero,
                snapshotTo snapshotURL: URL? = nil) -> Bool {
        self.motion = min(max(motion, 0), 1)
        let scanOK = scan.x.isFinite && scan.y.isFinite && scan.z.isFinite && simd_length(scan) < 0.1
        self.scanRotation = scanOK ? scan : .zero
        frameIndex &+= 1
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

    /// Single pass: every glasses pixel → lens map → ray → curved screen wall → one filtered sample.
    private func encodeDirect(_ cb: MTLCommandBuffer, target: MTLTexture, size: SIMD2<Float>, eyes: [EyeView],
                              layout: ScreenLayout, panels: [PanelDraw], textures: [Int: MTLTexture], style: Style) {
        let out = SIMD2<Float>(size.x / Float(eyes.count), size.y)
        let slots = Array(panels.prefix(8))
        var gpuPanels = slots.map { p in
            RendererShaders.DirectPanel(arcCenter: p.panel.arcCenter, height: p.panel.height, width: p.panel.size.x, panelHeight: p.panel.size.y,
                        highlight: p.highlight, dim: p.dim, hasTexture: textures[p.index] == nil ? 0 : 1,
                        hasCursor: p.cursorRect == nil || cursorGammaTexture == nil ? 0 : 1, cursorRect: p.cursorRect ?? .zero)
        }
        if gpuPanels.isEmpty { gpuPanels.append(RendererShaders.DirectPanel(arcCenter: 0, height: 0, width: 1, panelHeight: 1, highlight: 0, dim: 0,
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
        enc.setFragmentBytes(&gpuPanels, length: MemoryLayout<RendererShaders.DirectPanel>.stride * gpuPanels.count, index: 1)
        enc.setFragmentTexture(cursorGammaTexture ?? dummyTexture, index: 1)
        for i in 0..<8 {
            let t = i < slots.count ? textures[slots[i].index] : nil
            enc.setFragmentTexture(t ?? dummyTexture, index: 2 + i)
        }
        let radius = layout.radius.isFinite ? layout.radius : 0
        for (i, e) in eyes.enumerated() {
            let map = mapTextures[min(max(e.map, 0), 2)] ?? mapTextures[0]
            var u = RendererShaders.DirectUniforms(invView: (e.view * simd_float4x4(layout.tiltRotation)).inverse,
                                   focal: e.intrinsics.focal, center: e.intrinsics.center,
                                   toCalibrated: e.intrinsics.calibrated / out,
                                   mapSize: SIMD2(Float(mapInfo.w), Float(mapInfo.h)), mapStep: mapInfo.step,
                                   lensOn: (style.lensCorrection && map != nil) ? 1 : 0, originX: out.x * Float(i),
                                   radius: radius, distance: layout.distance, cornerRadius: style.cornerRadius,
                                   sharpen: style.sharpen, quality: style.supersample, panelCount: Float(slots.count),
                                   subpixel: Float(style.subpixel), subpixelStrength: style.subpixelStrength,
                                   frame: Float(frameIndex % 64), motion: style.motionAdaptive ? motion : 0,
                                   dither: style.dither ? 1 : 0,
                                   white: SIMD4(style.white, 1))
            if style.scanDirection != 0 {
                u.scanRows = e.intrinsics.calibrated.y
                u.scanDir = style.scanDirection
                u.scan = SIMD4(scanRotation, 0)
            }
            enc.setViewport(MTLViewport(originX: Double(u.originX), originY: 0, width: Double(out.x), height: Double(out.y), znear: 0, zfar: 1))
            enc.setFragmentBytes(&u, length: MemoryLayout<RendererShaders.DirectUniforms>.stride, index: 0)
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


}
