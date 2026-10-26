import AppKit
import ApplicationServices

/// "Mostra numeri": a number on every clickable element of the frontmost window.
/// The user then says the number and the app clicks it. Works even when elements
/// have no readable label (icons), which is where clicking by name fails.
@MainActor
final class NumberOverlay {
    struct Item {
        let number: Int
        let element: AXUIElement
        let frame: CGRect   // global, top-left origin (AX coordinates)
    }

    private(set) var items: [Item] = []
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    var isVisible: Bool { panel?.isVisible == true }

    /// Collects clickable elements and shows the numbers. Returns how many.
    @discardableResult
    func show(timeout: TimeInterval = 30) -> Int {
        hide()
        guard let (app, _) = AX.frontApp(), let window = AX.focusedWindow(in: app),
              let windowFrame = AX.frame(window) else { return 0 }

        let found = AXTree.clickables(in: window, windowFrame: windowFrame)
        items = found.enumerated().map { Item(number: $0.offset + 1, element: $0.element.element, frame: $0.element.frame) }
        guard !items.isEmpty else { return 0 }

        present(windowFrame: windowFrame)
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
        Log.info("Numeri mostrati: \(items.count)")
        return items.count
    }

    func hide() {
        hideTask?.cancel()
        panel?.orderOut(nil)
        panel = nil
    }

    func item(_ number: Int) -> Item? {
        items.first { $0.number == number }
    }

    // MARK: Drawing

    private func present(windowFrame: CGRect) {
        // AX uses a top-left origin on the primary screen; AppKit uses bottom-left.
        guard let primary = NSScreen.screens.first else { return }
        let primaryHeight = primary.frame.height
        let cocoaWindow = CGRect(x: windowFrame.minX, y: primaryHeight - windowFrame.maxY,
                                 width: windowFrame.width, height: windowFrame.height)

        let p = NSPanel(contentRect: cocoaWindow, styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = BadgeView(frame: NSRect(origin: .zero, size: cocoaWindow.size))
        view.badges = items.map { item in
            // Badge at the element's top-left corner, in the panel's (bottom-left) coordinates.
            (item.number, CGPoint(x: item.frame.minX - windowFrame.minX, y: windowFrame.maxY - item.frame.minY))
        }
        p.contentView = view
        p.orderFrontRegardless()
        panel = p
    }

    private final class BadgeView: NSView {
        var badges: [(Int, CGPoint)] = []

        override func draw(_ dirtyRect: NSRect) {
            let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            var placed: [CGRect] = []
            for (number, corner) in badges {
                let text = "\(number)" as NSString
                let size = text.size(withAttributes: attributes)
                var rect = CGRect(x: corner.x, y: corner.y - size.height - 4, width: size.width + 8, height: size.height + 4)
                // Nudge right if it would cover a badge already drawn.
                while placed.contains(where: { $0.insetBy(dx: -1, dy: -1).intersects(rect) }) { rect.origin.x += rect.width + 2 }
                placed.append(rect)
                let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
                NSColor.systemOrange.withAlphaComponent(0.92).setFill()
                path.fill()
                NSColor.black.withAlphaComponent(0.35).setStroke()
                path.lineWidth = 0.5
                path.stroke()
                text.draw(at: CGPoint(x: rect.minX + 4, y: rect.minY + 2), withAttributes: attributes)
            }
        }
    }
}
