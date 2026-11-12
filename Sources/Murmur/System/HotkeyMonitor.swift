import AppKit
import CoreGraphics

/* One session event tap watches the trigger key. A modifier key only counts as a press when nothing
else was touched while it was down so fn+arrow and fn+F keys keep working as normal. */
final class HotkeyMonitor {
    enum Event { case down, up(interrupted: Bool), interrupted, space }

    var onEvent: ((Event) -> Void)?
    var onEscape: (() -> Void)?
    var onPasteLast: (() -> Void)?
    var shortcut: Shortcut = .fn {
        didSet { triggerDown = false; interrupted = false }
    }
    var paused = false
    // Read from the tap thread so Escape is only swallowed while a recording is live
    var escapeActive = false
    // Space held with the trigger means hands free and is swallowed so no space gets typed
    var spaceLatches = true
    var onCommandV: (() -> Void)?
    private var swallowSpaceUp = false

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var triggerDown = false
    private var interrupted = false
    private var healthTimer: Timer?

    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    @discardableResult
    func start() -> Bool {
        if tap != nil { return isRunning }
        var mask: CGEventMask = 0
        for type in [CGEventType.flagsChanged, .keyDown, .keyUp] { mask |= CGEventMask(1) << type.rawValue }
        mask |= CGEventMask(1) << 14
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: hotkeyTapCallback, userInfo: refcon) else {
            Log.info("event tap could not be created")
            return false
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        // macOS silently disables slow taps so a slow check turns it back on
        healthTimer = commonTimer(10, repeats: true) { [weak self] _ in
            guard let self, let tap = self.tap, !CGEvent.tapIsEnabled(tap: tap) else { return }
            Log.info("event tap was disabled so re-enabling")
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        Log.info("event tap started")
        return true
    }

    func stop() {
        healthTimer?.invalidate()
        healthTimer = nil
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if paused { return Unmanaged.passUnretained(event) }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        if type == .keyDown, keyCode == 9, Self.comboMatches(event.flags, CGEventFlags.maskCommand.rawValue | CGEventFlags.maskControl.rawValue) {
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { DispatchQueue.main.async { self.onPasteLast?() } }
            return nil
        }
        if type == .keyDown, keyCode == 9, Self.comboMatches(event.flags, CGEventFlags.maskCommand.rawValue) {
            DispatchQueue.main.async { self.onCommandV?() }
        }
        if type == .keyDown, keyCode == 53, escapeActive, !triggerDown {
            DispatchQueue.main.async { self.onEscape?() }
            return nil
        }

        switch shortcut.kind {
        case .modifier:
            if type == .flagsChanged, keyCode == shortcut.keyCode {
                let down = Self.isDown(keyCode: keyCode, flags: event.flags)
                if down, !triggerDown {
                    triggerDown = true
                    interrupted = false
                    fire(.down)
                } else if !down, triggerDown {
                    triggerDown = false
                    fire(.up(interrupted: interrupted))
                }
                return Unmanaged.passUnretained(event)
            }
            if spaceLatches, keyCode == 49, type == .keyDown, triggerDown {
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { fire(.space) }
                swallowSpaceUp = true
                return nil
            }
            if keyCode == 49, type == .keyUp, swallowSpaceUp {
                swallowSpaceUp = false
                return nil
            }
            if triggerDown, !interrupted, type == .keyDown || type == .flagsChanged || type.rawValue == 14 {
                interrupted = true
                fire(.interrupted)
            }
        case .combo:
            if type == .keyDown, keyCode == shortcut.keyCode, Self.comboMatches(event.flags, shortcut.modifiers) {
                if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
                triggerDown = true
                fire(.down)
                return nil
            }
            if type == .keyUp, keyCode == shortcut.keyCode, triggerDown {
                triggerDown = false
                fire(.up(interrupted: false))
                return nil
            }
        }
        return Unmanaged.passUnretained(event)
    }

    private func fire(_ e: Event) {
        DispatchQueue.main.async { self.onEvent?(e) }
    }

    static let comboMask: UInt64 = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue
        | CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue

    static func comboMatches(_ flags: CGEventFlags, _ wanted: UInt64) -> Bool {
        flags.rawValue & comboMask == wanted & comboMask
    }

    // Device dependent bits tell the left and right copies of a modifier apart
    static func isDown(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        let raw = flags.rawValue
        switch keyCode {
        case 63: return flags.contains(.maskSecondaryFn)
        case 54: return raw & 0x10 != 0
        case 55: return raw & 0x08 != 0
        case 61: return raw & 0x40 != 0
        case 58: return raw & 0x20 != 0
        case 62: return raw & 0x2000 != 0
        case 59: return raw & 0x01 != 0
        case 60: return raw & 0x04 != 0
        case 56: return raw & 0x02 != 0
        default: return false
        }
    }

    static func modifierName(_ keyCode: UInt16) -> String? {
        switch keyCode {
        case 63: return "fn (Globe)"
        case 54: return "Right Command ⌘"
        case 55: return "Left Command ⌘"
        case 61: return "Right Option ⌥"
        case 58: return "Left Option ⌥"
        case 62: return "Right Control ⌃"
        case 59: return "Left Control ⌃"
        case 60: return "Right Shift ⇧"
        case 56: return "Left Shift ⇧"
        default: return nil
        }
    }
}

private func hotkeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    return monitor.handle(type: type, event: event)
}
