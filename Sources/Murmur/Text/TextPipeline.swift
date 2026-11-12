import Foundation
import NaturalLanguage

struct PipelineResult {
    var text: String
    var learned: [LearnedPair] = []
    var usedModel = false
    var modelError: String?
}

enum TextPipeline {
    // Phrases that mean the speaker is talking about the text rather than dictating it
    static let cuePattern = try! NSRegularExpression(pattern: [
        "\\b(one|single) word\\b",
        "\\btwo words\\b",
        "\\bseparate words\\b",
        "\\bno (space|spaces|dash|dashes|hyphen|hyphens|gap)\\b",
        "\\bwithout (a |the |any )?(space|spaces|dash|dashes|hyphen|hyphens|gap)\\b",
        "\\b(with|add) (a |an )?(dash|hyphen)\\b",
        "\\bspel(led|t|ling)\\b",
        "\\bspell it\\b",
        "\\bcapital (letter|[a-z])\\b",
        "\\bcapitali[sz]ed?\\b",
        "\\b(lower ?case|upper ?case|all caps)\\b",
        "\\bscratch that\\b",
        "\\bstrike that\\b",
        "\\b(camel|pascal|snake) case\\b",
    ].joined(separator: "|"), options: [.caseInsensitive])

    static let spellingCuePattern = try! NSRegularExpression(pattern: [
        "\\b(one|single) word\\b", "\\btwo words\\b", "\\bno (space|spaces|dash|dashes|hyphen|hyphens)\\b",
        "\\bwithout (a |the |any )?(space|spaces|dash|dashes|hyphen|hyphens)\\b", "\\bspel(led|t)\\b",
    ].joined(separator: "|"), options: [.caseInsensitive])

