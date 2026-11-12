import AppKit
import SwiftUI

final class MissedPasteModel: ObservableObject {
    @Published var text = ""
    @Published var title = MissedPasteModel.nowhereToPaste
    @Published var copiedAgain = false

    static let nowhereToPaste = "Nowhere to paste"
}

// A clickable card above the bar that shows dictated text which had nowhere to go
final class MissedPasteCard {
    private let model = MissedPasteModel()
    private var panel: NSPanel?
    private var host: NSHostingView<MissedPasteView>?
    private var hideTimer: Timer?
    private var hovering = false
    private var shownAt = Date()

    func show(_ text: String, title: String = MissedPasteModel.nowhereToPaste) {
        model.text = text
        model.title = title
        model.copiedAgain = false
        hovering = false
        shownAt = Date()
        if panel == nil { build() }
        guard let panel, let host else { return }
        // The window hugs the card so no invisible margin swallows clicks meant for the app behind it
        host.layoutSubtreeIfNeeded()
        panel.setContentSize(host.fittingSize)
        position(panel)
        panel.orderFrontRegardless()
        scheduleHide()
    }

    func hide() {
        hideTimer?.invalidate()
        hovering = false
        panel?.orderOut(nil)
    }

    // Six seconds and a resting pointer buys more time but never past thirty
    private func scheduleHide() {
        hideTimer?.invalidate()
        hideTimer = commonTimer(6, repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.hovering, Date().timeIntervalSince(self.shownAt) < 30 { self.scheduleHide() } else { self.hide() }
        }
    }

    private func build() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 230),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        let view = MissedPasteView(
            model: model,
            onCopy: { [weak self] in
                guard let self else { return }
                TextInserter.copy(self.model.text)
                self.model.copiedAgain = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { self.hide() }
            },
            onHistory: { [weak self] in
                self?.hide()
                AppDelegate.shared?.showWindow(tab: .history)
            },
            onClose: { [weak self] in self?.hide() },
            onHover: { [weak self] inside in self?.hovering = inside })
        let hosting = NSHostingView(rootView: view)
        p.contentView = hosting
        host = hosting
        panel = p
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2, y: visible.minY + 56))
    }
}

struct MissedPasteView: View {
    @ObservedObject var model: MissedPasteModel
    let onCopy: () -> Void
    let onHistory: () -> Void
    let onClose: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.doc").font(.system(size: 11, weight: .semibold))
                Text(model.title).font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.white.opacity(0.6))
                    .help("Close")
            }
            .foregroundStyle(Color.white)
            Text(model.text)
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.92))
                .lineLimit(6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 18) {
                Button(model.copiedAgain ? "Copied" : "Copy", action: onCopy)
                Button("Open History", action: onHistory)
                Spacer()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.white)
        }
        .padding(14)
        .frame(width: 440)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.3))
                RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color(white: 0.06)).padding(1)
            }
        )
        .onHover(perform: onHover)
    }
}
