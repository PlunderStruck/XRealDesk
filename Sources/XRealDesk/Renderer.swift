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
    private let sampler: MTLSamplerState
    private let linearSampler: MTLSamplerState
    private var eyeTextures: [MTLTexture?] = [nil, nil]
    /// The same eye images read without sRGB decoding, so the final shrink blends in gamma space.
    private var eyeGammaViews: [MTLTexture?] = [nil, nil]
    private var cursorTexture: MTLTexture?
    private var mapTextures: [MTLTexture?] = [nil, nil, nil]   // average, left, right
    private var mapInfo = (w: 1, h: 1, step: Float(8))
    private let gpuLock = OSAllocatedUnfairLock(initialState: (sum: 0.0, max: 0.0, n: 0))
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
        guard let image else { cursorTexture = nil; return }
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info) else { return }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: w, height: h, mipmapped: true)
        td.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: td), let cb = queue.makeCommandBuffer(),
              let blit = cb.makeBlitCommandEncoder() else { return }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: bytes, bytesPerRow: w * 4)
        blit.generateMipmaps(for: tex)
        blit.endEncoding()
        cb.commit()
        cursorTexture = tex
    }

    /// Average / worst GPU time per frame since the last call (ms).
    func takeGPUTimes() -> (avg: Double, max: Double) {
        gpuLock.withLock { g in
            defer { g = (0, 0, 0) }
            return (g.n > 0 ? g.sum / Double(g.n) : 0, g.max)
        }
    }

    func forget(index: Int) { mipTextures[index] = nil }
    func forgetAll() { mipTextures.removeAll() }

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
        guard !eyes.isEmpty, eyes.count <= 2, inFlight.wait(timeout: .now() + .milliseconds(8)) == .success else {
            stats.skippedBusy += 1
            return false
        }
        guard let cb = queue.makeCommandBuffer() else {
            inFlight.signal()
            return false
        }
        stats.rendered += 1
        cb.label = "XRealDesk frame"

        // 1. Refresh mip chains for screens that produced new frames.
        var retained: [DisplayCapture.Frame] = []
        let fresh = panels.compactMap { p -> (Int, DisplayCapture.Frame)? in
            guard let f = p.frame, mipTextures[p.index]?.seq != f.seq else { return nil }
            return (p.index, f)
        }
        if !fresh.isEmpty, let blit = cb.makeBlitCommandEncoder() {
            for (index, frame) in fresh {
                let src = frame.texture
                var dst = mipTextures[index]?.texture
                if dst == nil || dst!.width != src.width || dst!.height != src.height {
                    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: src.width,
                                                                      height: src.height, mipmapped: true)
                    td.storageMode = .private
                    td.usage = [.shaderRead]
                    dst = device.makeTexture(descriptor: td)
                }
                guard let dst else { continue }
                blit.copy(from: src, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                          sourceSize: MTLSize(width: src.width, height: src.height, depth: 1),
                          to: dst, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
                blit.generateMipmaps(for: dst)
                mipTextures[index] = (dst, frame.seq)
                retained.append(frame)
            }
            blit.endEncoding()
        }

        // 2. Per eye: panels → supersampled ideal image (with margin), over black (transparent on the optics).
        let full = SIMD2<Float>(Float(drawable.texture.width), Float(drawable.texture.height))
        let out = SIMD2<Float>(full.x / Float(eyes.count), full.y)   // each eye's share of the output
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
            encodePanels(cb, target: eye, viewProj: viewProj, layout: layout, panels: panels, style: style, pixelScale: ss)
            let map = mapTextures[min(max(e.map, 0), 2)] ?? mapTextures[0]
            warps.append((eyeGamma, map, WarpUniforms(outputSize: out, toCalibrated: e.intrinsics.calibrated / out,
                                                 mapStep: mapInfo.step, margin: m,
                                                 mapSize: SIMD2(Float(mapInfo.w), Float(mapInfo.h)), eyeSize: eyeSize,
                                                 lensOn: (style.lensCorrection && map != nil) ? 1 : 0,
                                                 originX: out.x * Float(i), filter: style.sharpDownsample ? 1 : 0,
                                                 kernelWidth: min(max(0.75 * Float(eyePx.x) / eyeSize.x, 1), 1.5))))
        }

        // 3. Ideal images → glasses, each through its lens map, into its part of the output.
        encodeWarp(cb, target: drawable.texture, warps: warps)

        // Optional: the same frame into a readable texture, saved as PNG (diagnostics).
        if let snapshotURL {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: drawable.texture.width,
                                                              height: drawable.texture.height, mipmapped: false)
            td.usage = [.renderTarget]
            td.storageMode = .shared
            if let snapshot = device.makeTexture(descriptor: td) {
                encodeWarp(cb, target: snapshot, warps: warps)
                cb.addCompletedHandler { _ in Renderer.writePNG(snapshot, to: snapshotURL) }
            }
        }
        cb.present(drawable)
        let sem = inFlight
        let gpu = gpuLock
        cb.addCompletedHandler { cb in
            _ = retained   // keep captured IOSurfaces alive until the GPU copy finished
            let ms = (cb.gpuEndTime - cb.gpuStartTime) * 1000
            if ms > 0 && ms < 1000 { gpu.withLock { $0.sum += ms; $0.max = max($0.max, ms); $0.n += 1 } }
            sem.signal()
        }
        cb.commit()
        return true
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

    private func encodePanels(_ cb: MTLCommandBuffer, target: MTLTexture, viewProj: simd_float4x4,
                              layout: ScreenLayout, panels: [PanelDraw], style: Style, pixelScale: Float) {
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
            let tex = mipTextures[p.index]?.texture
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
    """
}
