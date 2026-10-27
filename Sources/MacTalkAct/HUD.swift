import AppKit
import ApplicationServices
import SwiftUI

@MainActor
final class HUDModel: ObservableObject {
    enum Phase: Equatable { case listening, thinking, working, success, error, confirm, info }
    @Published var phase: Phase = .info
    @Published var title = ""
    @Published var detail = ""
    @Published var level: Float = 0
    /// A small pill (icon and a few words): «Ti ascolto ancora» during the conversation window.
    @Published var mini = false
    @Published var compact = true
    /// Where the pill sits inside the (larger, transparent) panel.
    @Published var alignment: Alignment = .bottom
    /// Size of the visible pill, measured by the view: the controller uses it to dodge the caret.
    @Published var pillSize: CGSize = .zero
}

/// The floating message at the bottom (or top) of the screen. It never takes focus and lets
/// clicks through, so typing and clicking keep going to the app the user was working in.
/// In automatic position it moves to the top when it would cover the caret or the pointer.
@MainActor
final class HUDController {
    let model = HUDModel()
    private let panel: NSPanel
    private var hideTask: Task<Void, Never>?
    private var dodgeTask: Task<Void, Never>?
    /// The automatic position currently in use (bottom first, top when bottom covers something).
    private var autoPlace: HUDPosition = .bottom
    private static let panelSize = NSSize(width: 660, height: 300)

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: HUDView(model: model))
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = host
    }

    var isVisible: Bool { panel.isVisible }

    func show(_ phase: HUDModel.Phase, _ title: String, detail: String = "", autoHide: TimeInterval? = nil, mini: Bool = false) {
        hideTask?.cancel()
        let settings = AppSettings.shared
        model.compact = settings.hudCompact
        model.mini = mini && settings.hudCompact
        model.phase = phase
        model.title = title
        model.detail = model.mini ? "" : detail
        if !panel.isVisible { autoPlace = .bottom }
        position()
        panel.orderFrontRegardless()
        startDodging()
        if let autoHide {
            hideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(autoHide))
                guard !Task.isCancelled else { return }
                self?.hide()
            }
        }
    }

    /// Updates the text without changing phase (live transcript).
    func update(_ title: String) {
        model.title = title
    }

    func hide() {
        hideTask?.cancel()
        dodgeTask?.cancel()
        panel.orderOut(nil)
    }

    // MARK: Position

    private var screen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    private var place: HUDPosition {
        let p = AppSettings.shared.hudPosition
        return p == .auto ? autoPlace : p
    }

    private func position() {
        guard let visible = screen?.visibleFrame else { return }
        let size = Self.panelSize
        var origin = NSPoint.zero
        switch place {
        case .auto, .bottom:
            model.alignment = .bottom
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 18)
        case .top:
            model.alignment = .top
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - 10 - size.height)
        case .topRight:
            model.alignment = .topTrailing
            origin = NSPoint(x: visible.maxX - 14 - size.width, y: visible.maxY - 10 - size.height)
        case .bottomRight:
            model.alignment = .bottomTrailing
            origin = NSPoint(x: visible.maxX - 14 - size.width, y: visible.minY + 18)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    /// The visible pill on screen (Cocoa coordinates), from the panel and the measured size.
    private func pillRect(for p: HUDPosition) -> NSRect? {
        guard let visible = screen?.visibleFrame, model.pillSize.width > 0 else { return nil }
        let w = model.pillSize.width, h = model.pillSize.height
        switch p {
        case .auto, .bottom: return NSRect(x: visible.midX - w / 2, y: visible.minY + 18, width: w, height: h)
        case .top: return NSRect(x: visible.midX - w / 2, y: visible.maxY - 10 - h, width: w, height: h)
        case .topRight: return NSRect(x: visible.maxX - 14 - w, y: visible.maxY - 10 - h, width: w, height: h)
        case .bottomRight: return NSRect(x: visible.maxX - 14 - w, y: visible.minY + 18, width: w, height: h)
        }
    }

    /// In automatic position, checks a few times a second whether the pill covers the caret or the
    /// pointer, and moves it to the top (or back to the bottom when the way is clear).
    private func startDodging() {
        dodgeTask?.cancel()
        guard AppSettings.shared.hudPosition == .auto else { return }
        dodgeTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.panel.isVisible {
                self.dodge()
                try? await Task.sleep(for: .milliseconds(350))
            }
        }
    }

    private func dodge() {
        let obstacles = Self.obstacles()
        func covers(_ p: HUDPosition) -> Bool {
            guard let r = pillRect(for: p)?.insetBy(dx: -24, dy: -24) else { return false }
            return obstacles.contains { $0.intersects(r) }
        }
        let wanted: HUDPosition = !covers(.bottom) ? .bottom : !covers(.top) ? .top : .topRight
        if wanted != autoPlace {
            autoPlace = wanted
            position()
        }
    }

    /// The pointer and the caret (or the focused field when it is small), in Cocoa coordinates.
    private static func obstacles() -> [NSRect] {
        let mouse = NSEvent.mouseLocation
        var out = [NSRect(x: mouse.x - 8, y: mouse.y - 8, width: 16, height: 16)]
        if let caret = caretRect() { out.append(caret) }
        return out
    }

    private static func caretRect() -> NSRect? {
        guard let (app, _) = AX.frontApp(), let focused = AX.focusedElement(in: app) else { return nil }
        var axRect: CGRect?
        if var range = AX.selectedRange(focused) {
            range.length = max(range.length, 0)
            if let param = AXValueCreate(.cfRange, &range) {
                var value: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(focused, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                              param, &value) == .success,
                   let v = value, CFGetTypeID(v) == AXValueGetTypeID() {
                    var r = CGRect.zero
                    if AXValueGetValue(v as! AXValue, .cgRect, &r), r.height > 0 { axRect = r }
                }
            }
        }
        if axRect == nil, let f = AX.frame(focused), f.height < 160, f.width < 1600 { axRect = f }
        guard let r = axRect, let primary = NSScreen.screens.first?.frame else { return nil }
        // AX uses top-left coordinates on the primary screen; Cocoa uses bottom-left.
        return NSRect(x: r.minX, y: primary.maxY - r.maxY, width: max(r.width, 2), height: r.height)
    }
}

