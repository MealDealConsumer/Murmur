import Combine
import Foundation
import ServiceManagement

struct Shortcut: Codable, Equatable, Hashable {
    enum Kind: String, Codable { case modifier, combo }
    var kind: Kind
    var keyCode: UInt16
    var modifiers: UInt64
    var display: String

    static let fn = Shortcut(kind: .modifier, keyCode: 63, modifiers: 0, display: "fn (Globe)")
    static let presets: [Shortcut] = [
        .fn,
        Shortcut(kind: .modifier, keyCode: 61, modifiers: 0, display: "Right Option ⌥"),
        Shortcut(kind: .modifier, keyCode: 54, modifiers: 0, display: "Right Command ⌘"),
        Shortcut(kind: .modifier, keyCode: 62, modifiers: 0, display: "Right Control ⌃"),
        Shortcut(kind: .modifier, keyCode: 60, modifiers: 0, display: "Right Shift ⇧"),
    ]
}

enum TriggerMode: String, Codable, CaseIterable, Identifiable {
    case holdHandsFree, toggle, hold
    var id: String { rawValue }
    var label: String {
        switch self {
        case .holdHandsFree: return "Hold to talk, add Space for hands free"
        case .toggle: return "Press to start, press again to stop"
        case .hold: return "Hold to talk only"
        }
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var shortcut: Shortcut { didSet { store(shortcut, "shortcut") } }
    @Published var mode: TriggerMode { didSet { defaults.set(mode.rawValue, forKey: "mode") } }
    @Published var showIdlePill: Bool { didSet { defaults.set(showIdlePill, forKey: "showIdlePill") } }
    @Published var spokenCorrections: Bool { didSet { defaults.set(spokenCorrections, forKey: "spokenCorrections") } }
    @Published var learnFromEdits: Bool { didSet { defaults.set(learnFromEdits, forKey: "learnFromEdits") } }
    @Published var playSounds: Bool { didSet { defaults.set(playSounds, forKey: "playSounds") } }
    @Published var language: String { didSet { defaults.set(language, forKey: "language") } }
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            applyLoginItem()
        }
    }

    private init() {
        defaults.register(defaults: [
            "mode": TriggerMode.holdHandsFree.rawValue,
            "showIdlePill": true,
            "spokenCorrections": true,
            "learnFromEdits": true,
            "playSounds": false,
            "language": "en",
        ])
        if let data = defaults.data(forKey: "shortcut"), let s = try? JSONDecoder().decode(Shortcut.self, from: data) {
            shortcut = s
        } else {
            shortcut = .fn
        }
        mode = TriggerMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .holdHandsFree
        showIdlePill = defaults.bool(forKey: "showIdlePill")
        spokenCorrections = defaults.bool(forKey: "spokenCorrections")
        learnFromEdits = defaults.bool(forKey: "learnFromEdits")
        playSounds = defaults.bool(forKey: "playSounds")
        language = defaults.string(forKey: "language") ?? "en"
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func store<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private func applyLoginItem() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.info("login item change failed \(error)")
        }
    }

    // First run turns this on once so a reboot never leaves dictation off
    func enableLoginItemOnFirstRun() {
        guard !defaults.bool(forKey: "didOfferLoginItem") else { return }
        defaults.set(true, forKey: "didOfferLoginItem")
        if SMAppService.mainApp.status != .enabled { launchAtLogin = true }
    }
}
