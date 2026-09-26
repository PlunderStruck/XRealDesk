import AppKit
import Metal
import QuartzCore

/// View backed by a CAMetalLayer. Frames are drawn by `Compositor` on its own thread,
/// paced by the display the layer is on (the glasses: up to 120 Hz).
final class MetalHostView: NSView {
    let metalLayer = CAMetalLayer()
    private let hud = CATextLayer()
    private var hudHideWork: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        hud.alignmentMode = .center
        hud.foregroundColor = NSColor.white.cgColor
        hud.backgroundColor = NSColor(white: 0.12, alpha: 0.92).cgColor
        hud.cornerRadius = 10
        hud.font = NSFont.systemFont(ofSize: 22, weight: .medium)
        hud.fontSize = 22
        hud.opacity = 0
        hud.isWrapped = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer {
        metalLayer.pixelFormat = .bgra8Unorm_srgb
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = 3
        metalLayer.displaySyncEnabled = true
        metalLayer.backgroundColor = NSColor.black.cgColor
        return metalLayer
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if hud.superlayer == nil { layer?.addSublayer(hud) }
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
    func showHUD(_ text: String, seconds: Double = 1.6) {
        hudHideWork?.cancel()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hud.string = text
        hud.contentsScale = window?.backingScaleFactor ?? 2
        layoutHUD()
        CATransaction.commit()
        hud.opacity = 1
        let work = DispatchWorkItem { [weak self] in self?.hud.opacity = 0 }
        hudHideWork = work
        if seconds > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work) }
    }

    func hideHUD() {
        hudHideWork?.cancel()
        hud.opacity = 0
    }

    private func layoutHUD() {
        let text = (hud.string as? String) ?? ""
        let w = min(bounds.width * 0.6, max(260, CGFloat(text.count) * 12 + 40))
        let h: CGFloat = text.contains("\n") ? 76 : 44
        hud.frame = CGRect(x: (bounds.width - w) / 2, y: bounds.height * 0.18, width: w, height: h)
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
