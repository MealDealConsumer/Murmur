import Combine
import Foundation

struct Snippet: Codable, Identifiable, Hashable {
    var id = UUID()
    var trigger: String
    var text: String
}

// Spoken shortcuts that expand into saved text such as an email address or a sign off
final class SnippetStore: ObservableObject {
    static let shared = SnippetStore()

    @Published private(set) var items: [Snippet] = []
    private let lock = NSLock()
    private var snapshot: [Snippet] = []
    private var file: URL { Paths.dataDir.appendingPathComponent("snippets.json") }

    init() {
        if let data = try? Data(contentsOf: file), let decoded = try? JSONDecoder().decode([Snippet].self, from: data) {
            set(decoded, persist: false)
        }
    }

    func add(trigger: String, text: String) {
        let t = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !body.isEmpty else { return }
        var list = items.filter { $0.trigger.lowercased() != t.lowercased() }
        list.insert(Snippet(trigger: t, text: body), at: 0)
        set(list, persist: true)
    }

    func remove(_ id: UUID) {
        set(items.filter { $0.id != id }, persist: true)
    }

    private func set(_ list: [Snippet], persist: Bool) {
        items = list
        lock.withLock { snapshot = list }
        if persist, let data = try? JSONEncoder.pretty.encode(list) { try? data.write(to: file, options: .atomic) }
    }

    // Longer triggers go first so "my work email" wins over "my email"
    func apply(_ text: String) -> String {
        let list = lock.withLock { snapshot }.sorted { $0.trigger.count > $1.trigger.count }
        var out = text
        for s in list {
            let words = s.trigger.lowercased().split(whereSeparator: { $0 == " " || $0 == "-" }).map { NSRegularExpression.escapedPattern(for: String($0)) }
            guard !words.isEmpty,
                  let re = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])" + words.joined(separator: "[\\s,\\-]+") + "(?![\\p{L}\\p{N}])", options: [.caseInsensitive]) else { continue }
            out = re.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: (out as NSString).length),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: s.text))
        }
        return out
    }
}
