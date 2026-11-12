import AppKit
import ApplicationServices

/* Looks for dictated text after a paste. Chromium apps such as VS Code often report a tab or the whole page as
focused and update their tree late, so besides the original target this reads whatever is focused now and then
searches the front window for a text field holding the text. */
enum PasteCheck {
    struct Result {
        var landed: Bool
        // A text field could be read and did not hold the text
        var readable: Bool
        var detail: String
    }

    static let queue = DispatchQueue(label: "murmur.pastecheck", qos: .userInitiated)

    private static let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"]
    private static let maxNodes = 6000
    private static let searchBudget: TimeInterval = 0.4

    // The start and the end of the text so an app that tidies one edge of a paste still matches
    static func probes(for text: String) -> [String] {
        let key = Replacer.key(text)
        guard !key.isEmpty else { return [] }
        let n = min(32, key.count)
        return key.count > n ? [String(key.prefix(n)), String(key.suffix(n))] : [key]
    }

    static func check(text: String, original: AXUIElement?, pid: pid_t?) -> Result {
        let probes = probes(for: text)
        guard !probes.isEmpty else { return Result(landed: true, readable: false, detail: "nothing to find") }
        func holds(_ value: String) -> Bool {
            guard value.utf16.count < 300_000 else { return false }
            let key = Replacer.key(value)
            return probes.contains { key.contains($0) }
        }
        var readable = false
        var roles: [String] = []
        for element in [original, focusedElement(pid: pid)].compactMap({ $0 }) {
            AXUIElementSetMessagingTimeout(element, 0.15)
            let role = AX.string(element, kAXRoleAttribute) ?? ""
            roles.append(role)
            guard let value = AX.string(element, kAXValueAttribute) else { continue }
            if holds(value) { return Result(landed: true, readable: true, detail: role) }
            if textRoles.contains(role) { readable = true }
        }
        if let pid {
            let search = searchWindow(pid: pid, holds: holds)
            if search.found { return Result(landed: true, readable: true, detail: "window search") }
            roles.append("searched \(search.visited)")
        }
        return Result(landed: false, readable: readable, detail: roles.joined(separator: " "))
    }

    private static func focusedElement(pid: pid_t?) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        if let raw = AX.attribute(system, kAXFocusedUIElementAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() {
            return (raw as! AXUIElement)
        }
        guard let pid else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        if let raw = AX.attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() {
            return (raw as! AXUIElement)
        }
        return nil
    }

    private static func searchWindow(pid: pid_t, holds: (String) -> Bool) -> (found: Bool, visited: Int) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        guard let raw = AX.attribute(app, kAXFocusedWindowAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return (false, 0) }
        var stack = [raw as! AXUIElement]
        var visited = 0
        let deadline = Date().addingTimeInterval(searchBudget)
        while let element = stack.popLast(), visited < maxNodes, Date() < deadline {
            visited += 1
            AXUIElementSetMessagingTimeout(element, 0.15)
            let role = AX.string(element, kAXRoleAttribute) ?? ""
            if textRoles.contains(role) {
                if let value = AX.string(element, kAXValueAttribute), holds(value) { return (true, visited) }
                continue
            }
            if let children = AX.attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                stack.append(contentsOf: children.reversed())
            }
        }
        return (false, visited)
    }
}
