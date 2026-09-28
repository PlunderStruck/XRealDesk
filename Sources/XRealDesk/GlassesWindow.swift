import AppKit
import Metal
import QuartzCore

/// View backed by a CAMetalLayer. Frames are drawn by `Compositor` on its own thread,
/// paced by the display the layer is on (the glasses: up to 120 Hz).
final class MetalHostView: NSView {
    let metalLayer = CAMetalLayer()
    /// Two copies so the toast shows in both eyes' halves in side-by-side 3D (one used in 2D).
    private let huds = [CATextLayer(), CATextLayer()]
    private var hud: CATextLayer { huds[0] }
    private var hudHideWork: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        for hud in huds {
            hud.alignmentMode = .center
            hud.foregroundColor = NSColor.white.cgColor
            hud.backgroundColor = NSColor(white: 0.12, alpha: 0.92).cgColor
            hud.cornerRadius = 10
            hud.font = NSFont.systemFont(ofSize: 22, weight: .medium)
            hud.fontSize = 22
            hud.opacity = 0
            hud.isWrapped = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer {
        metalLayer.pixelFormat = .bgra8Unorm_srgb
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = 3
        metalLayer.displaySyncEnabled = true
        metalLayer.backgroundColor = NSColor.black.cgColor
        metalLayer.isOpaque = true
        return metalLayer
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 1
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        layoutHUD()
    }


    /// Head-locked toast in the lower middle of the view.
    /// A message shown until explicitly hidden (seconds: 0), e.g. "tracking lost". Brief messages
    /// shown meanwhile return to it instead of hiding it.
    private var stickyText: String?

    func showHUD(_ text: String, seconds: Double = 1.6) {
        if seconds <= 0 { stickyText = text }
        hudHideWork?.cancel()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Attached only while showing, so the window is otherwise a single opaque Metal layer.
        for hud in huds where hud.superlayer == nil { layer?.addSublayer(hud) }
        for hud in huds {
            hud.string = text
            hud.contentsScale = window?.backingScaleFactor ?? 2
        }
        layoutHUD()
        CATransaction.commit()
        for (i, hud) in huds.enumerated() { hud.opacity = i == 0 || isSideBySide ? 1 : 0 }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if let sticky = self.stickyText { self.showHUD(sticky, seconds: 0) } else { self.hideHUD() }
        }
        hudHideWork = work
        if seconds > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work) }
    }

    // MARK: Calibration aim ring (head-locked: drawn on top of the picture, moves with the head)

    private let aimRing = CAShapeLayer(), aimFill = CAShapeLayer(), aimDot = CAShapeLayer()
    private var aimConfigured = false

    /// `p`: where straight ahead appears (0…1, y top → bottom); `progress` 0…1 fills the ring.
    func showAim(at p: SIMD2<Float>, progress: CGFloat, color: NSColor = .systemGreen) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !aimConfigured {
            aimConfigured = true
            let r: CGFloat = 16
            let ring = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r), transform: nil)
            aimRing.path = ring
            aimRing.fillColor = nil
            aimRing.strokeColor = NSColor(white: 1, alpha: 0.85).cgColor
            aimRing.lineWidth = 2
            // Progress arc from 12 o'clock, clockwise.
            let arc = CGMutablePath()
            arc.addArc(center: .zero, radius: r, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
            aimFill.path = arc
            aimFill.fillColor = nil
            aimFill.lineWidth = 4
            aimFill.lineCap = .round
            aimDot.path = CGPath(ellipseIn: CGRect(x: -2.5, y: -2.5, width: 5, height: 5), transform: nil)
            aimDot.fillColor = NSColor.white.cgColor
        }
        for l in [aimRing, aimFill, aimDot] where l.superlayer == nil { layer?.addSublayer(l) }
        let pos = CGPoint(x: CGFloat(p.x) * bounds.width / (isSideBySide ? 2 : 1), y: bounds.height * (1 - CGFloat(p.y)))
        for l in [aimRing, aimFill, aimDot] { l.position = pos }
        aimFill.strokeColor = color.cgColor
        aimFill.strokeEnd = min(max(progress, 0), 1)
        aimFill.opacity = progress > 0.001 ? 1 : 0
        CATransaction.commit()
    }

    // MARK: Session progress (head-locked bar near the bottom)

    private let progressTrack = CALayer(), progressFill = CALayer(), progressText = CATextLayer()
    private var progressConfigured = false

    /// `fraction` nil hides the bar.
    func showProgress(_ fraction: Double?, text: String) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let fraction else { [progressTrack, progressFill, progressText].forEach { $0.removeFromSuperlayer() }; return }
        if !progressConfigured {
            progressConfigured = true
            progressTrack.backgroundColor = NSColor(white: 1, alpha: 0.18).cgColor
            progressTrack.cornerRadius = 3
            progressFill.backgroundColor = NSColor.systemGreen.cgColor
            progressFill.cornerRadius = 3
            progressText.fontSize = 16; progressText.font = NSFont.systemFont(ofSize: 16, weight: .medium)
            progressText.foregroundColor = NSColor(white: 1, alpha: 0.85).cgColor
            progressText.alignmentMode = .center
        }
        for l in [progressTrack, progressFill, progressText] where l.superlayer == nil { layer?.addSublayer(l) }
        let eyeWidth = bounds.width / (isSideBySide ? 2 : 1)
        let w = eyeWidth * 0.42, x = (eyeWidth - w) / 2, y = bounds.height * 0.1
        progressTrack.frame = CGRect(x: x, y: y, width: w, height: 6)
        progressFill.frame = CGRect(x: x, y: y, width: w * CGFloat(min(max(fraction, 0), 1)), height: 6)
        progressText.contentsScale = window?.backingScaleFactor ?? 2
        progressText.string = text
        progressText.frame = CGRect(x: x - 40, y: y + 10, width: w + 80, height: 22)
    }

    func hideAim() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        [aimRing, aimFill, aimDot].forEach { $0.removeFromSuperlayer() }
        CATransaction.commit()
    }

    func hideHUD() {
        stickyText = nil
        hudHideWork?.cancel()
        huds.forEach { $0.opacity = 0; $0.removeFromSuperlayer() }
    }

    /// The glasses are in side-by-side 3D (3840x1080): each half of the view goes to one eye.
    var isSideBySide: Bool { bounds.width > bounds.height * 2.5 }

    private func layoutHUD() {
        let text = (hud.string as? String) ?? ""
        let halves: CGFloat = isSideBySide ? 2 : 1
        let eyeWidth = bounds.width / halves
        let w = min(eyeWidth * 0.6, max(260, CGFloat(text.count) * 12 + 40))
        let h: CGFloat = text.contains("\n") ? 76 : 44
        for (i, hud) in huds.enumerated() {
            let half = min(CGFloat(i), halves - 1)
            hud.frame = CGRect(x: half * eyeWidth + (eyeWidth - w) / 2, y: bounds.height * 0.18, width: w, height: h)
        }
        if !isSideBySide { huds[1].opacity = 0 }
    }
}

