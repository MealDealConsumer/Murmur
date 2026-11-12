import AppKit
import Combine
import Foundation

struct VocabEntry: Codable, Identifiable, Hashable {
    enum Source: String, Codable {
        case manual, imported, learnedEdit, learnedVoice

        var label: String {
            switch self {
            case .manual: return "Added by you"
            case .imported: return "Imported"
            case .learnedEdit: return "Learned from an edit"
            case .learnedVoice: return "Learned from your voice"
            }
        }
    }

    var id = UUID()
    var term: String
    var heardAs: [String] = []
    var source: Source
    var addedAt = Date()
    var uses = 0
    // Variants the speaker taught directly which always apply even on an imported entry
    var personalHeardAs: [String]?
}

final class VocabularyStore: ObservableObject {
    static let shared = VocabularyStore()

    @Published private(set) var entries: [VocabEntry] = []
    private let lock = NSLock()
    private var cachedReplacer: Replacer?

    init(loadFromDisk: Bool = true) {
        if loadFromDisk { load() }
    }

    func load() {
        guard let data = try? Data(contentsOf: Paths.dictionaryFile),
              let decoded = try? JSONDecoder.iso.decode([VocabEntry].self, from: data) else { return }
        setEntries(decoded, persist: false)
    }

    func save() {
        let snapshot = lock.withLock { entries }
        if let data = try? JSONEncoder.pretty.encode(snapshot) {
            try? data.write(to: Paths.dictionaryFile, options: .atomic)
        }
    }

    func snapshot() -> [VocabEntry] { lock.withLock { entries } }

    func replacer() -> Replacer {
        lock.withLock {
            if let cachedReplacer { return cachedReplacer }
            let r = Replacer(entries: entries)
            cachedReplacer = r
            return r
        }
    }

    // Merges into an existing entry with the same spelling so repeated corrections never duplicate
    @discardableResult
    func add(term rawTerm: String, heardAs: [String] = [], source: VocabEntry.Source) -> VocabEntry? {
        let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, term.count <= 60 else { return nil }
        var list = snapshot()
        let variants = heardAs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.lowercased() != term.lowercased() }
        let result: VocabEntry
        if let i = list.firstIndex(where: { $0.term.lowercased() == term.lowercased() }) {
            // Only a word typed in by hand may change how an existing entry is spelled
            if source == .manual, list[i].term != term { list[i].term = term }
            for v in variants where !list[i].heardAs.contains(where: { $0.lowercased() == v.lowercased() }) {
                list[i].heardAs.append(v)
            }
            if source != .imported {
                var personal = list[i].personalHeardAs ?? []
                for v in variants where !personal.contains(where: { $0.lowercased() == v.lowercased() }) { personal.append(v) }
                list[i].personalHeardAs = personal
            }
            result = list[i]
        } else {
            var unique: [String] = []
            for v in variants where !unique.contains(where: { $0.lowercased() == v.lowercased() }) { unique.append(v) }
            var entry = VocabEntry(term: term, heardAs: unique, source: source)
            if source != .imported { entry.personalHeardAs = unique }
            list.append(entry)
            result = entry
        }
        setEntries(list, persist: true)
        return result
    }

    func update(_ entry: VocabEntry) {
        var list = snapshot()
        guard let i = list.firstIndex(where: { $0.id == entry.id }) else { return }
        list[i] = entry
        setEntries(list, persist: true)
    }

    func remove(ids: Set<UUID>) {
        setEntries(snapshot().filter { !ids.contains($0.id) }, persist: true)
    }

    func recordUses(_ terms: Set<String>) {
        guard !terms.isEmpty else { return }
        // Every write to the list happens on main so a learned word can never be lost to a race
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.recordUses(terms) }
            return
        }
        var list = snapshot()
        for i in list.indices where terms.contains(list[i].term) { list[i].uses += 1 }
        setEntries(list, persist: true, keepReplacer: true)
    }

    private func setEntries(_ list: [VocabEntry], persist: Bool, keepReplacer: Bool = false) {
        lock.withLock {
            entries = list
            if !keepReplacer { cachedReplacer = nil }
        }
        if Thread.isMainThread {
            objectWillChange.send()
        } else {
            DispatchQueue.main.async { self.objectWillChange.send() }
        }
        if persist { save() }
    }

    // Recent and personal words go first because whisper only reads the first couple hundred tokens
    func whisperPrompt(maxChars: Int = 420) -> String {
        let list = snapshot()
        let personal = list.filter { $0.source != .imported }.sorted { $0.addedAt > $1.addedAt }
        // CamelCase API names get rebuilt by the join rules afterwards so plain names deserve the prompt space
        func score(_ e: VocabEntry) -> Int {
            let camel = e.term.dropFirst().contains(where: { $0.isUppercase }) || e.term.contains("@")
            return e.uses * 10 + (camel ? 0 : 5)
        }
        let imported = list.enumerated().filter { $0.element.source == .imported }
            .sorted { score($0.element) != score($1.element) ? score($0.element) > score($1.element) : $0.offset < $1.offset }
            .map(\.element)
        var terms: [String] = []
        var length = 0
        for e in personal + imported {
            let add = e.term.count + 2
            if length + add > maxChars { break }
            terms.append(e.term)
            length += add
        }
        return terms.joined(separator: ", ")
    }

    func importVoiceInkFile(_ url: URL) -> Int {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        let parsed = VoiceInkImport.parse(text)
        var added = 0
        for item in parsed where add(term: item.term, heardAs: item.heardAs, source: .imported) != nil { added += 1 }
        return added
    }
}

