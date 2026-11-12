import AppKit
import AVFoundation
import SwiftUI

// Renders every pill state and window tab to PNG so the interface can be checked without a screen recording
enum Snapshots {
    static func render(to dir: URL) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let states: [(String, PillState)] = [
            ("pill-idle", .idle),
            ("pill-listening", .listening),
            ("pill-working", .working),
            ("pill-pasted", .message("Pasted", symbol: "checkmark")),
            ("pill-not-pasted", .message("Nowhere to paste", symbol: "doc.on.doc")),
            ("pill-learned", .message("Learned Deepwoken", symbol: "text.book.closed")),
            ("pill-warning", .warning("Five minutes left")),
            ("pill-limit", .message("Twenty minutes is up", symbol: "clock")),
        ]
        for (name, state) in states {
            let model = OverlayModel()
            model.state = state
            model.level = 0.8
            for (suffix, backdrop) in [("dark", NSColor(calibratedWhite: 0.18, alpha: 1)), ("light", NSColor(calibratedWhite: 0.96, alpha: 1))] {
                let view = ZStack { Color(nsColor: backdrop); PillView(model: model) }.frame(width: 420, height: 64)
                save(view, size: NSSize(width: 420, height: 64), to: dir.appendingPathComponent("\(name)-\(suffix).png"))
            }
        }
        let card = MissedPasteModel()
        card.text = "We should run the raid again tonight once everyone is on, and keep the new zone for the weekend so nobody misses it."
        let cardView = ZStack {
            Color(nsColor: NSColor(calibratedWhite: 0.85, alpha: 1))
            MissedPasteView(model: card, onCopy: {}, onHistory: {}, onClose: {}, onHover: { _ in })
        }.frame(width: 500, height: 200)
        save(cardView, size: NSSize(width: 500, height: 200), to: dir.appendingPathComponent("missed-paste-card.png"))
        card.title = "Twenty minutes is up"
        save(cardView, size: NSSize(width: 500, height: 200), to: dir.appendingPathComponent("missed-paste-card-limit.png"))
        for tab in MainTab.allCases {
            WindowRouter.shared.tab = tab
            save(MainView(), size: NSSize(width: 820, height: 560), to: dir.appendingPathComponent("window-\(tab.rawValue).png"))
        }
        print("rendered to \(dir.path)")
    }

    private static func save<V: View>(_ view: V, size: NSSize, to url: URL) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    static func diagnose() {
        print("accessibility trusted: \(AX.trusted)")
        print("input monitoring: \(CGPreflightListenEventAccess())")
        print("microphone: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) (3 means allowed)")
        print("llama-server: \(Paths.llamaServer?.path ?? "missing")")
        for m in ModelCatalog.all {
            print("model \(m.fileName): \(FileManager.default.fileExists(atPath: Paths.models.appendingPathComponent(m.fileName).path))")
        }
    }
}
