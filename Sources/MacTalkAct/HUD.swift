import AppKit
import SwiftUI

@MainActor
final class HUDModel: ObservableObject {
    enum Phase: Equatable { case listening, thinking, working, success, error, confirm, info }
    @Published var phase: Phase = .info
    @Published var title = ""
    @Published var detail = ""
    @Published var level: Float = 0
}

/// The floating "pill" at the bottom of the screen. It never takes focus,
/// so typing and clicking keep going to the app the user was working in.
@MainActor
final class HUDController {
    let model = HUDModel()
    private let panel: NSPanel
    private var hideTask: Task<Void, Never>?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 120),
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

    func show(_ phase: HUDModel.Phase, _ title: String, detail: String = "", autoHide: TimeInterval? = nil) {
        hideTask?.cancel()
        model.phase = phase
        model.title = title
        model.detail = detail
        position()
        panel.orderFrontRegardless()
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
        panel.orderOut(nil)
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 24))
    }
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                indicator
                    .frame(width: 30, height: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title.isEmpty ? "Ti ascolto…" : model.title)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(2)
                        .truncationMode(.head)
                    if !model.detail.isEmpty {
                        Text(model.detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(minWidth: 220, maxWidth: 600)
            .fixedSize(horizontal: false, vertical: true)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(tint.opacity(0.6), lineWidth: 1.5)
            )
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
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
