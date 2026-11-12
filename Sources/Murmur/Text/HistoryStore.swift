import Combine
import Foundation

struct HistoryItem: Codable, Identifiable, Hashable {
    // The saved name stays copied so older history files still load
    enum Outcome: String, Codable { case pasted, notPasted = "copied", empty, failed, cancelled }

    var id = UUID()
    var date = Date()
    var text: String
    var raw: String
    var appName: String
    var duration: Double
    var outcome: Outcome
    var audioFile: String?
}

final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    static let maxItems = 2000
    static let keepAudio = 40
    static let keepFor: TimeInterval = 7 * 24 * 3600

    @Published private(set) var items: [HistoryItem] = []
    private var sweepTimer: Timer?

    init() {
        if let data = try? Data(contentsOf: Paths.historyFile),
           let decoded = try? JSONDecoder.iso.decode([HistoryItem].self, from: data) {
            items = decoded
        }
        if pruneOld() { save() }
        removeStrayAudio()
        // An app left open for days with no dictation still forgets old entries on time
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            guard let self, self.pruneOld() else { return }
            self.save()
        }
    }

    func add(_ item: HistoryItem) {
        items.insert(item, at: 0)
        if items.count > Self.maxItems { items.removeLast(items.count - Self.maxItems) }
        pruneOld()
        pruneAudio()
        save()
    }

    static func expired(_ items: [HistoryItem], now: Date = Date()) -> Set<UUID> {
        Set(items.filter { now.timeIntervalSince($0.date) > keepFor }.map(\.id))
    }

    // Everything older than a week goes with its audio so the folder never keeps growing
    @discardableResult
    private func pruneOld() -> Bool {
        let old = Self.expired(items)
        guard !old.isEmpty else { return false }
        for item in items where old.contains(item.id) { removeAudio(item) }
        items.removeAll { old.contains($0.id) }
        Log.info("history forgot \(old.count) entries older than a week")
        return true
    }

    // A crash between saving audio and adding its entry leaves a file nothing points at
    private func removeStrayAudio() {
        let fm = FileManager.default
        let known = Set(items.compactMap(\.audioFile))
        guard let files = try? fm.contentsOfDirectory(at: Paths.recordings, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for url in files where !known.contains(url.lastPathComponent) {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            if Date().timeIntervalSince(date) > Self.keepFor { try? fm.removeItem(at: url) }
        }
    }

    func replace(_ item: HistoryItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i] = item
        save()
    }

    func delete(_ ids: Set<UUID>) {
        for item in items where ids.contains(item.id) { removeAudio(item) }
        items.removeAll { ids.contains($0.id) }
        save()
    }

    func clear() {
        for item in items { removeAudio(item) }
        items = []
        save()
    }

    var last: HistoryItem? { items.first { !$0.text.isEmpty } }

    func audioURL(_ item: HistoryItem) -> URL? {
        guard let name = item.audioFile else { return nil }
        let url = Paths.recordings.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func removeAudio(_ item: HistoryItem) {
        if let url = audioURL(item) { try? FileManager.default.removeItem(at: url) }
    }

    // Audio is kept for recent items and for anything that failed so it can be retried
    private func pruneAudio() {
        var kept = 0
        for i in items.indices where items[i].audioFile != nil {
            let failed = items[i].outcome == .failed || items[i].outcome == .empty || items[i].outcome == .cancelled
            if kept < Self.keepAudio || failed {
                kept += 1
                continue
            }
            removeAudio(items[i])
            items[i].audioFile = nil
        }
    }

    func saveNow() {
        if let data = try? JSONEncoder.pretty.encode(items) {
            try? data.write(to: Paths.historyFile, options: .atomic)
        }
    }

    private func save() {
        let snapshot = items
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder.pretty.encode(snapshot) {
                try? data.write(to: Paths.historyFile, options: .atomic)
            }
        }
    }
}