/// Borderless, click-through window covering the glasses' display (or a normal window in preview mode).
final class GlassesWindow: NSWindow {
    let hostView: MetalHostView
    let isPreview: Bool

    init(screen: NSScreen?, preview: Bool) {
        let frame: NSRect
        if preview {
            let main = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            frame = NSRect(x: main.midX - 480, y: main.midY - 270, width: 960, height: 540)
        } else {
            frame = screen?.frame ?? .zero
        }
        hostView = MetalHostView(frame: NSRect(origin: .zero, size: frame.size))
        isPreview = preview
        super.init(contentRect: frame, styleMask: preview ? [.titled, .resizable, .closable, .miniaturizable] : [.borderless],
                   backing: .buffered, defer: false)
        contentView = hostView
        isReleasedWhenClosed = false
        backgroundColor = .black
        isOpaque = true
        hasShadow = false
        if preview {
            title = "XRealDesk Preview"
            contentAspectRatio = NSSize(width: 16, height: 9)
        } else {
            level = .screenSaver
            ignoresMouseEvents = true
            collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            animationBehavior = .none
            if let screen { setFrame(screen.frame, display: true) }
        }
    }

    override var canBecomeKey: Bool { isPreview }
    override var canBecomeMain: Bool { isPreview }

    func move(to screen: NSScreen) {
        setFrame(screen.frame, display: true)
    }
}