enum VoiceInkImport {
    struct Item { var term: String; var heardAs: [String] }

    // Section 1 lines are bare terms and Section 2 lines are "a, b -> Term"
    static func parse(_ text: String) -> [Item] {
        var items: [Item] = []
        var section = 0
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## SECTION 1") { section = 1; continue }
            if line.hasPrefix("## SECTION 2") { section = 2; continue }
            if line.hasPrefix("## SECTION 3") { section = 3; continue }
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("-") { continue }
            if section == 1 {
                let term = line.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespaces)
                // Prose lines are long sentences and real terms are a few words at most
                if !term.isEmpty, !term.contains("->"), term.split(separator: " ").count <= 4 {
                    items.append(Item(term: term, heardAs: []))
                }
            } else if section == 2, line.contains("->") {
                let parts = line.components(separatedBy: "->")
                guard parts.count == 2 else { continue }
                let term = parts[1].trimmingCharacters(in: .whitespaces)
                let heard = parts[0].components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if !term.isEmpty { items.append(Item(term: term, heardAs: heard)) }
            }
        }
        return items
    }
}

// Applies the dictionary to a transcript, first the misheard variants in one pass then a joined spelling match
struct Replacer {
    private struct JoinRule {
        let term: String
        let distinctive: Bool
        // A single made up word such as Deepwoken that may absorb the words it was split into
        let coined: Bool
        // CamelCase of three or more parts such as FindFirstChildOfClass which no ordinary phrase spells out
        let longCompound: Bool
    }

    private let variantRegex: NSRegularExpression?
    private let variantTerms: [String: String]
    private let joinRules: [String: JoinRule]
    private let maxWords: Int

