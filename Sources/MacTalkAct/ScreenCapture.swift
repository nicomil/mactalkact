import AppKit
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case noWindow
    case encoding

    var errorDescription: String? {
        switch self {
        case .noWindow: return "Nessuna finestra in primo piano da catturare"
        case .encoding: return "Impossibile codificare lo screenshot"
        }
    }
}

/// A screenshot of the frontmost window, plus what is needed to turn a point in the
/// image back into a point on screen (for clicking).
struct WindowShot {
    let image: CGImage
    let imageSize: CGSize
    /// Window frame in global screen coordinates (top-left origin, like AX and CGEvent).
    let windowFrame: CGRect

    /// JPEG of the screenshot with numbered tags drawn on the given elements
    /// ("set-of-marks"): the model can then click by number instead of guessing pixels.
    func jpeg(marks: [(Int, CGRect)] = []) -> Data? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        if !marks.isEmpty {
            // Top-left coordinates from here on, like the screen.
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            let sx = CGFloat(w) / windowFrame.width, sy = CGFloat(h) / windowFrame.height
            let font = NSFont.monospacedDigitSystemFont(ofSize: max(10, 11 * sx), weight: .bold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            var placed: [CGRect] = []
            for (number, frame) in marks {
                let r = CGRect(x: (frame.minX - windowFrame.minX) * sx, y: (frame.minY - windowFrame.minY) * sy,
                               width: frame.width * sx, height: frame.height * sy)
                NSColor.systemOrange.withAlphaComponent(0.75).setStroke()
                let outline = NSBezierPath(rect: r)
                outline.lineWidth = 1
                outline.stroke()
                let label = "\(number)" as NSString
                let size = label.size(withAttributes: attributes)
                var tag = CGRect(x: max(0, r.minX), y: max(0, r.minY), width: size.width + 6, height: size.height + 2)
                while placed.contains(where: { $0.intersects(tag) }) { tag.origin.x += tag.width + 1 }
                placed.append(tag)
                NSColor.systemOrange.setFill()
                NSBezierPath(roundedRect: tag, xRadius: 3, yRadius: 3).fill()
                label.draw(at: CGPoint(x: tag.minX + 3, y: tag.minY + 1), withAttributes: attributes)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .jpeg, properties: [.compressionFactor: 0.6])
    }

    func screenPoint(imageX x: Double, imageY y: Double) -> CGPoint {
        CGPoint(x: windowFrame.minX + x * windowFrame.width / imageSize.width,
                y: windowFrame.minY + y * windowFrame.height / imageSize.height)
    }
}

enum ScreenCapture {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    static func requestPermission() {
        _ = CGRequestScreenCaptureAccess()
    }

    /// Captures the frontmost app's main window, scaled so its longest side is at most `maxSide`.
    @MainActor
    static func frontWindow(maxSide: CGFloat = 1400) async throws -> WindowShot {
        guard let front = AX.frontmostApplication() else { throw CaptureError.noWindow }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let candidates = content.windows.filter {
            $0.owningApplication?.processID == front.processIdentifier && $0.windowLayer == 0
                && $0.frame.width > 80 && $0.frame.height > 80
        }
        // Prefer the window Accessibility reports as focused; otherwise the largest.
        let axFrame = ScreenContext.capture(includeLabels: false).windowFrame
        let window = candidates.min { a, b in
            distance(a.frame, axFrame) < distance(b.frame, axFrame)
        } ?? candidates.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        let filter: SCContentFilter
        let frame: CGRect
        let config = SCStreamConfiguration()
        if let window {
            filter = SCContentFilter(desktopIndependentWindow: window)
            frame = window.frame
        } else {
            // Window not listed (e.g. a just-opened message window): capture the screen
            // it is on and crop to the window frame Accessibility reports.
            guard let display = content.displays.first(where: { d in axFrame.map { d.frame.intersects($0) } ?? false })
                    ?? content.displays.first else { throw CaptureError.noWindow }
            let ownApp = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])
            frame = axFrame.map { $0.intersection(display.frame) } ?? display.frame
            config.sourceRect = CGRect(x: frame.minX - display.frame.minX, y: frame.minY - display.frame.minY,
                                       width: frame.width, height: frame.height)
            Log.debug("Screenshot: finestra non elencata, ritaglio dallo schermo")
        }
        guard frame.width > 10, frame.height > 10 else { throw CaptureError.noWindow }
        let scale = min(1, maxSide / max(frame.width, frame.height))
        config.width = Int(frame.width * scale)
        config.height = Int(frame.height * scale)
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

        return WindowShot(image: image, imageSize: CGSize(width: image.width, height: image.height),
                          windowFrame: frame)
    }

    private static func distance(_ a: CGRect, _ b: CGRect?) -> CGFloat {
        guard let b else { return .greatestFiniteMagnitude }
        return abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }
}
