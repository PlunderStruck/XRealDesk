import AppKit
import CoreMedia
import CoreVideo
import Metal
import os
import ScreenCaptureKit

/// Streams one display into Metal textures with ScreenCaptureKit (IOSurface-backed, zero-copy).
/// Restarts itself if macOS stops the stream (sleep, display reconfiguration, permission hiccup).
final class DisplayCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    final class Frame: @unchecked Sendable {
        let texture: MTLTexture
        /// The same pixels read without sRGB decoding (filtering in gamma space keeps text weight).
        let gammaTexture: MTLTexture
        let seq: UInt64
        /// When the frame reached us (CACurrentMediaTime).
        let arrival: CFTimeInterval
        // Keep the CoreVideo objects alive for as long as the texture is used.
        private let cvTextures: [CVMetalTexture]
        private let pixelBuffer: CVPixelBuffer
        init(texture: MTLTexture, gammaTexture: MTLTexture, cvTextures: [CVMetalTexture], pixelBuffer: CVPixelBuffer,
             seq: UInt64, arrival: CFTimeInterval) {
            self.texture = texture; self.gammaTexture = gammaTexture; self.cvTextures = cvTextures
            self.pixelBuffer = pixelBuffer; self.seq = seq; self.arrival = arrival
        }
    }

    enum Status: Equatable { case starting, running, failed(String), stopped }

    let displayID: CGDirectDisplayID
    let index: Int
    private let refreshRate: Int
    private let queue: DispatchQueue
    private var textureCache: CVMetalTextureCache?
    private let frameLock = OSAllocatedUnfairLock<Frame?>(initialState: nil)
    private let statusLock = OSAllocatedUnfairLock<Status>(initialState: .starting)
    private var seq: UInt64 = 0   // sample-handler queue only

    /// Start/stop state is touched from the main thread (start/stop), Swift tasks (startStream) and
    /// ScreenCaptureKit's delegate queue (didStopWithError), so it lives behind a lock. `generation`
    /// changes on every start/stop, so a stale task can never resurrect a stopped capture.
    private struct Control {
        var stream: SCStream?
        var wantRunning = false
        var generation = 0
        var restartCount = 0
    }
    private let control = OSAllocatedUnfairLock<Control>(initialState: Control())

    private func isCurrent(_ generation: Int) -> Bool {
        control.withLock { $0.wantRunning && $0.generation == generation }
    }

    var latestFrame: Frame? { frameLock.withLock { $0 } }

    /// Capture diagnostics: new frames, how old they were on arrival (since macOS composed them),
    /// and the largest gap between frames.
    struct Stats { var frames = 0; var latencySum = 0.0; var latencyMax = 0.0; var gapMax = 0.0 }
    private let statsLock = OSAllocatedUnfairLock(initialState: Stats())
    private var lastArrival: CFTimeInterval = 0   // sample-handler queue only
    func takeStats() -> Stats { statsLock.withLock { s in defer { s = Stats() }; return s } }
    var status: Status { statusLock.withLock { $0 } }

    init(displayID: CGDirectDisplayID, index: Int, device: MTLDevice, refreshRate: Int) {
        self.displayID = displayID
        self.index = index
        self.refreshRate = refreshRate
        self.queue = DispatchQueue(label: "XRealDesk.capture.\(index)", qos: .userInteractive)
        super.init()
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    func start() {
        let gen = control.withLock { c -> Int in
            c.wantRunning = true
            c.generation += 1
            c.restartCount = 0
            return c.generation
        }
        Task { await self.startStream(generation: gen, attempt: 0) }
    }

    func stop() {
        let s = control.withLock { c -> SCStream? in
            c.wantRunning = false
            c.generation += 1
            defer { c.stream = nil }
            return c.stream
        }
        statusLock.withLock { $0 = .stopped }
        Task { try? await s?.stopCapture() }
    }

    private func startStream(generation gen: Int, attempt: Int) async {
        guard isCurrent(gen) else { return }
        statusLock.withLock { $0 = .starting }
        do {
            // A freshly created virtual display takes a moment to show up in shareable content.
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard isCurrent(gen) else { return }
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                if attempt < 40 {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    await startStream(generation: gen, attempt: attempt + 1)
                } else {
                    fail("Display \(displayID) never became capturable")
                }
                return
            }
            let pixel = VirtualDisplayManager.pixelSize(of: displayID) ?? CGSize(width: display.width, height: display.height)
            let cfg = SCStreamConfiguration()
            cfg.width = Int(pixel.width)
            cfg.height = Int(pixel.height)
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(30, refreshRate)))
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            cfg.colorSpaceName = CGColorSpace.sRGB
            cfg.queueDepth = 5
            cfg.showsCursor = false   // the cursor is drawn live at 120 Hz by the renderer instead
            cfg.capturesAudio = false
            cfg.scalesToFit = false

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let s = SCStream(filter: filter, configuration: cfg, delegate: self)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await s.startCapture()
            // Publish the stream only if nobody stopped/restarted us meanwhile.
            let installed = control.withLock { c -> Bool in
                guard c.wantRunning && c.generation == gen else { return false }
                c.stream = s
                return true
            }
            guard installed else { try? await s.stopCapture(); return }
            statusLock.withLock { $0 = .running }
            Log.info("Capturing screen \(index + 1) (display \(displayID)) at \(Int(pixel.width))x\(Int(pixel.height))")
        } catch {
            let ns = error as NSError
            Log.error("Capture start failed for screen \(index + 1): \(ns.domain) \(ns.code) \(ns.localizedDescription)")
            if !CGPreflightScreenCaptureAccess() {
                fail("Screen Recording permission is needed")
                return
            }
            await scheduleRestart(generation: gen)
        }
    }

    private func fail(_ msg: String) {
        Log.error("Screen \(index + 1): \(msg)")
        statusLock.withLock { $0 = .failed(msg) }
    }

    private func scheduleRestart(generation gen: Int) async {
        let count = control.withLock { c -> Int? in
            guard c.wantRunning && c.generation == gen else { return nil }
            c.restartCount += 1
            return c.restartCount
        }
        guard let count else { return }
        let delay = min(5.0, 0.5 * Double(count))
        try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
        await startStream(generation: gen, attempt: 0)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Only react if this is still our live stream; stops caused by stop() or a newer start are ignored.
        let gen = control.withLock { c -> Int? in
            guard c.wantRunning, c.stream === stream else { return nil }
            c.stream = nil
            return c.generation
        }
        guard let gen else { return }
        Log.error("Capture of screen \(index + 1) stopped: \(error.localizedDescription)")
        Task { await scheduleRestart(generation: gen) }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        // Only complete frames carry new pixels; idle/blank frames just mean "nothing changed".
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: raw), status != .complete {
            return
        }
        let arrival = CACurrentMediaTime()
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer), let cache = textureCache else { return }
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let displayTime = ((CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?
            .first?[.displayTime] as? UInt64).map { Double($0) * Double(tb.numer) / Double(tb.denom) / 1e9 }
        let gap = lastArrival > 0 ? arrival - lastArrival : 0
        lastArrival = arrival
        statsLock.withLock { s in
            s.frames += 1
            if let displayTime, arrival - displayTime < 1 {
                s.latencySum += arrival - displayTime; s.latencyMax = max(s.latencyMax, arrival - displayTime)
            }
            if gap < 0.5 { s.gapMax = max(s.gapMax, gap) }
        }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        var cvTex: CVMetalTexture?
        let r = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, .bgra8Unorm_srgb, w, h, 0, &cvTex)
        guard r == kCVReturnSuccess, let cvTex, let tex = CVMetalTextureGetTexture(cvTex) else { return }
        var cvGamma: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, .bgra8Unorm, w, h, 0, &cvGamma) == kCVReturnSuccess,
              let cvGamma, let gammaTex = CVMetalTextureGetTexture(cvGamma) else { return }
        seq &+= 1
        let frame = Frame(texture: tex, gammaTexture: gammaTex, cvTextures: [cvTex, cvGamma], pixelBuffer: pb, seq: seq, arrival: arrival)
        frameLock.withLock { $0 = frame }
    }
}
