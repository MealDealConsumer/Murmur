import AppKit
import Foundation

/* Lets the murmur terminal command change the dictionary, which is how a chat fixes a word I confirm was
misheard. While Murmur runs the app makes the change itself so its own saves never overwrite the file. */
enum DictionaryBridge {
    static let requestName = Notification.Name("local.murmur.dictation.dictionary.request")
    static let replyName = Notification.Name("local.murmur.dictation.dictionary.reply")
    private static let sender = "local.murmur.dictation"

    struct Request {
        var action: String
        var term: String
        var heard: [String] = []
        var anyway = false

        init(action: String, term: String, heard: [String], anyway: Bool) {
            self.action = action
            self.term = term
            self.heard = heard
            self.anyway = anyway
        }

        init?(_ info: [AnyHashable: Any]) {
            guard let action = info["action"] as? String, let term = info["term"] as? String else { return nil }
            self.init(action: action, term: term, heard: info["heard"] as? [String] ?? [], anyway: info["anyway"] as? Bool ?? false)
        }

        var userInfo: [String: Any] { ["action": action, "term": term, "heard": heard, "anyway": anyway] }
    }

    static func listen() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: requestName, object: sender, queue: .main) { note in
            guard let info = note.userInfo, let id = info["id"] as? String, let request = Request(info) else { return }
            let reply = perform(request, store: .shared)
            Log.info("dictionary \(request.action) \(request.term) from the command line ok=\(reply.ok)")
            center.postNotificationName(replyName, object: sender, userInfo: ["id": id, "ok": reply.ok, "message": reply.message],
                                        deliverImmediately: true)
        }
    }

    static func perform(_ r: Request, store: VocabularyStore) -> (ok: Bool, message: String) {
        let term = r.term.trimmingCharacters(in: .whitespacesAndNewlines)
        let heard = r.heard.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !term.isEmpty, term.count <= 60 else { return (false, "A word has to be between 1 and 60 characters.") }
        switch r.action {
        case "add":
            // A personal variant always applies so one everyday word would rewrite every sentence that uses it
            if !r.anyway, let risky = heard.first(where: { isEverydayWord($0) }) {
                return (false, "Not added. \"\(risky)\" is an everyday word, so every time it is said it would become \(term). "
                    + "Teach the whole phrase instead, for example murmur add \"\(term) <next word>\" --heard \"\(risky) <next word>\", "
                    + "or add \(term) with no --heard so it only nudges recognition. Pass --anyway to add it regardless.")
            }
            guard let entry = store.add(term: term, heardAs: heard, source: .manual) else { return (false, "Could not add \(term).") }
            let variants = entry.personalHeardAs ?? []
            return (true, "Added \(entry.term)" + (variants.isEmpty ? "." : ", heard as: " + variants.joined(separator: ", ") + "."))
        case "remove":
            guard var entry = store.snapshot().first(where: { $0.term.lowercased() == term.lowercased() }) else {
                return (false, "\(term) is not in the dictionary.")
            }
            if heard.isEmpty {
                store.remove(ids: [entry.id])
                return (true, "Removed \(entry.term).")
            }
            let drop = Set(heard.map { Replacer.normalize($0) })
            entry.heardAs.removeAll { drop.contains(Replacer.normalize($0)) }
            entry.personalHeardAs?.removeAll { drop.contains(Replacer.normalize($0)) }
            store.update(entry)
            return (true, "\(entry.term) is no longer heard as: " + heard.joined(separator: ", ") + ".")
        default:
            return (false, "Unknown action \(r.action).")
        }
    }

    static func isEverydayWord(_ variant: String) -> Bool {
        let words = Replacer.normalize(variant).split(separator: " ")
        return words.count == 1 && Replacer.isOrdinary(String(words[0]))
    }

    // Runs inside the terminal command and returns the exit code
    static func command(_ args: [String]) -> Int32 {
        guard let verb = args.first else { print(usage); return 1 }
        var words: [String] = []
        var heard: [String] = []
        var anyway = false
        var all = false
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--heard":
                if i + 1 < args.count { heard.append(args[i + 1]); i += 1 }
            case "--anyway": anyway = true
            case "--all": all = true
            default: words.append(args[i])
            }
            i += 1
        }
        let term = words.joined(separator: " ")
        switch verb {
        case "list":
            list(filter: term, all: all)
            return 0
        case "add", "remove":
            let reply = send(Request(action: verb, term: term, heard: heard, anyway: anyway))
            print(reply.message)
            return reply.ok ? 0 : 1
        default:
            print(usage)
            return 1
        }
    }

    private static let usage = """
    murmur add <word> [--heard <what it was heard as>]... [--anyway]
    murmur remove <word> [--heard <variant to forget>]...
    murmur list [text] [--all]
    """

    private static func send(_ r: Request) -> (ok: Bool, message: String) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: sender).filter { $0.processIdentifier != getpid() }
        // A test data folder never belongs to the running app
        guard !others.isEmpty, ProcessInfo.processInfo.environment["MURMUR_DATA_DIR"] == nil else {
            return perform(r, store: .shared)
        }
        let id = UUID().uuidString
        var reply: (ok: Bool, message: String)?
        let center = DistributedNotificationCenter.default()
        let token = center.addObserver(forName: replyName, object: sender, queue: nil) { note in
            guard let info = note.userInfo, info["id"] as? String == id else { return }
            reply = (info["ok"] as? Bool ?? false, info["message"] as? String ?? "")
        }
        var info = r.userInfo
        info["id"] = id
        center.postNotificationName(requestName, object: sender, userInfo: info, deliverImmediately: true)
        let deadline = Date().addingTimeInterval(4)
        while reply == nil, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        center.removeObserver(token)
        return reply ?? (false, "Murmur is running but did not answer, so nothing changed. Quit and reopen Murmur, then try again.")
    }

    private static func list(filter: String, all: Bool) {
        let entries = VocabularyStore.shared.snapshot()
        let personal = entries.filter { $0.source != .imported }.sorted { $0.addedAt > $1.addedAt }
        let imported = entries.filter { $0.source == .imported }.sorted { $0.term.lowercased() < $1.term.lowercased() }
        let needle = filter.lowercased()
        func matches(_ e: VocabEntry) -> Bool {
            needle.isEmpty || e.term.lowercased().contains(needle) || e.heardAs.contains { $0.lowercased().contains(needle) }
        }
        let shown = (needle.isEmpty && !all ? personal : personal + imported).filter(matches)
        for e in shown {
            let variants = e.heardAs.isEmpty ? "" : "  heard as: " + e.heardAs.joined(separator: ", ")
            print("\(e.term)\(variants)  [\(e.source.label)]")
        }
        if needle.isEmpty, !all {
            print("\(personal.count) personal \(personal.count == 1 ? "word" : "words"). \(imported.count) imported words are hidden, add --all to see them.")
        }
        if shown.isEmpty, !needle.isEmpty { print("Nothing matches \(filter).") }
    }
}