    static func hasCue(_ text: String) -> Bool {
        cuePattern.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    static func cueCount(_ text: String) -> Int {
        cuePattern.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    private static let fillerPattern = try! NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}'’])(?:um+|uh+|uhm+|erm+|er|hmm+)(?![\\p{L}\\p{N}'’])[,.]?\\s*", options: [.caseInsensitive])

    // Thinking noises go and whatever follows at the start of a sentence gets its capital back
    static func stripFillers(_ text: String) -> String {
        var out = text as NSString
        let matches = fillerPattern.matches(in: text, range: NSRange(location: 0, length: out.length))
        for m in matches.reversed() {
            let before = out.substring(to: m.range.location).trimmingCharacters(in: .whitespaces)
            let sentenceStart = before.isEmpty || ".!?".contains(before.last!)
            out = out.replacingCharacters(in: m.range, with: "") as NSString
            if sentenceStart, m.range.location < out.length {
                let next = out.substring(with: NSRange(location: m.range.location, length: 1))
                out = out.replacingCharacters(in: NSRange(location: m.range.location, length: 1), with: next.uppercased()) as NSString
            }
        }
        return (out as String).replacingOccurrences(of: ", ,", with: ",").replacingOccurrences(of: " ,", with: ",")
    }

    private static let repeatPattern = try! NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}'’])([\\p{L}\\p{N}'’]+)((?:[,.]?\\s+\\1)+)(?![\\p{L}\\p{N}'’])", options: [.caseInsensitive])
    private static let fragmentPattern = try! NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}])(\\p{L}{1,2})-\\s?(?=\\1)", options: [.caseInsensitive])
    // Doubles that are real English or deliberate emphasis survive when said exactly twice
    private static let realDoubles: Set<String> = ["had", "that", "is", "very", "really", "so", "no", "yeah", "bye", "ha", "go", "knock", "now"]
    private static let realPrefixes: Set<String> = ["re", "co", "de", "ex", "bi", "un", "in"]

    // Stutters like "I I I think", "the the" and "w-what" collapse to the word that was meant
    static func collapseStutters(_ text: String) -> String {
        var out = text as NSString
        for m in fragmentPattern.matches(in: text, range: NSRange(location: 0, length: out.length)).reversed() {
            let fragment = out.substring(with: m.range(at: 1)).lowercased()
            guard !realPrefixes.contains(fragment) else { continue }
            out = out.replacingCharacters(in: m.range, with: "") as NSString
        }
        let afterFragments = out as String
        out = afterFragments as NSString
        for m in repeatPattern.matches(in: afterFragments, range: NSRange(location: 0, length: out.length)).reversed() {
            let word = out.substring(with: m.range(at: 1))
            let repeats = words(out.substring(with: m.range(at: 2))).count
            if repeats == 1, realDoubles.contains(word.lowercased()) { continue }
            out = out.replacingCharacters(in: m.range, with: word) as NSString
        }
        return out as String
    }

    static func tidy(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let scratchPattern = try! NSRegularExpression(pattern: "\\b(scratch|strike) that\\b", options: [.caseInsensitive])

    static func matches(_ re: NSRegularExpression, _ text: String) -> Bool {
        re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    static func process(raw: String, store: VocabularyStore, corrections: Bool, llm: LLMService) async -> PipelineResult {
        var text = tidy(collapseStutters(stripFillers(tidy(raw))))
        guard !text.isEmpty else { return PipelineResult(text: "") }
        let replacer = await MainActor.run { store.replacer() }
        let first = replacer.apply(text)
        text = first.text
        store.recordUses(first.used)

        guard corrections, hasCue(text) else { return PipelineResult(text: SnippetStore.shared.apply(text)) }

        var result = PipelineResult(text: text, usedModel: true)
        let vocabulary = store.snapshot().filter { $0.source != .imported }.map(\.term)
        var output = text as NSString
        // Windows are patched from the end so earlier ranges stay valid
        for window in cueWindows(in: text).reversed() {
            let original = output.substring(with: window)
            let passage = original.trimmingCharacters(in: .whitespacesAndNewlines)
            let lead = String(original.prefix { $0.isWhitespace })
            let trail = String(original.reversed().prefix { $0.isWhitespace })
            do {
                guard let fix = try await correct(passage: passage, vocabulary: vocabulary, llm: llm) else { continue }
                output = output.replacingCharacters(in: window, with: lead + fix.text + trail) as NSString
                result.learned.append(contentsOf: fix.learned)
            } catch {
                result.modelError = error.localizedDescription
                Log.info("correction model error \(error)")
                // A model that failed once is not asked again for the rest of this dictation
                break
            }
        }
        text = tidy(output as String)

        if !result.learned.isEmpty {
            let pairs = result.learned
            await MainActor.run {
                for pair in pairs {
                    store.add(term: pair.correct, heardAs: [pair.heard], source: .learnedVoice)
                }
            }
        }
        // The model can respell known words so the dictionary gets the final say
        text = await MainActor.run { store.replacer() }.apply(text).text
        result.text = SnippetStore.shared.apply(text)
        return result
    }

    // Returns nil whenever the passage should stay exactly as dictated
    static func correct(passage: String, vocabulary: [String], llm: LLMService) async throws -> (text: String, learned: [LearnedPair])? {
        let first = try await llm.applySpokenCorrections(to: passage, vocabulary: vocabulary)
        var fixed = tidy(first.text)
        var learned = useful(first.learned, passage: passage, in: fixed)
        // An untouched answer means the model judged the phrase to be ordinary speech and that judgement stands
        if fixed == passage { return nil }
        let spelling = matches(spellingCuePattern, passage)
        if cueCount(fixed) > 0 || (spelling && learned.isEmpty) {
            let retry = try await llm.applySpokenCorrections(to: passage, vocabulary: vocabulary, secondLook: true)
            let retried = tidy(retry.text)
            let retryLearned = useful(retry.learned, passage: passage, in: retried)
            let better = retried != passage && (cueCount(retried) < cueCount(fixed) || (learned.isEmpty && !retryLearned.isEmpty))
            if better, accept(original: passage, fixed: retried, learned: retryLearned) {
                fixed = retried
                learned = retryLearned
            }
        }
        let modelDroppedCue = cueCount(fixed) < cueCount(passage)
        fixed = stripInstructionClauses(fixed, original: passage)
        // Removing a closing instruction can leave the sentence ending on a comma
        if fixed.hasSuffix(","), let end = passage.last, ".!?".contains(end) { fixed = String(fixed.dropLast()) + String(end) }
        // When the model fixes a word without reporting it the diff of its answer says what changed
        if spelling, learned.isEmpty {
            learned = useful(EditLearner.corrections(original: passage, edited: fixed), passage: passage, in: fixed)
        }
        if spelling, learned.isEmpty, modelDroppedCue, let rescue = oneWordFallback(passage: passage, fixed: fixed) {
            fixed = rescue.text
            learned = [rescue.learned]
        }
        // A spelling instruction that respelled nothing was really a sentence about something else so it stays
        let passageWords = Set(words(passage))
        let respelled = !learned.isEmpty || words(fixed).contains { !passageWords.contains($0) }
        if spelling, !matches(scratchPattern, passage), !respelled { return nil }
        guard accept(original: passage, fixed: fixed, learned: learned) else {
            Log.info("correction rejected for passage of \(passage.count) chars")
            return nil
        }
        return (fixed, learned)
    }

    // Each cue gets the two sentences before it and the one after it since spoken fixes point backwards
    static func cueWindows(in text: String) -> [NSRange] {
        let ns = text as NSString
        if ns.length < 600 { return [NSRange(location: 0, length: ns.length)] }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [NSRange] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            sentences.append(NSRange(range, in: text))
            return true
        }
        guard !sentences.isEmpty else { return [NSRange(location: 0, length: ns.length)] }
        var windows: [NSRange] = []
        for (i, s) in sentences.enumerated() {
            guard hasCue(ns.substring(with: s)) else { continue }
            let lo = sentences[max(0, i - 2)].location
            let hiRange = sentences[min(sentences.count - 1, i + 1)]
            var window = NSRange(location: lo, length: NSMaxRange(hiRange) - lo)
            if let last = windows.last, NSMaxRange(last) >= window.location {
                window = NSUnionRange(last, window)
                windows.removeLast()
            }
            windows.append(window)
        }
        return windows
    }

    private static let instructionWords: Set<String> = [
        "one", "single", "two", "word", "words", "no", "not", "without", "with", "space", "spaces", "dash", "dashes",
        "hyphen", "hyphens", "gap", "gaps", "capital", "capitals", "capitalised", "capitalized", "letter", "letters",
        "lowercase", "lower", "upper", "uppercase", "case", "caps", "camel", "pascal", "snake", "keep", "together",
        "separate", "spelled", "spelt", "spelling", "that's", "thats", "it's", "its", "is", "and", "a", "an", "the",
        "in", "between", "actually", "all", "just", "written", "as", "like", "so", "but", "first", "of", "each",
    ]

    private static func isInstructionClause(_ raw: String) -> Bool {
        var clause = raw.trimmingCharacters(in: .whitespaces)
        if let last = clause.last, ".!?".contains(last) { clause = String(clause.dropLast()) }
        let ws = words(clause)
        guard !ws.isEmpty, ws.count <= 10 else { return false }
        let allInstruction = ws.allSatisfy { instructionWords.contains($0) || $0.count == 1 }
        let lower = clause.lowercased()
        let hasPhrase = hasCue(clause) || lower.contains("camel case") || (lower.contains("capital") && ws.contains { $0.count == 1 && $0 != "a" })
        return allInstruction && hasPhrase
    }

    /* The small model sometimes applies a fix but leaves the instruction behind. A comma clause made only of
    instruction words is removed when the clause it follows holds a word the model changed, which keeps
    sentences like "the answer, in one word, is no" exactly as dictated. */
    static func stripInstructionClauses(_ text: String, original: String) -> String {
        var clauses = text.components(separatedBy: ",")
        guard clauses.count > 1 else { return text }
        let originalWords = Set(words(original))
        var removed = false
        for i in stride(from: clauses.count - 1, through: 1, by: -1) where isInstructionClause(clauses[i]) {
            var j = i - 1
            while j > 0, isInstructionClause(clauses[j]) { j -= 1 }
            guard words(clauses[j]).contains(where: { !originalWords.contains($0) }) else { continue }
            let trimmed = clauses[i].trimmingCharacters(in: .whitespaces)
            let ending = trimmed.last.map { ".!?".contains($0) ? String($0) : "" } ?? ""
            clauses.remove(at: i)
            if !ending.isEmpty { clauses[i - 1] += ending }
            removed = true
        }
        return removed ? clauses.joined(separator: ",") : text
    }

    private static let phrase = "([\\p{L}\\p{N}]+(?:[ \\-]+[\\p{L}\\p{N}]+){1,3})"
    private static let sentenceForm = try! NSRegularExpression(
        pattern: "(?:^|(?<=[.!?]\\s))" + phrase + "\\s+(?:is|are)\\s+(?:all\\s+)?(?:one|a single)\\s+word\\b[^.!?]*[.!?]?\\s*",
        options: [.caseInsensitive])
    private static let inlineForm = try! NSRegularExpression(
        pattern: "\\b([\\p{L}\\p{N}]+[ \\-]+[\\p{L}\\p{N}]+),?\\s+(?:that's|that is|it's|it is)\\s+(?:all\\s+)?one word\\b[^,.!?]*,?",
        options: [.caseInsensitive])
    private static let functionWords: Set<String> = [
        "the", "a", "an", "my", "your", "his", "her", "its", "it", "our", "their", "this", "that", "these", "those",
        "what", "which", "who", "is", "are", "was", "to", "of", "in", "on", "and", "or", "name", "word", "i", "we", "you",
    ]

    /* Covers the two most common phrasings when the model drops an instruction without applying it.
    "Ember reach is one word." and "frost ward, that's one word" both name the words to join. */
    static func oneWordFallback(passage: String, fixed: String) -> (text: String, learned: LearnedPair)? {
        let full = NSRange(location: 0, length: (passage as NSString).length)
        var heard: String?
        var instruction: NSRegularExpression?
        if let m = sentenceForm.firstMatch(in: passage, range: full) {
            heard = (passage as NSString).substring(with: m.range(at: 1))
            instruction = sentenceForm
        } else if let m = inlineForm.firstMatch(in: passage, range: full) {
            heard = (passage as NSString).substring(with: m.range(at: 1))
            instruction = inlineForm
        }
        guard let heard, let instruction else { return nil }
        let parts = heard.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
        guard parts.count >= 2, !parts.contains(where: { functionWords.contains($0.lowercased()) }) else { return nil }
        var joined = parts.joined().lowercased()
        guard !Replacer.isEnglishWord(joined) else { return nil }
        if parts.first?.first?.isUppercase == true { joined = joined.prefix(1).uppercased() + joined.dropFirst() }
        var text = fixed
        // The inline form keeps its words in place so only the instruction part goes
        if instruction === inlineForm {
            let ns = text as NSString
            if let m = inlineForm.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                text = ns.replacingCharacters(in: m.range, with: ns.substring(with: m.range(at: 1)))
            }
        } else {
            text = sentenceForm.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
        }
        let body = parts.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "[\\s\\-]+")
        guard let re = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])" + body + "(?![\\p{L}\\p{N}])", options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil else { return nil }
        text = re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: NSRegularExpression.escapedTemplate(for: joined))
        text = tidy(text.replacingOccurrences(of: " ,", with: ",").replacingOccurrences(of: " .", with: "."))
        return (text, LearnedPair(heard: parts.joined(separator: " ").lowercased(), correct: joined))
    }

    static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") }).map(String.init)
    }

    // Every removed word has to be paid for by an instruction and taking something back pays for what came before it
    static func removalAllowance(_ passage: String, learned: [LearnedPair]) -> Int {
        let clauses = passage.components(separatedBy: CharacterSet(charactersIn: ",.;!?"))
        var allowance = 2
        for (i, clause) in clauses.enumerated() where hasCue(clause) {
            allowance += words(clause).count
            if matches(scratchPattern, clause) {
                let prior = clauses[max(0, i - 2)..<i].reduce(0) { $0 + words($1).count }
                allowance += min(prior, 30)
            }
        }
        for pair in learned { allowance += max(0, words(pair.heard).count - words(pair.correct).count) }
        return allowance
    }

    private static let negations: Set<String> = ["not", "no", "never", "don't", "doesn't", "isn't", "won't", "can't", "didn't"]

    // A small model sometimes rewrites, shortens or answers the passage so anything that strays is thrown away
    static func accept(original: String, fixed: String, learned: [LearnedPair]) -> Bool {
        let before = words(original)
        let after = words(fixed)
        if before.count - after.count > removalAllowance(original, learned: learned) { return false }
        if after.count > before.count + 2 { return false }
        for n in negations where after.filter({ $0 == n }).count > before.filter({ $0 == n }).count { return false }
        let known = Set(before).union(learned.flatMap { words($0.correct) })
        let joinedOriginal = Replacer.key(original)
        // Long words may be joins of what was said but short ones have to have been said
        let invented = after.filter { w in
            !known.contains(w) && !(w.count >= 5 && joinedOriginal.contains(Replacer.key(w)))
        }
        return invented.isEmpty
    }

    static func useful(_ pairs: [LearnedPair], passage: String, in text: String) -> [LearnedPair] {
        pairs.filter { validLearned($0, passage: passage) && text.range(of: $0.correct) != nil }
    }

    static func validLearned(_ pair: LearnedPair, passage: String) -> Bool {
        let correct = pair.correct.trimmingCharacters(in: .whitespacesAndNewlines)
        let heard = pair.heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !correct.isEmpty, correct.count <= 40, correct.split(separator: " ").count <= 4, !hasCue(correct) else { return false }
        guard !heard.isEmpty, heard != correct, !functionWords.contains(heard.lowercased()) else { return false }
        let kh = Replacer.key(heard), kc = Replacer.key(correct)
        guard !kh.isEmpty, Replacer.key(passage).contains(kh) else { return false }
        // The heard form has to resemble the fix unless the speaker spelled it out letter by letter
        let similar = kh == kc || Double(EditLearner.levenshtein(kh, kc)) / Double(max(kh.count, kc.count)) <= 0.5
        let spelledOut = passage.lowercased().contains(kc.map(String.init).joined(separator: " "))
        return similar || spelledOut
    }
}