    init(entries: [VocabEntry]) {
        var variants: [(String, String)] = []
        var rules: [String: JoinRule] = [:]
        var maxWords = 1
        for e in entries {
            let personal = Set((e.personalHeardAs ?? []).map { Replacer.normalize($0) })
            for v in e.heardAs where personal.contains(Replacer.normalize(v)) || Replacer.variantAllowed(v, term: e.term, source: e.source) {
                variants.append((v, e.term))
            }
            let key = Replacer.key(e.term)
            guard key.count >= 3 else { continue }
            let camel = e.term.dropFirst().contains { $0.isUppercase }
            let single = !e.term.contains(" ") && !e.term.contains("-")
            let coined = single && !camel && !Replacer.isEnglishWord(e.term)
            let capitals = e.term.filter { $0.isUppercase }.count
            rules[key] = JoinRule(term: e.term, distinctive: Replacer.isDistinctive(e.term), coined: coined, longCompound: camel && capitals >= 3)
            maxWords = max(maxWords, min(6, e.term.split(separator: " ").count + 3))
        }
        var map: [String: String] = [:]
        var bodies: [String] = []
        for (v, term) in variants.sorted(by: { $0.0.count > $1.0.count }) {
            let norm = Replacer.normalize(v)
            guard !norm.isEmpty, map[norm] == nil else { continue }
            map[norm] = term
            bodies.append(norm.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "[\\s\\-]+"))
        }
        variantTerms = map
        // One alternation in one pass so a variant can never match inside the term it just produced
        variantRegex = bodies.isEmpty ? nil : try? NSRegularExpression(
            pattern: "(?<![\\p{L}\\p{N}'’\\-])(?:" + bodies.joined(separator: "|") + ")(?![\\p{L}\\p{N}'’\\-])",
            options: [.caseInsensitive])
        joinRules = rules
        self.maxWords = maxWords
    }

    static func key(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "\t" }).joined(separator: " ")
    }

    /* Imported variants made only of ordinary words would rewrite normal sentences such as "we flew to Paris",
    so they apply only when a word is not English or when they are a long spelled out API name. */
    static func variantAllowed(_ variant: String, term: String, source: VocabEntry.Source) -> Bool {
        if source != .imported { return true }
        let words = normalize(variant).split(separator: " ").map(String.init)
        if words.contains(where: { !isOrdinary($0) }) { return true }
        return words.count >= 3 && term.filter { $0.isUppercase }.count >= 3
    }

    private static let commonShort: Set<String> = [
        "a", "i", "an", "as", "at", "be", "by", "do", "go", "he", "if", "in", "is", "it", "me", "my", "no", "of",
        "on", "or", "so", "to", "up", "us", "we", "am", "oh", "ok",
    ]

    // The spell checker accepts fragments like lu and d which never stand alone in a normal sentence
    static func isOrdinary(_ word: String) -> Bool {
        let w = word.lowercased()
        if w.count <= 2 { return commonShort.contains(w) }
        return isEnglishWord(w)
    }

    private static let spellLock = NSLock()
    private static var spellCache: [String: Bool] = [:]

    // Checked lower case and capitalised so names like Paris count as ordinary words
    static func isEnglishWord(_ word: String) -> Bool {
        let w = word.lowercased()
        if let cached = spellLock.withLock({ spellCache[w] }) { return cached }
        func known(_ candidate: String) -> Bool {
            // Pinned to English because automatic language detection accepts words like rojo
            NSSpellChecker.shared.checkSpelling(of: candidate, startingAt: 0, language: "en", wrap: false,
                                                inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
        func check() -> Bool { known(w) || known(w.prefix(1).uppercased() + w.dropFirst()) }
        let ok = Thread.isMainThread ? check() : DispatchQueue.main.sync { check() }
        spellLock.withLock { spellCache[w] = ok }
        return ok
    }

    // A term is distinctive when changing only its capitalisation cannot wreck an ordinary sentence
    static func isDistinctive(_ term: String) -> Bool {
        if term.contains(where: { $0.isNumber }) { return true }
        for word in term.split(whereSeparator: { $0 == " " || $0 == "-" }) {
            let w = String(word)
            if w.dropFirst().contains(where: { $0.isUppercase }) { return true }
            if !isEnglishWord(w) { return true }
        }
        return false
    }

    // A replacement that starts lower case still gets a capital when it opens a sentence
    static func keepSentenceCapital(_ replacement: String, surface: String, before: String) -> String {
        guard let s = surface.first, s.isUppercase, let r = replacement.first, r.isLowercase else { return replacement }
        let trimmed = before.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || ".!?".contains(trimmed.last!) else { return replacement }
        return replacement.prefix(1).uppercased() + replacement.dropFirst()
    }

    func apply(_ text: String) -> (text: String, used: Set<String>) {
        var used = Set<String>()
        var out = text
        if let re = variantRegex {
            let ns = out as NSString
            var result = ""
            var cursor = 0
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                let surface = ns.substring(with: m.range)
                guard let term = variantTerms[Replacer.normalize(surface)], surface != term else { continue }
                result += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                result += Replacer.keepSentenceCapital(term, surface: surface, before: ns.substring(to: m.range.location))
                cursor = NSMaxRange(m.range)
                used.insert(term)
            }
            result += ns.substring(from: cursor)
            out = result
        }
        let joined = applyJoin(out)
        return (joined.text, used.union(joined.used))
    }

    private static let tokenRegex = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]+(?:['’\\-][\\p{L}\\p{N}]+)*")
    private static let joinableGap = try! NSRegularExpression(pattern: "^[ \\t]+$")

    private func applyJoin(_ text: String) -> (text: String, used: Set<String>) {
        guard !joinRules.isEmpty else { return (text, []) }
        let ns = text as NSString
        let tokens = Replacer.tokenRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { $0.range }
        guard !tokens.isEmpty else { return (text, []) }
        var used = Set<String>()
        var result = ""
        var cursor = 0
        var i = 0
        while i < tokens.count {
            var replaced = false
            var n = min(maxWords, tokens.count - i)
            while n >= 1 {
                if n > 1 {
                    var gapsOK = true
                    for k in i..<(i + n - 1) {
                        let gapRange = NSRange(location: NSMaxRange(tokens[k]), length: tokens[k + 1].location - NSMaxRange(tokens[k]))
                        let gap = ns.substring(with: gapRange)
                        if Replacer.joinableGap.firstMatch(in: gap, range: NSRange(location: 0, length: (gap as NSString).length)) == nil {
                            gapsOK = false
                            break
                        }
                    }
                    if !gapsOK { n -= 1; continue }
                }
                let start = tokens[i].location
                let end = NSMaxRange(tokens[i + n - 1])
                var surface = ns.substring(with: NSRange(location: start, length: end - start))
                var suffix = ""
                for poss in ["'s", "’s"] where surface.lowercased().hasSuffix(poss) {
                    suffix = String(surface.suffix(2))
                    surface = String(surface.dropLast(2))
                }
                if let replacement = match(surface: surface, words: n) {
                    let before = ns.substring(to: start)
                    result += ns.substring(with: NSRange(location: cursor, length: start - cursor))
                    result += Replacer.keepSentenceCapital(replacement.text, surface: surface, before: before) + suffix
                    used.insert(replacement.term)
                    cursor = end
                    i += n
                    replaced = true
                    break
                }
                n -= 1
            }
            if !replaced { i += 1 }
        }
        result += ns.substring(from: cursor)
        return (result, used)
    }

    private func match(surface: String, words: Int) -> (text: String, term: String)? {
        let k = Replacer.key(surface)
        var rule = joinRules[k]
        var plural = false
        if rule == nil, k.hasSuffix("s"), let r = joinRules[String(k.dropLast())], !r.term.hasSuffix("s") {
            rule = r
            plural = true
        }
        guard let rule else { return nil }
        let target = plural ? rule.term + "s" : rule.term
        if surface == target { return nil }
        let termWords = rule.term.split(separator: " ").count
        if surface.lowercased() == target.lowercased() {
            guard rule.distinctive else { return nil }
        } else if words > termWords {
            // Separate spoken words only merge into a two part coined word or a long API name never into GetPlayers from "get players"
            guard (rule.coined && words == 2) || (rule.longCompound && words >= 3) else { return nil }
        } else if words == 1 {
            guard surface.contains("-"), rule.distinctive else { return nil }
        } else {
            guard rule.distinctive else { return nil }
        }
        return (target, rule.term)
    }
}

extension JSONEncoder {
    static let pretty: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
