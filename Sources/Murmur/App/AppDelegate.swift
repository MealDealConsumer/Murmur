import AppKit
import AVFoundation
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    static weak var shared: AppDelegate?

    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private var subs = Set<AnyCancellable>()
    private let controller = DictationController.shared
    private var quitSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        Log.info("Murmur launched")
        // A plain kill skips applicationWillTerminate and would leave the correction server running
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        quitSignal = source
        LLMService.killOrphanedServers()
        buildStatusItem()
        controller.$phase.sink { [weak self] phase in self?.updateIcon(phase) }.store(in: &subs)
        controller.launch()
        DictionaryBridge.listen()
        if AppSettings.shared.spokenCorrections { LLMService.shared.start() }
        AppSettings.shared.enableLoginItemOnFirstRun()

        let needsSetup = AVCaptureDevice.authorizationStatus(for: .audio) != .authorized || !AX.trusted || !ModelDownloader.shared.missing.isEmpty
        if needsSetup {
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            }
            showWindow(tab: .setup)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(tab: WindowRouter.shared.tab)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.saveBeforeQuit()
        controller.editWatcher.finish()
        LLMService.shared.stop()
        WhisperEngine.shared.unload()
        Log.info("Murmur quit")
        // C++ teardown in the Metal backend asserts at exit so skipping it avoids a crash report
        _exit(0)
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateIcon(.idle)
    }

    private func updateIcon(_ phase: DictationController.Phase) {
        let name: String
        switch phase {
        case .idle: name = "waveform"
        case .recording: name = "mic.fill"
        case .processing: name = "ellipsis"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Murmur")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let shortcut = AppSettings.shared.shortcut.display
        switch controller.phase {
        case .idle: menu.addItem(withTitle: "Start dictation (\(shortcut))", action: #selector(toggleDictation), keyEquivalent: "").target = self
        case .recording: menu.addItem(withTitle: "Stop dictation (\(shortcut))", action: #selector(toggleDictation), keyEquivalent: "").target = self
        case .processing: menu.addItem(withTitle: "Transcribing…", action: nil, keyEquivalent: "")
        }
        if !controller.hotkeyActive {
            let warn = menu.addItem(withTitle: "Shortcut is off until Accessibility is allowed", action: #selector(openSetup), keyEquivalent: "")
            warn.target = self
        }
        menu.addItem(.separator())

        let recent = HistoryStore.shared.items.filter { !$0.text.isEmpty }.prefix(5)
        if !recent.isEmpty {
            menu.addItem(withTitle: "Click to copy", action: nil, keyEquivalent: "").isEnabled = false
            for item in recent {
                let title = item.text.count > 60 ? String(item.text.prefix(60)) + "…" : item.text
                let mi = menu.addItem(withTitle: title, action: #selector(copyItem(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = item.text
                mi.toolTip = item.text
            }
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "History…", action: #selector(openHistory), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Dictionary…", action: #selector(openDictionary), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Setup…", action: #selector(openSetup), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Murmur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func toggleDictation() { controller.toggle() }
    @objc private func copyItem(_ sender: NSMenuItem) {
        if let text = sender.representedObject as? String { TextInserter.copy(text) }
    }
    @objc private func openHistory() { showWindow(tab: .history) }
    @objc private func openDictionary() { showWindow(tab: .dictionary) }
    @objc private func openSettings() { showWindow(tab: .settings) }
    @objc private func openSetup() { showWindow(tab: .setup) }

    // The app lives in the menu bar and only shows in the Dock while its window is open
    func showWindow(tab: MainTab) {
        WindowRouter.shared.tab = tab
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Murmur"
            w.contentViewController = NSHostingController(rootView: MainView())
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            w.setFrameAutosaveName("MurmurMain")
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
