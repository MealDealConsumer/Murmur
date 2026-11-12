import AppKit
import AVFoundation
import SwiftUI

enum MainTab: String, CaseIterable, Identifiable {
    case history, dictionary, snippets, settings, setup
    var id: String { rawValue }
    var title: String {
        switch self {
        case .history: return "History"
        case .dictionary: return "Dictionary"
        case .settings: return "Settings"
        case .snippets: return "Snippets"
        case .setup: return "Setup"
        }
    }
    var symbol: String {
        switch self {
        case .history: return "clock"
        case .dictionary: return "text.book.closed"
        case .settings: return "gearshape"
        case .snippets: return "text.bubble"
        case .setup: return "checklist"
        }
    }
}

final class WindowRouter: ObservableObject {
    static let shared = WindowRouter()
    @Published var tab: MainTab = .history
}

struct MainView: View {
    @ObservedObject var router = WindowRouter.shared

    var body: some View {
        NavigationSplitView {
            List(MainTab.allCases, selection: Binding(get: { router.tab }, set: { if let t = $0 { router.tab = t } })) { tab in
                Label(tab.title, systemImage: tab.symbol).tag(tab)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 160, max: 200)
        } detail: {
            switch router.tab {
            case .history: HistoryView()
            case .dictionary: DictionaryView()
            case .snippets: SnippetsView()
            case .settings: SettingsView()
            case .setup: SetupView()
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

// MARK: History

struct HistoryView: View {
    @ObservedObject var store = HistoryStore.shared
    @State private var query = ""
    @State private var copied: UUID?

    // Words this week and speaking pace measured over recordings long enough to count
    private var stats: String {
        let weekAgo = Date().addingTimeInterval(-7 * 86400)
        let week = store.items.filter { $0.date > weekAgo }.reduce(0) { $0 + $1.text.split(separator: " ").count }
        let timed = store.items.filter { $0.duration > 3 && !$0.text.isEmpty }
        let words = timed.reduce(0) { $0 + $1.text.split(separator: " ").count }
        let minutes = timed.reduce(0.0) { $0 + $1.duration } / 60
        let pace = minutes > 0 ? Int(Double(words) / minutes) : 0
        return "\(week) words this week · \(pace) words a minute"
    }

    private var filtered: [HistoryItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? store.items : store.items.filter { $0.text.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("History").font(.title2.weight(.semibold))
                Spacer()
                TextField("Search", text: $query).textFieldStyle(.roundedBorder).frame(width: 220)
            }
            .padding(16)
            HStack {
                Text("Click anything to copy it. Control Command V pastes the latest one again.")
                Spacer()
                Text(stats)
            }
            .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 8)
            if filtered.isEmpty {
                Spacer()
                Text(store.items.isEmpty ? "Nothing yet. Press your shortcut and start talking." : "No matches.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                List {
                    ForEach(filtered) { item in
                        HistoryRow(item: item, copied: copied == item.id) {
                            guard !item.text.isEmpty else { return }
                            TextInserter.copy(item.text)
                            copied = item.id
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if copied == item.id { copied = nil } }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct HistoryRow: View {
    let item: HistoryItem
    let copied: Bool
    let onCopy: () -> Void
    @State private var expanded = false

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.text.isEmpty ? (item.outcome == .cancelled ? "Cancelled recording, the audio is kept" : item.outcome == .failed ? "Not transcribed yet, the audio is kept" : "Nothing was heard in this recording") : item.text)
                .font(.body)
                .foregroundStyle(item.text.isEmpty ? .secondary : .primary)
                .lineLimit(expanded ? nil : 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                Text(meta).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if copied { Text("Copied").font(.caption.weight(.semibold)).foregroundStyle(.green) }
                if item.text.count > 280 {
                    Button(expanded ? "Less" : "More") { expanded.toggle() }.buttonStyle(.borderless).font(.caption)
                }
                if !item.raw.isEmpty, item.raw != item.text {
                    Button("Copy original") { TextInserter.copy(item.raw) }.buttonStyle(.borderless).font(.caption)
                        .help("Copy what was heard before any cleanup")
                }
                if HistoryStore.shared.audioURL(item) != nil {
                    Button("Transcribe again") { DictationController.shared.retry(item) }.buttonStyle(.borderless).font(.caption)
                }
                Button {
                    HistoryStore.shared.delete([item.id])
                } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Delete")
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onCopy)
    }

    private var meta: String {
        var parts = [Self.formatter.string(from: item.date)]
        if !item.appName.isEmpty { parts.append(item.appName) }
        parts.append(String(format: item.duration >= 60 ? "%.0f min" : "%.0f s", item.duration >= 60 ? item.duration / 60 : item.duration))
        switch item.outcome {
        case .pasted: parts.append("pasted")
        case .notPasted: parts.append("not pasted")
        case .empty: parts.append("no speech")
        case .failed: parts.append("needs another try")
        case .cancelled: parts.append("cancelled")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: Dictionary

struct DictionaryView: View {
    @ObservedObject var store = VocabularyStore.shared
    @State private var term = ""
    @State private var heard = ""
    @State private var query = ""

    private var filtered: [VocabEntry] {
        let q = query.lowercased()
        // Personal and learned words lead newest first and the imported block follows alphabetically
        let personal = store.entries.filter { $0.source != .imported }.sorted { $0.addedAt > $1.addedAt }
        let imported = store.entries.filter { $0.source == .imported }.sorted { $0.term.lowercased() < $1.term.lowercased() }
        let list = personal + imported
        return q.isEmpty ? list : list.filter { $0.term.lowercased().contains(q) || $0.heardAs.joined(separator: " ").lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Dictionary").font(.title2.weight(.semibold))
                Text("\(store.entries.count) words").foregroundStyle(.secondary)
                Spacer()
                TextField("Search", text: $query).textFieldStyle(.roundedBorder).frame(width: 220)
            }
            .padding(16)
            HStack(spacing: 8) {
                TextField("Correct spelling, like Deepwoken", text: $term).textFieldStyle(.roundedBorder)
                TextField("Often heard as, comma separated (optional)", text: $heard).textFieldStyle(.roundedBorder)
                Button("Add") {
                    let variants = heard.split(separator: ",").map { String($0) }
                    store.add(term: term, heardAs: variants, source: .manual)
                    term = ""
                    heard = ""
                }
                .disabled(term.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            List {
                ForEach(filtered) { entry in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.term).font(.body.weight(.medium))
                            if !entry.heardAs.isEmpty {
                                Text("heard as " + entry.heardAs.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer()
                        Text(entry.source.label).font(.caption).foregroundStyle(entry.source == .learnedEdit || entry.source == .learnedVoice ? .blue : .secondary)
                        Button {
                            store.remove(ids: [entry.id])
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Remove")
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.inset)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: Snippets

struct SnippetsView: View {
    @ObservedObject var store = SnippetStore.shared
    @State private var trigger = ""
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Snippets").font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(16)
            Text("Say the phrase while dictating and the saved text goes in its place.")
                .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 8)
            HStack(alignment: .top, spacing: 8) {
                TextField("When I say, like my email", text: $trigger).textFieldStyle(.roundedBorder).frame(width: 220)
                TextField("Put in this text", text: $text, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...4)
                Button("Add") {
                    store.add(trigger: trigger, text: text)
                    trigger = ""
                    text = ""
                }
                .disabled(trigger.trimmingCharacters(in: .whitespaces).isEmpty || text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            if store.items.isEmpty {
                Spacer()
                Text("No snippets yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                List {
                    ForEach(store.items) { s in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.trigger).font(.body.weight(.medium))
                                Text(s.text).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }
                            Spacer()
                            Button {
                                store.remove(s.id)
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Remove")
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: Settings

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Form {
            Section("Shortcut") {
                Picker("Key", selection: Binding(get: { settings.shortcut }, set: { settings.shortcut = $0 })) {
                    ForEach(Shortcut.presets, id: \.self) { s in Text(s.display).tag(s) }
                    if !Shortcut.presets.contains(settings.shortcut) {
                        Text(settings.shortcut.display).tag(settings.shortcut)
                    }
                }
                HStack {
                    Text(recording ? "Press the key or key combination you want, Esc to cancel" : "Or record any key combination")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(recording ? "Cancel" : "Record shortcut") { recording ? stopRecording() : startRecording() }
                }
                Picker("Behaviour", selection: $settings.mode) {
                    ForEach(TriggerMode.allCases) { m in Text(m.label).tag(m) }
                }
                Text("Esc cancels a recording. Recordings stop by themselves after 20 minutes with a chime at five and one minute left. That text is not pasted, it waits in the card and in History.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Text") {
                Toggle("Apply spoken fixes like \"that's one word\" or \"scratch that\"", isOn: $settings.spokenCorrections)
                Toggle("Learn words when I correct pasted text", isOn: $settings.learnFromEdits)
                Picker("Language", selection: $settings.language) {
                    Text("English").tag("en")
                    Text("Detect automatically").tag("auto")
                }
            }
            Section("App") {
                Toggle("Play a sound when listening starts and stops", isOn: $settings.playSounds)
                Toggle("Show the small bar at the bottom of the screen when idle", isOn: $settings.showIdlePill)
                Toggle("Open at login", isOn: $settings.launchAtLogin)
                HStack {
                    Button("Open data folder") { NSWorkspace.shared.open(Paths.appSupport) }
                    Button("Open logs") { NSWorkspace.shared.open(Paths.logs) }
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        recording = true
        DictationController.shared.hotkeys.paused = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .keyDown, event.keyCode == 53 {
                stopRecording()
                return nil
            }
            if event.type == .flagsChanged, let name = HotkeyMonitor.modifierName(event.keyCode) {
                let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
                if HotkeyMonitor.isDown(keyCode: event.keyCode, flags: flags) {
                    settings.shortcut = Shortcut(kind: .modifier, keyCode: event.keyCode, modifiers: 0, display: name)
                    stopRecording()
                }
                return nil
            }
            if event.type == .keyDown {
                let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
                guard !mods.isEmpty || (event.keyCode >= 96 && event.keyCode <= 122) else { return nil }
                var label = ""
                if mods.contains(.control) { label += "⌃" }
                if mods.contains(.option) { label += "⌥" }
                if mods.contains(.shift) { label += "⇧" }
                if mods.contains(.command) { label += "⌘" }
                let key = event.keyCode == 49 ? "Space" : (event.charactersIgnoringModifiers ?? "?").uppercased()
                var cg: UInt64 = 0
                if mods.contains(.command) { cg |= CGEventFlags.maskCommand.rawValue }
                if mods.contains(.option) { cg |= CGEventFlags.maskAlternate.rawValue }
                if mods.contains(.control) { cg |= CGEventFlags.maskControl.rawValue }
                if mods.contains(.shift) { cg |= CGEventFlags.maskShift.rawValue }
                settings.shortcut = Shortcut(kind: .combo, keyCode: event.keyCode, modifiers: cg, display: label + key)
                stopRecording()
                return nil
            }
            return event
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        DictationController.shared.hotkeys.paused = false
    }
}

// MARK: Setup

final class SetupModel: ObservableObject {
    @Published var mic = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published var accessibility = AX.trusted
    @Published var hotkeyActive = false
    @Published var wisprRunning = false
    @Published var llmState = LLMService.shared.state
    private var timer: Timer?

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() { timer?.invalidate() }

    func refresh() {
        mic = AVCaptureDevice.authorizationStatus(for: .audio)
        accessibility = AX.trusted
        hotkeyActive = DictationController.shared.hotkeyActive
        wisprRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.electron.wispr-flow" }
        llmState = LLMService.shared.state
    }
}

struct SetupView: View {
    @StateObject private var model = SetupModel()
    @ObservedObject private var downloader = ModelDownloader.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Permissions") {
                row("Microphone", ok: model.mic == .authorized,
                    detail: model.mic == .authorized ? "Allowed" : "Needed to hear you") {
                    if model.mic == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else {
                        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                    }
                }
                row("Accessibility", ok: model.accessibility,
                    detail: model.accessibility ? "Allowed" : "Needed for the shortcut and for pasting") {
                    AX.requestTrust()
                    open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                }
                row("Shortcut", ok: model.hotkeyActive,
                    detail: model.hotkeyActive ? "Listening for \(settings.shortcut.display)" : "Starts once Accessibility is allowed", action: nil)
            }
            Section("Models") {
                ForEach(ModelCatalog.all, id: \.fileName) { m in
                    row(m.label, ok: downloader.isPresent(m),
                        detail: downloader.isPresent(m) ? "Downloaded" : String(format: "Missing, %.1f GB", Double(m.approxBytes) / 1e9), action: nil)
                }
                if let active = downloader.active {
                    ProgressView(value: downloader.progress) { Text("Downloading \(active)") }
                } else if !downloader.missing.isEmpty {
                    Button("Download missing models") { downloader.downloadMissing() }
                }
                if let error = downloader.error { Text(error).foregroundStyle(.red) }
                HStack {
                    Text("Correction model")
                    Spacer()
                    Text(llmLabel).foregroundStyle(.secondary)
                }
            }
            Section("Good to know") {
                if model.wisprRunning {
                    Label("Wispr Flow is running and also listens to fn. Quit it so both apps do not fire at once.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Text("If pressing fn opens the emoji picker or switches keyboard, go to System Settings, Keyboard, and set \"Press 🌐 key to\" to Do Nothing.")
                Button("Open Keyboard settings") { open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension") }
                Text("Everything runs on this Mac. Audio and text never leave it.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var llmLabel: String {
        switch model.llmState {
        case .ready: return "Running"
        case .starting: return "Starting"
        case .stopped: return settings.spokenCorrections ? "Stopped" : "Off"
        case .failed(let why): return why
        }
    }

    @ViewBuilder
    private func row(_ title: String, ok: Bool, detail: String, action: (() -> Void)?) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !ok, let action { Button("Allow", action: action) }
        }
    }

    private func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}
