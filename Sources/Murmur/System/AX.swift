import AppKit
import ApplicationServices

enum AX {
    static var trusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return err == .success ? value : nil
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    static func bool(_ element: AXUIElement, _ name: String) -> Bool? {
        if let n = attribute(element, name) as? NSNumber { return n.boolValue }
        return nil
    }

    static func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }

    static func selectedRange(_ element: AXUIElement) -> NSRange? {
        guard let raw = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    static func pid(_ element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    static func same(_ a: AXUIElement, _ b: AXUIElement) -> Bool { CFEqual(a, b) }

    private static var preparedPids = Set<pid_t>()

    private static let chromiumBundles: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.google.chrome.for.testing", "com.brave.Browser",
        "com.microsoft.edgemac", "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    // Electron and Chromium apps hide their text fields from accessibility until asked for them
    static func prepare(app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard !preparedPids.contains(pid) else { return }
        preparedPids.insert(pid)
        let isElectron = app.bundleURL.map {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
        } ?? false
        guard isElectron || chromiumBundles.contains(app.bundleIdentifier ?? "") else { return }
        let element = AXUIElementCreateApplication(pid)
        let result = AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        Log.info("AXManualAccessibility on \(app.bundleIdentifier ?? "?") result \(result.rawValue)")
    }
}

struct FocusInfo {
    enum Editable { case yes, no, unknown }

    var element: AXUIElement?
    var app: NSRunningApplication?
    var role = ""
    var editable: Editable = .unknown
    var secure = false
    var value: String?
    var selection: NSRange?

    var appName: String { app?.localizedName ?? "" }
    var bundleId: String { app?.bundleIdentifier ?? "" }

    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    private static let nonTextRoles: Set<String> = [
        "AXButton", "AXList", "AXOutline", "AXTable", "AXRow", "AXWindow", "AXImage", "AXStaticText", "AXScrollArea",
        "AXMenuItem", "AXMenuBar", "AXToolbar", "AXApplication", "AXBrowser", "AXSplitGroup", "AXLink", "AXCheckBox",
        "AXRadioButton", "AXPopUpButton", "AXSlider", "AXTabGroup", "AXDisclosureTriangle", "AXMenuButton", "AXCell",
    ]

    static func current() -> FocusInfo {
        var info = FocusInfo()
        info.app = NSWorkspace.shared.frontmostApplication
        if let app = info.app { AX.prepare(app: app) }
        guard AX.trusted else { return info }

        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        var focused: AnyObject?
        var err = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
        if err != .success, let app = info.app {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, 0.15)
            err = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused)
        }
        guard err == .success, let raw = focused, CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            // No focused element at all means there is nowhere to type
            info.editable = err == .noValue ? .no : .unknown
            return info
        }
        let element = raw as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.15)
        info.element = element
        info.role = AX.string(element, kAXRoleAttribute) ?? ""
        let subrole = AX.string(element, kAXSubroleAttribute) ?? ""
        info.secure = subrole == (kAXSecureTextFieldSubrole as String)

        if let editable = AX.bool(element, "AXEditable") {
            info.editable = editable ? .yes : .no
        } else if textRoles.contains(info.role) || info.secure {
            info.editable = .yes
        } else if AX.isSettable(element, kAXSelectedTextRangeAttribute) || AX.isSettable(element, kAXValueAttribute) && info.role != "AXSlider" {
            info.editable = .yes
        } else if nonTextRoles.contains(info.role) {
            info.editable = .no
        }
        if info.role == "AXTextArea" || info.role == "AXTextField", AX.bool(element, "AXEditable") == false {
            info.editable = .no
        }
        // Chromium marks tabs and buttons inside editable pages as editable so those become a guess that keeps the clipboard
        if info.editable == .yes, nonTextRoles.contains(info.role) {
            info.editable = .unknown
        }
        if !info.secure {
            info.value = AX.string(element, kAXValueAttribute)
            info.selection = AX.selectedRange(element)
        }
        return info
    }

    // Spaces are added only where the new text would otherwise glue onto a neighbouring word
    func spacing(for text: String) -> (leading: Bool, trailing: Bool)? {
        guard let value, let selection, selection.location != NSNotFound else { return nil }
        let ns = value as NSString
        guard selection.location <= ns.length else { return nil }
        var leading = false
        if selection.location > 0, let c = ns.substring(with: NSRange(location: selection.location - 1, length: 1)).unicodeScalars.first {
            let opener = "([{\"'“‘/".unicodeScalars.contains(c)
            let startsWithPunctuation = text.unicodeScalars.first.map { ".,!?;:)".unicodeScalars.contains($0) } ?? false
            leading = !CharacterSet.whitespacesAndNewlines.contains(c) && !opener && !startsWithPunctuation
        }
        var trailing = false
        let end = selection.location + selection.length
        if end < ns.length, let c = ns.substring(with: NSRange(location: end, length: 1)).unicodeScalars.first {
            trailing = !CharacterSet.whitespacesAndNewlines.contains(c) && !".,!?;:)]}\"'”’".unicodeScalars.contains(c)
        }
        return (leading, trailing)
    }
}
