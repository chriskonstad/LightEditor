import CoreImage
import Metal
import MetalKit
import QuartzCore

/// How the preview maps image pixels to the view.
public enum PreviewZoom: Hashable, Sendable {
    /// Aspect-fit the whole image.
    case fit
    /// Image pixels per drawable pixel, e.g. 1 for 100%.
    case actual(scale: CGFloat)
}

/// Draws the graded image into an EDR-capable `MTKView`.
///
/// Rendering is pull-based: setting `image` only marks the view dirty, and the view
/// draws at most once per display refresh. At most one frame is in flight; if a new
/// image arrives while the GPU is busy, only the latest one is drawn next. Slider
/// input therefore never queues stale renders. Core Image encodes each frame on a
/// background queue, so the main thread only places the image.
@MainActor
public final class PreviewRenderer: NSObject, MTKViewDelegate {
    public var image: CIImage? { didSet { requestDraw() } }
    public var zoom: PreviewZoom = .fit { didSet { requestDraw() } }
    /// Pan offset in drawable pixels, used when zoomed in.
    public var pan: CGPoint = .zero { didSet { requestDraw() } }
    /// The unedited image for split before/after, the same size as `image`.
    public var before: CIImage? { didSet { requestDraw() } }
    /// Where the before/after divider sits, as a fraction of the view's width;
    /// `before` shows to its left. nil shows no split. The divider stays put in
    /// the view while the image zooms and pans under it.
    public var split: CGFloat? { didSet { requestDraw() } }
    public var background = CIColor(red: 0.055, green: 0.059, blue: 0.067)

    /// Called after each frame with its GPU time, for performance overlays and tests.
    public var onFrame: ((Duration) -> Void)?
    /// Frames presented so far, and the size of the last one in pixels.
    public private(set) var framesDrawn = 0
    public private(set) var lastDrawableSize: CGSize = .zero

    private weak var view: MTKView?
    private let commandQueue: MTLCommandQueue?
    private var inFlight = false
    private var pending = false
    private let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    private let renderQueue = DispatchQueue(label: "LightEditor.PreviewRenderer", qos: .userInteractive)

    public override init() {
        commandQueue = RenderContext.device?.makeCommandQueue()
        super.init()
    }

    public func attach(to view: MTKView) {
        self.view = view
        view.device = RenderContext.device
        view.delegate = self
        view.framebufferOnly = false
        view.colorPixelFormat = .rgba16Float
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.autoResizeDrawable = true
        view.clearColor = MTLClearColor(red: Double(background.red), green: Double(background.green), blue: Double(background.blue), alpha: 1)
        if let layer = view.layer as? CAMetalLayer {
            layer.colorspace = colorSpace
            layer.wantsExtendedDynamicRangeContent = true
            layer.isOpaque = true
        }
        requestDraw()
    }

    public func requestDraw() {
        #if os(macOS)
        view?.needsDisplay = true
        #else
        view?.setNeedsDisplay()
        #endif
    }

    /// The image's on-screen rect in drawable pixels (top-left origin) for the current zoom and pan.
    public func imageRect(in drawableSize: CGSize) -> CGRect {
        guard let extent = image?.extent, extent.width > 0, drawableSize.width > 0 else { return .zero }
        let scale = displayScale(for: extent.size, drawableSize: drawableSize)
        let size = CGSize(width: extent.width * scale, height: extent.height * scale)
        return CGRect(
            x: (drawableSize.width - size.width) / 2 + pan.x,
            y: (drawableSize.height - size.height) / 2 + pan.y,
            width: size.width, height: size.height
        )
    }

    public func displayScale(for imageSize: CGSize, drawableSize: CGSize) -> CGFloat {
        switch zoom {
        case .fit:
            min(drawableSize.width / imageSize.width, drawableSize.height / imageSize.height)
        case .actual(let scale):
            scale
        }
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        requestDraw()
    }

    public func draw(in view: MTKView) {
        guard !inFlight else {
            pending = true
            return
        }
        guard let commandQueue, let drawable = view.currentDrawable, let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let drawableSize = view.drawableSize
        let bounds = CGRect(origin: .zero, size: drawableSize)
        var output = CIImage(color: background).cropped(to: bounds)
        if let image, image.extent.width > 0, image.extent.width.isFinite {
            let rect = imageRect(in: drawableSize)
            let scale = rect.width / image.extent.width
            // `imageRect` uses a top-left origin like SwiftUI; Core Image is bottom-left.
            func place(_ image: CIImage) -> CIImage {
                image
                    .transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
                    .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    .transformed(by: CGAffineTransform(translationX: rect.minX, y: drawableSize.height - rect.maxY))
            }
            var placed = place(image)
            if let before, let split {
                let left = CGRect(x: 0, y: 0, width: drawableSize.width * split, height: drawableSize.height)
                placed = place(before).cropped(to: left).composited(over: placed)
            }
            output = placed.composited(over: output)
        }

        // Core Image plans and encodes the frame on the CPU, which can take a few
        // milliseconds for a big graph; do that off the main thread so gestures
        // and controls stay smooth.
        inFlight = true
        let frame = Frame(output: output, bounds: bounds, drawable: drawable, commandBuffer: commandBuffer,
                          pixelFormat: view.colorPixelFormat, colorSpace: colorSpace)
        renderQueue.async { [weak self] in
            let signpostID = Signposts.display.makeSignpostID()
            let state = Signposts.display.beginInterval("DisplayFrame", id: signpostID)
            let start = ContinuousClock.now
            let destination = CIRenderDestination(
                width: Int(frame.bounds.width), height: Int(frame.bounds.height),
                pixelFormat: frame.pixelFormat, commandBuffer: frame.commandBuffer,
                mtlTextureProvider: { frame.drawable.texture }
            )
            destination.colorSpace = frame.colorSpace
            do {
                _ = try RenderContext.shared.startTask(toRender: frame.output, from: frame.bounds, to: destination, at: .zero)
            } catch {
                Signposts.display.endInterval("DisplayFrame", state)
                Task { @MainActor in self?.finishFrame(drawableSize: nil, elapsed: nil) }
                return
            }
            frame.commandBuffer.present(frame.drawable)
            frame.commandBuffer.addCompletedHandler { _ in
                let elapsed = ContinuousClock.now - start
                Signposts.display.endInterval("DisplayFrame", state)
                Task { @MainActor in self?.finishFrame(drawableSize: frame.bounds.size, elapsed: elapsed) }
            }
            frame.commandBuffer.commit()
        }
    }

    private func finishFrame(drawableSize: CGSize?, elapsed: Duration?) {
        inFlight = false
        if let drawableSize, let elapsed {
            framesDrawn += 1
            lastDrawableSize = drawableSize
            onFrame?(elapsed)
        }
        if pending {
            pending = false
            requestDraw()
        }
    }
}

/// One frame handed to the render queue.
private struct Frame: @unchecked Sendable {
    let output: CIImage
    let bounds: CGRect
    let drawable: CAMetalDrawable
    let commandBuffer: MTLCommandBuffer
    let pixelFormat: MTLPixelFormat
    let colorSpace: CGColorSpace
}