private struct PillSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    private var titleSize: CGFloat { model.mini ? 12 : model.compact ? 13.5 : 15 }

    var body: some View {
        pill
            .background(GeometryReader { g in Color.clear.preference(key: PillSizeKey.self, value: g.size) })
            .onPreferenceChange(PillSizeKey.self) { size in
                Task { @MainActor in model.pillSize = size }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.alignment)
    }

    /// Text column wider than this wraps onto more lines.
    private var maxTextWidth: CGFloat { model.compact ? 460 : 540 }

    private var content: some View {
        HStack(spacing: model.mini ? 7 : model.compact ? 10 : 12) {
            indicator
                .frame(width: model.mini ? 18 : model.compact ? 24 : 30, height: model.mini ? 16 : 26)
                .scaleEffect(model.mini ? 0.7 : model.compact ? 0.85 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title.isEmpty ? "Ti ascolto…" : model.title)
                    .font(.system(size: titleSize, weight: .medium))
                    // Answers and explanations: several lines, read from the start.
                    // Live text: two lines, the end visible.
                    .lineLimit(model.mini ? 1 : model.phase == .success ? 7 : 2)
                    .truncationMode(model.phase == .success ? .tail : .head)
                if !model.detail.isEmpty {
                    Text(model.detail)
                        .font(.system(size: model.compact ? 11 : 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    /// As wide as its text (a short message is a small pill), wrapping only past `maxTextWidth`.
    private var pill: some View {
        ViewThatFits(in: .horizontal) {
            content.fixedSize()
            content.frame(width: maxTextWidth, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, model.mini ? 11 : model.compact ? 14 : 18)
        .padding(.vertical, model.mini ? 5 : model.compact ? 8 : 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: model.mini ? 11 : model.compact ? 15 : 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: model.mini ? 11 : model.compact ? 15 : 20, style: .continuous)
                .strokeBorder(tint.opacity(model.mini ? 0.4 : 0.6), lineWidth: model.mini ? 1 : 1.5)
        )
        .opacity(model.mini ? 0.85 : 1)
    }

    private var tint: Color {
        switch model.phase {
        case .listening: return .accentColor
        case .thinking, .working: return .purple
        case .success: return .green
        case .error: return .orange
        case .confirm: return .blue
        case .info: return .gray
        }
    }

    @ViewBuilder private var indicator: some View {
        switch model.phase {
        case .listening:
            LevelBars(level: model.level)
        case .thinking, .working:
            ProgressView().controlSize(.small)
        case .success:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(.green)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 18)).foregroundStyle(.orange)
        case .confirm:
            Image(systemName: "questionmark.circle.fill").font(.system(size: 20)).foregroundStyle(.blue)
        case .info:
            Image(systemName: "hand.raised.fill").font(.system(size: 18)).foregroundStyle(.secondary)
        }
    }
}

struct LevelBars: View {
    let level: Float
    private let weights: [CGFloat] = [0.5, 0.85, 1.0, 0.8, 0.55]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 4, height: 5 + CGFloat(level) * 21 * weights[i])
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
    }
}

/// Short, quiet sounds: a sleeping baby should not wake up. Volume and on/off from the settings.
@MainActor
enum Sound {
    private static func play(_ name: String) {
        let settings = AppSettings.shared
        guard settings.soundsEnabled, let s = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
        s.volume = Float(settings.soundsVolume)
        s.play()
    }
    static func listen() { play("Tink") }
    static func confirm() { play("Glass") }
    static func error() { play("Basso") }
    static func cancel() { play("Pop") }
}
