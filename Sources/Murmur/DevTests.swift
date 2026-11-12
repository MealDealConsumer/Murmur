import AppKit
import ApplicationServices
import AVFoundation

// Live checks against a real app window, run only from the command line with TextEdit in front
enum DevTests {
    static func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    static func liveTest() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let front = NSWorkspace.shared.frontmostApplication
        guard front?.bundleIdentifier == "com.apple.TextEdit" else {
            print("ABORT frontmost app is \(front?.bundleIdentifier ?? "none") not TextEdit")
            return
        }
        let userClipboard = TextInserter.snapshot()
        defer { TextInserter.restore(userClipboard) }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("CLIPBOARD-BEFORE", forType: .string)

        let focus = FocusInfo.current()
        print("focus role=\(focus.role) editable=\(focus.editable) value=\(focus.value.map { "\"\($0)\"" } ?? "nil") selection=\(String(describing: focus.selection))")

        var outcome: InsertOutcome?
        TextInserter.insert("We should play deep-woken tonight.") { outcome = $0 }
        spin(0.6)
        guard let outcome, let element = outcome.focus.element else { print("FAIL no outcome"); return }
        print("outcome=\(outcome.kind) inserted=\"\(outcome.inserted)\"")
        print("field after paste=\"\(AX.string(element, kAXValueAttribute) ?? "nil")\"")
        spin(1.7)
        print("clipboard restored=\(NSPasteboard.general.string(forType: .string) == "CLIPBOARD-BEFORE")")

        let watcher = EditWatcher()
        var learned: [LearnedPair] = []
        watcher.onLearned = { learned = $0 }
        watcher.begin(outcome: outcome)
        spin(1.0)
        // Stand in for a hand edit by selecting the word and replacing it through accessibility
        let value = AX.string(element, kAXValueAttribute) ?? ""
        let r = (value as NSString).range(of: "deep-woken")
        if r.location != NSNotFound {
            var cf = CFRange(location: r.location, length: r.length)
            if let axRange = AXValueCreate(.cfRange, &cf) {
                AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange)
                let err = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, "Deepwoken" as CFString)
                print("simulated edit result=\(err.rawValue)")
            }
        }
        spin(2.2)
        print("field after edit=\"\(AX.string(element, kAXValueAttribute) ?? "nil")\"")
        watcher.finish()
        print("learned=\(learned.map { "\($0.heard) -> \($0.correct)" })")

        hotkeyTest()
        micTest()
    }

    static func endToEnd(_ path: String) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.TextEdit" else {
            print("ABORT TextEdit is not frontmost")
            return
        }
        guard let samples = try? WavIO.read16kMono(URL(fileURLWithPath: path)) else { print("cannot read \(path)"); return }
        let userClipboard = TextInserter.snapshot()
        defer { TextInserter.restore(userClipboard) }
        let controller = DictationController.shared
        _ = WhisperEngine.shared.loadIfNeeded()
        LLMService.shared.start()
        let start = Date()
        var stopAt: Date?
        var finished = false
        // One second of audio every twentieth of a second is twenty times real time which whisper keeps up with
        controller.runInjected(samples, secondsPerTick: 1) { finished = true }
        while !finished {
            if stopAt == nil, controller.phase == .processing { stopAt = Date() }
            spin(0.05)
            if Date().timeIntervalSince(start) > 300 { print("TIMEOUT"); break }
        }
        let latency = stopAt.map { Date().timeIntervalSince($0) } ?? -1
        spin(0.8)
        let item = HistoryStore.shared.items.first
        print("audio=\(String(format: "%.1f", Double(samples.count) / 16000))s stop-to-paste=\(String(format: "%.2f", latency))s outcome=\(item?.outcome.rawValue ?? "none") app=\(item?.appName ?? "")")
        print("text=\(item?.text ?? "")")
        let focus = FocusInfo.current()
        print("field=\(focus.value ?? "nil")")
    }

    /* Plays a long file through the real controller with the keystroke blocked and the chime muted. Prints when each
    warning fired, where it stopped, whether anything tried to paste and whether the clipboard came back untouched. */
    static func limitTest(_ path: String) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        guard ProcessInfo.processInfo.environment["MURMUR_DATA_DIR"] != nil else { print("ABORT set MURMUR_DATA_DIR"); return }
        guard let samples = try? WavIO.read16kMono(URL(fileURLWithPath: path)) else { print("cannot read \(path)"); return }
        let userClipboard = TextInserter.snapshot()
        defer { TextInserter.restore(userClipboard) }
        TextInserter.blockPaste = true
        let controller = DictationController.shared
        controller.muteChime = true
        _ = WhisperEngine.shared.loadIfNeeded()
        func run(_ clip: [Float], label: String) {
            var chimeTimes: [Int] = []
            var finished = false
            let pastesBefore = TextInserter.blockedPastes
            let chimesBefore = controller.chimes
            let marker = "CLIPBOARD-BEFORE-\(label)"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(marker, forType: .string)
            let start = Date()
            controller.runInjected(clip, secondsPerTick: 2) { finished = true }
            while !finished {
                if controller.chimes - chimesBefore > chimeTimes.count, controller.phase == .recording { chimeTimes.append(Int(controller.elapsed)) }
                spin(0.02)
                if Date().timeIntervalSince(start) > 900 { print("TIMEOUT"); break }
            }
            // The paste puts the old clipboard back two seconds later when nothing confirms it landed
            spin(2.5)
            let item = HistoryStore.shared.items.first
            let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
            print("\(label): file=\(clip.count / 16000)s chimes at \(chimeTimes)s stopped at \(String(format: "%.0f", item?.duration ?? -1))s "
                + "outcome=\(item?.outcome.rawValue ?? "none") paste attempts=\(TextInserter.blockedPastes - pastesBefore) "
                + "clipboard untouched=\(clipboard == marker) took \(String(format: "%.0f", Date().timeIntervalSince(start)))s")
            print("text=\(item?.text ?? "")")
        }
        run(samples, label: "LIMIT")
        run(Array(samples.prefix(16000 * 20)), label: "SHORT")
        // A paste that is seen in the field gives the clipboard back at once instead of waiting
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("CLIPBOARD-BEFORE-LANDED", forType: .string)
        var landed: InsertOutcome?
        TextInserter.insert("A short line that landed.") { landed = $0 }
        spin(0.1)
        let during = NSPasteboard.general.string(forType: .string) ?? ""
        if let landed { TextInserter.pasteLanded(landed.token) }
        let after = NSPasteboard.general.string(forType: .string) ?? ""
        print("LANDED: text on clipboard while pasting=\(during.hasPrefix("A short line")) put back at once=\(after == "CLIPBOARD-BEFORE-LANDED")")
    }

    // Right Option stands in for fn so nothing else listening to fn wakes up
    static func hotkeyTest() {
        let monitor = HotkeyMonitor()
        monitor.shortcut = Shortcut(kind: .modifier, keyCode: 61, modifiers: 0, display: "Right Option")
        var events: [String] = []
        monitor.onEvent = { e in
            switch e {
            case .down: events.append("down")
            case .up(let i): events.append(i ? "up-interrupted" : "up")
            case .interrupted: events.append("interrupted")
            case .space: events.append("space")
            }
        }
        guard monitor.start() else { print("hotkey tap FAILED to start"); return }
        let src = CGEventSource(stateID: .privateState)
        func modifier(_ down: Bool) {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 61, keyDown: down)
            e?.type = .flagsChanged
            e?.flags = down ? CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40) : []
            e?.post(tap: .cghidEventTap)
        }
        modifier(true); spin(0.15); modifier(false); spin(0.3)
        // A shift press while held is a chord and must not count as a tap
        modifier(true); spin(0.1)
        let shift = CGEvent(keyboardEventSource: src, virtualKey: 56, keyDown: true)
        shift?.type = .flagsChanged
        shift?.flags = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40 | CGEventFlags.maskShift.rawValue | 0x02)
        shift?.post(tap: .cghidEventTap)
        spin(0.1)
        let shiftUp = CGEvent(keyboardEventSource: src, virtualKey: 56, keyDown: false)
        shiftUp?.type = .flagsChanged
        shiftUp?.flags = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)
        shiftUp?.post(tap: .cghidEventTap)
        spin(0.1)
        modifier(false); spin(0.4)
        // Space while held latches hands free and must never reach the app as a typed space
        let before = FocusInfo.current().value ?? ""
        modifier(true); spin(0.1)
        CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: true)?.post(tap: .cghidEventTap)
        spin(0.05)
        CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: false)?.post(tap: .cghidEventTap)
        spin(0.1)
        modifier(false); spin(0.4)
        let after = FocusInfo.current().value ?? ""
        monitor.stop()
        print("hotkey events=\(events)")
        print("space swallowed=\(before == after)")
    }

    // Three seconds of microphone level only and nothing is saved or transcribed
    static func micTest() {
        let recorder = AudioRecorder()
        var levels: [Float] = []
        recorder.onLevel = { levels.append($0) }
        do {
            try recorder.start()
        } catch {
            print("mic FAILED \(error.localizedDescription)")
            return
        }
        spin(3)
        let samples = recorder.stop()
        let peak = levels.max() ?? 0
        print("mic device=\(recorder.deviceName) samples=\(samples.count) (\(String(format: "%.2f", Double(samples.count) / 16000))s) level callbacks=\(levels.count) peak dBFS=\(String(format: "%.0f", 20 * log10(max(peak, 1e-6))))")
    }
}
