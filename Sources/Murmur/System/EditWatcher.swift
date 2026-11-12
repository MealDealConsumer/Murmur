import AppKit
import ApplicationServices

/* After a paste the text field is read back once a second. The text either side of the paste acts as an
anchor so the edited span can be cut out later. The last good read is diffed when the field loses focus,
when sixty seconds pass or when the next dictation starts. */
final class EditWatcher {
    var onLearned: (([LearnedPair]) -> Void)?

    private var element: AXUIElement?
    private var original = ""
    private var before = ""
    private var after = ""
    private var lastSpan: String?
    private var timer: Timer?
    private var started = Date()
    private var unfocusedSince: Date?

    private static let anchorLength = 24
    private static let window: TimeInterval = 60

    func begin(outcome: InsertOutcome) {
        finish()
        guard let element = outcome.focus.element, !outcome.focus.secure else { return }
        let pasted = outcome.inserted.trimmingCharacters(in: .whitespaces)
        guard EditLearner.tokens(pasted).count >= 1 else { return }
        let previous = outcome.focus.value ?? ""
        // The paste lands asynchronously so the first read waits a moment
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            guard let now = AX.string(element, kAXValueAttribute), now.count < 200_000 else { return }
            guard let span = Self.locate(pasted: pasted, previous: previous, current: now) else {
                Log.info("edit watcher could not find the pasted text")
                return
            }
            let ns = now as NSString
            let beforeStart = max(0, span.location - Self.anchorLength)
            self.before = ns.substring(with: NSRange(location: beforeStart, length: span.location - beforeStart))
            let afterEnd = min(ns.length, NSMaxRange(span) + Self.anchorLength)
            self.after = ns.substring(with: NSRange(location: NSMaxRange(span), length: afterEnd - NSMaxRange(span)))
            self.element = element
            self.original = ns.substring(with: span)
            self.lastSpan = self.original
            self.started = Date()
            self.unfocusedSince = nil
            self.timer = commonTimer(1, repeats: true) { [weak self] _ in self?.poll() }
        }
    }

    static func locate(pasted: String, previous: String, current: String) -> NSRange? {
        let cur = current as NSString
        let prev = previous as NSString
        // What changed between the reads before and after the paste is the paste itself
        if !previous.isEmpty || cur.length > 0 {
            var start = 0
            let maxPrefix = min(prev.length, cur.length)
            while start < maxPrefix, prev.character(at: start) == cur.character(at: start) { start += 1 }
            var tail = 0
            while tail < prev.length - start, tail < cur.length - start,
                  prev.character(at: prev.length - 1 - tail) == cur.character(at: cur.length - 1 - tail) { tail += 1 }
            let length = cur.length - start - tail
            if length > 0 {
                let candidate = NSRange(location: start, length: length)
                let text = cur.substring(with: candidate).trimmingCharacters(in: .whitespaces)
                if Replacer.key(text) == Replacer.key(pasted) {
                    let lead = cur.substring(with: candidate).prefix { $0 == " " }.count
                    return NSRange(location: start + lead, length: (text as NSString).length)
                }
            }
        }
        let found = cur.range(of: pasted, options: .backwards)
        return found.location == NSNotFound ? nil : found
    }

    private func poll() {
        guard let element else { return finish() }
        if Date().timeIntervalSince(started) > Self.window { return finish() }
        var focused: AnyObject?
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        if AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
           let raw = focused, CFGetTypeID(raw) == AXUIElementGetTypeID(), AX.same(raw as! AXUIElement, element) {
            unfocusedSince = nil
        } else if unfocusedSince == nil {
            unfocusedSince = Date()
        }
        guard let value = AX.string(element, kAXValueAttribute) else { return finish() }
        // An emptied field means the message was sent so the last read is final and nothing typed next can leak in
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return finish() }
        if let span = span(in: value) { lastSpan = span }
        // Leaving the field for a couple of seconds counts as being done with it
        if let since = unfocusedSince, Date().timeIntervalSince(since) > 2 { finish() }
    }

    private func span(in value: String) -> String? {
        let ns = value as NSString
        let startRange = before.isEmpty ? NSRange(location: 0, length: 0) : ns.range(of: before)
        guard startRange.location != NSNotFound else { return nil }
        if !before.isEmpty, ns.range(of: before, options: .backwards).location != startRange.location { return nil }
        let from = NSMaxRange(startRange)
        let endRange: NSRange
        if after.isEmpty {
            endRange = NSRange(location: ns.length, length: 0)
        } else {
            endRange = ns.range(of: after, options: [], range: NSRange(location: from, length: ns.length - from))
        }
        guard endRange.location != NSNotFound, endRange.location >= from else { return nil }
        let span = ns.substring(with: NSRange(location: from, length: endRange.location - from))
        // An emptied field means the message was sent and the previous read is the final one
        return span.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : span
    }

    func finish() {
        timer?.invalidate()
        timer = nil
        defer {
            element = nil
            lastSpan = nil
        }
        guard element != nil, let edited = lastSpan, edited != original else { return }
        let pairs = EditLearner.corrections(original: original, edited: edited)
        Log.info("edit watcher saw an edit and found \(pairs.count) corrections")
        if !pairs.isEmpty { onLearned?(pairs) }
    }
}
