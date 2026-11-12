import AppKit
import Combine
import SwiftUI

enum PillState: Equatable {
    case idle
    case listening
    case working
    case message(String, symbol: String)
    case warning(String)
}

final class OverlayModel: ObservableObject {
    @Published var state: PillState = .idle
    @Published var showIdle = true
    // Smoothed voice level from 0 to 1 that the bars read every frame so it is deliberately not published
    var level: CGFloat = 0

    /* Speech on this mic sits near minus thirty five dB and a whisper near minus fifty five so the scale starts at
    minus sixty. It rises fast and falls slowly so syllables pop and the bars do not flicker between them. */
    func push(level raw: Float) {
        let db = 20 * log10(max(raw, 0.00001))
        let target = CGFloat(max(0, min(1, (db + 60) / 30)))
        level = target > level ? level + (target - level) * 0.65 : level * 0.8 + target * 0.2
    }

    func resetLevels() { level = 0 }
}

final class OverlayController {
    let model = OverlayModel()
    private var panel: NSPanel?
    private var messageTimer: Timer?
    private var settingsSub: AnyCancellable?

    init() {
        settingsSub = AppSettings.shared.$showIdlePill.sink { [weak self] show in
            self?.model.showIdle = show
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rebuild()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rebuild()
        }
    }

    func show(_ state: PillState, for seconds: TimeInterval? = nil) {
        messageTimer?.invalidate()
        if state == .listening { model.resetLevels() }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { model.state = state }
        ensurePanel()
        if let seconds {
            messageTimer = commonTimer(seconds, repeats: false) { [weak self] _ in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { self?.model.state = .idle }
            }
        }
    }

    func level(_ value: Float) { model.push(level: value) }

    // A panel can go stale after sleep or a display change so it is rebuilt rather than trusted
    func rebuild() {
        panel?.orderOut(nil)
        panel = nil
        ensurePanel()
    }

    private func ensurePanel() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 64),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.hidesOnDeactivate = false
            p.contentView = NSHostingView(rootView: PillView(model: model))
            panel = p
        }
        guard let panel else { return }
        position(panel)
        panel.orderFrontRegardless()
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 6))
    }
}

struct PillView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            content
        }
        .frame(width: 420, height: 64)
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle:
            if model.showIdle {
                HairlineCapsule(fill: Color(white: 0.1).opacity(0.75), edge: Color(white: 0.55).opacity(0.8))
                    .frame(width: 42, height: 9)
                    .padding(.bottom, 4)
                    .transition(.opacity)
            }
        case .listening:
            shell { VoiceBars(model: model) }
        case .working:
            shell { WorkingDots() }
        case .message(let text, let symbol):
            shell {
                HStack(spacing: 6) {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                    Text(text).font(.system(size: 12, weight: .medium)).lineLimit(1)
                }
                .foregroundStyle(Color.white)
            }
        case .warning(let text):
            shell {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 11, weight: .semibold))
                    Text(text).font(.system(size: 12, weight: .medium)).lineLimit(1)
                }
                .foregroundStyle(Color(red: 1, green: 0.62, blue: 0.55))
            }
        }
    }

    private func shell<Content: View>(@ViewBuilder _ inner: () -> Content) -> some View {
        inner()
            .padding(.horizontal, 14)
            .frame(minWidth: 96)
            .frame(height: 32)
            .background(HairlineCapsule(fill: Color(white: 0.04), edge: Color(white: 0.3)))
            .transition(.scale(scale: 0.6).combined(with: .opacity))
    }
}

// Two stacked fills instead of strokeBorder which left stray ticks at the capsule ends
struct HairlineCapsule: View {
    let fill: Color
    let edge: Color

    var body: some View {
        ZStack {
            Capsule().fill(edge)
            Capsule().fill(fill).padding(1)
        }
    }
}

// Bars mirror around the middle line and bounce with the voice while a slow ripple shows it is still listening in silence
struct VoiceBars: View {
    let model: OverlayModel
    private static let weights: [CGFloat] = [0.4, 0.6, 0.8, 0.95, 1.0, 0.95, 0.8, 0.6, 0.4]

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let level = model.level
            HStack(alignment: .center, spacing: 4) {
                ForEach(0..<Self.weights.count, id: \.self) { i in
                    let bounce = 0.55 + 0.45 * sin(t * (9 + Double(i % 3) * 3.1) + Double(i) * 1.9)
                    let ripple = 0.1 + 0.07 * sin(t * 3 - Double(i) * 0.7)
                    let height = max(CGFloat(ripple), level * Self.weights[i] * CGFloat(bounce))
                    Capsule()
                        .fill(Color.white)
                        .frame(width: 3.5, height: 4 + 18 * height)
                }
            }
            .frame(height: 24)
        }
    }
}

struct WorkingDots: View {
    @State private var phase = 0.0

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.white)
                        .frame(width: 5, height: 5)
                        .opacity(0.35 + 0.65 * (0.5 + 0.5 * sin(t * 6 - Double(i) * 0.9)))
                }
            }
        }
    }
}
