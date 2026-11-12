import AppKit

enum SelfTest {
    static func run() -> Bool {
        var failures = 0
        func check(_ name: String, _ got: String, _ want: String) {
            if got == want {
                print("ok   \(name)")
            } else {
                failures += 1
                print("FAIL \(name)\n     got  \(got)\n     want \(want)")
            }
        }

        let entries = [
            VocabEntry(term: "Deepwoken", source: .imported),
            VocabEntry(term: "DataStore", heardAs: ["data store"], source: .imported),
            VocabEntry(term: "ReplicatedStorage", heardAs: ["replicated storage"], source: .imported),
            VocabEntry(term: "ServerScriptService", heardAs: ["server script service"], source: .imported),
            VocabEntry(term: "FindFirstChild", source: .imported),
            VocabEntry(term: "FindFirstChildOfClass", source: .imported),
            VocabEntry(term: "GetPlayers", source: .imported),
            VocabEntry(term: "Rojo", heardAs: ["roho", "ro jo"], source: .imported),
            VocabEntry(term: "Players", source: .imported),
            VocabEntry(term: "Workspace", source: .imported),
            VocabEntry(term: "Highlight", source: .imported),
            VocabEntry(term: "Roblox", source: .imported),
            VocabEntry(term: "Bitmon", source: .imported),
            VocabEntry(term: "lm-loleris", heardAs: ["lm loleris", "loleris"], source: .imported),
            VocabEntry(term: "Motor6D", heardAs: ["motor six d"], source: .imported),
            VocabEntry(term: "The Long Night", source: .imported),
            VocabEntry(term: "Luau", heardAs: ["lu au"], source: .imported),
            VocabEntry(term: "parihsz", heardAs: ["paris", "parish"], source: .imported),
            VocabEntry(term: "rokit", heardAs: ["rocket", "ro kit"], source: .imported),
            VocabEntry(term: "howmanysmall", heardAs: ["how many small"], source: .imported),
            VocabEntry(term: "PivotTo", heardAs: ["pivot to"], source: .imported),
            VocabEntry(term: "Grimtide", heardAs: ["grim tide"], source: .learnedVoice, personalHeardAs: ["grim tide"]),
        ]
        let r = Replacer(entries: entries)
        func ap(_ s: String) -> String { r.apply(s).text }

        check("split term", ap("I played deep woken today."), "I played Deepwoken today.")
        check("hyphen term", ap("Deep-woken is fun."), "Deepwoken is fun.")
        check("case term", ap("open deepwoken now"), "open Deepwoken now")
        check("plural merge", ap("two bit mons"), "two Bitmons")
        check("possessive", ap("deep woken's map"), "Deepwoken's map")
        check("long merge", ap("call find first child of class here"), "call FindFirstChildOfClass here")
        check("three word merge", ap("call find first child here"), "call FindFirstChild here")
        check("long variant", ap("put it in server script service"), "put it in ServerScriptService")
        check("two word api left alone", ap("put it in replicated storage."), "put it in replicated storage.")
        check("data store left alone", ap("save it in the data store please"), "save it in the data store please")
        check("get players left alone", ap("How do we get players to come back?"), "How do we get players to come back?")
        check("joined api recased", ap("call getplayers there"), "call GetPlayers there")
        check("explicit variant", ap("open roho and sync"), "open Rojo and sync")
        check("ordinary word kept", ap("the players left"), "the players left")
        check("ordinary merge refused", ap("my work space is messy"), "my work space is messy")
        check("high light kept", ap("high light levels"), "high light levels")
        check("no merge across comma", ap("deep, woken up"), "deep, woken up")
        check("no merge across spaced dash", ap("save the data - store it later"), "save the data - store it later")
        check("hyphenated term", ap("thanks lm loleris"), "thanks lm-loleris")
        check("hyphenated term stable", ap("thanks lm-loleris"), "thanks lm-loleris")
        check("hyphenated term twice", ap(ap("thanks lm loleris")), "thanks lm-loleris")
        check("digit variant", ap("add a motor six d"), "add a Motor6D")
        check("ordinary phrase kept", ap("it was the long night before"), "it was the long night before")
        check("explicit luau", ap("write it in lu au"), "write it in Luau")
        check("paris kept", ap("We flew to Paris and met the parish council"), "We flew to Paris and met the parish council")
        check("rocket kept", ap("the rocket launch"), "the rocket launch")
        check("how many small kept", ap("How many small rooms are left?"), "How many small rooms are left?")
        check("pivot to kept", ap("pivot to a new plan"), "pivot to a new plan")
        check("non english variant kept", ap("install ro kit first"), "install rokit first")
        check("sentence capital kept", ap("Ro kit installs it."), "Rokit installs it.")
        check("personal variant applies", ap("the boss grim tide"), "the boss Grimtide")

        // Every real dictionary word has to come out of the dictionary untouched
        let vocabFile = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("VOICEINK_VOCAB.md")
        if let text = try? String(contentsOf: vocabFile, encoding: .utf8) {
            let real = VoiceInkImport.parse(text).map { VocabEntry(term: $0.term, heardAs: $0.heardAs, source: .imported) }
            let realReplacer = Replacer(entries: real)
            let drifted = real.map(\.term).filter { realReplacer.apply($0).text != $0 }
            check("real dictionary stable", drifted.joined(separator: ", "), "")
            let sentences = [
                "We flew to Paris and the rocket launch was fine.",
                "How do we get players to come back to the game?",
                "The force field is up and run service is slow.",
                "Should take damage when you pivot to the left.",
                "Celine said the parish council will listen, see what happens.",
            ]
            for s in sentences { check("real ordinary: \(s.prefix(24))", realReplacer.apply(s).text, s) }
        }

        func learned(_ a: String, _ b: String) -> String {
            EditLearner.corrections(original: a, edited: b).map { "\($0.heard)>\($0.correct)" }.joined(separator: ",")
        }
        check("learn merge", learned("We play deep-woken tonight.", "We play Deepwoken tonight."), "deep-woken>Deepwoken")
        check("learn split fix", learned("Open the bit mon folder", "Open the Bitmon folder"), "bit mon>Bitmon")
        check("learn mishear", learned("sync it with roho now", "sync it with Rojo now"), "roho>Rojo")
        check("learn added capitals", learned("the exp system", "the EXP system"), "exp>EXP")
        check("ignore lowering", learned("Is Rojo running?", "is rojo running?"), "")
        check("ignore english fix", learned("put it over there", "put it over their"), "")
        check("ignore additions", learned("hello world", "hello big world and more"), "")
        check("ignore rewrite", learned("this is the plan", "totally different sentence here"), "")
        check("ignore punctuation", learned("hello world", "Hello, world!"), "")
        check("ignore number", learned("it costs 100 Robux", "it costs 150 Robux"), "")
        check("ignore version", learned("ship v12 today", "ship v13 today"), "")

        check("cue one word", String(TextPipeline.hasCue("deep woken, that's one word")), "true")
        check("cue scratch", String(TextPipeline.hasCue("five, scratch that, six")), "true")
        check("no cue", String(TextPipeline.hasCue("let's ship the update tonight")), "false")
        check("delete that is not a cue", String(TextPipeline.hasCue("Can you delete that branch after the merge?")), "false")
        check("accept fix", String(TextPipeline.accept(original: "We play deep woken, that's one word, tonight.", fixed: "We play Deepwoken tonight.", learned: [LearnedPair(heard: "deep woken", correct: "Deepwoken")])), "true")
        check("accept scratch", String(TextPipeline.accept(original: "Let's meet at five. Scratch that, let's meet at six.", fixed: "Let's meet at six.", learned: [])), "true")
        check("reject answer", String(TextPipeline.accept(original: "Can you check the drop rates, one word answers only?", fixed: "Sure, here are the current drop rates for every rarity tier in the game.", learned: [])), "false")
        check("reject wipe", String(TextPipeline.accept(original: "Make the label one word. Then ship the patch and tell the team about the new boss.", fixed: "Then ship the patch.", learned: [])), "false")
        check("reject empty", String(TextPipeline.accept(original: "Delete that file and push the change, spelled out.", fixed: "", learned: [])), "false")
        check("reject negation", String(TextPipeline.accept(original: "We should ship the update tonight, one word.", fixed: "We should not ship the update tonight.", learned: [])), "false")

        check("strip capital clause", TextPipeline.stripInstructionClauses("Make the boss name Grimtide, with a capital G and no space, and give it two phases.",
              original: "Make the boss name grim tide, with a capital G and no space, and give it two phases."), "Make the boss name Grimtide, and give it two phases.")
        check("strip camel clause", TextPipeline.stripInstructionClauses("The function is called getPlayerData, no dashes, camel case.",
              original: "The function is called get-player-data, no dashes, camel case."), "The function is called getPlayerData.")
        check("keep real clause", TextPipeline.stripInstructionClauses("Give me one word answers, and keep it short.", original: "Give me one word answers, and keep it short."), "Give me one word answers, and keep it short.")
        check("keep in one word", TextPipeline.stripInstructionClauses("The answer, in one word, is no.", original: "The answer, in one word, is no."), "The answer, in one word, is no.")
        check("keep no spaces", TextPipeline.stripInstructionClauses("Keep the names short, no spaces.", original: "Keep the names short, no spaces."), "Keep the names short, no spaces.")

        check("filler at start", TextPipeline.stripFillers("Um, the plan is fine."), "The plan is fine.")
        check("filler mid", TextPipeline.stripFillers("So, um, yeah I think uh we go."), "So, yeah I think we go.")
        check("filler after full stop", TextPipeline.stripFillers("Done. Uhm, next one."), "Done. Next one.")
        check("words kept", TextPipeline.stripFillers("The umbrella is humming, hmmm okay."), "The umbrella is humming, okay.")
        check("filler er", TextPipeline.stripFillers("So er, ERM, we ship it in 10 mm boxes."), "So we ship it in 10 mm boxes.")
        check("stutter triple", TextPipeline.collapseStutters("I I I think it works."), "I think it works.")
        check("stutter commas", TextPipeline.collapseStutters("I, I, I think the the plan is fine."), "I think the plan is fine.")
        check("stutter fragment", TextPipeline.collapseStutters("w-what do we b- but do"), "what do we but do")
        check("real doubles kept", TextPipeline.collapseStutters("We had had enough and I said that that was very very good."), "We had had enough and I said that that was very very good.")
        check("prefix kept", TextPipeline.collapseStutters("Please re-read the e-mail and co-op notes."), "Please re-read the e-mail and co-op notes.")
        check("different words kept", TextPipeline.collapseStutters("the theme is there"), "the theme is there")

        func rescue(_ passage: String, _ fixed: String) -> String {
            guard let r = TextPipeline.oneWordFallback(passage: passage, fixed: fixed) else { return "nil" }
            return "\(r.text) | \(r.learned.heard)>\(r.learned.correct)"
        }
        check("rescue sentence form", rescue("So the zone is called ember reach. Ember reach is one word. And it opens at ten.",
                                             "So the zone is called ember reach. And it opens at ten."),
              "So the zone is called Emberreach. And it opens at ten. | ember reach>Emberreach")
        check("rescue inline form", rescue("We could play frost ward, that's one word, later.", "We could play frost ward later."),
              "We could play frostward later. | frost ward>frostward")
        check("no rescue without phrase", rescue("Give me one word answers.", "Give me one word answers."), "nil")
        check("no rescue for the password", rescue("Type the password here. The password is one word.", "Type the password here."), "nil")
        check("no rescue for my answer", rescue("My answer, it's one word, no.", "My answer no."), "nil")

        check("learned needs resemblance", String(TextPipeline.validLearned(LearnedPair(heard: "it", correct: "Grimtide"), passage: "call it grim tide one word")), "false")
        check("learned spelled out", String(TextPipeline.validLearned(LearnedPair(heard: "jackson", correct: "Jaxon"), passage: "tell jackson, spelled j a x o n")), "true")

        // Snippets are tested against a throwaway store so the real one is never touched
        if ProcessInfo.processInfo.environment["MURMUR_DATA_DIR"] != nil {
            let snippets = SnippetStore.shared
            snippets.add(trigger: "my email", text: "me@example.com")
            snippets.add(trigger: "my work email", text: "work@example.com")
            check("snippet", snippets.apply("Send it to my email."), "Send it to me@example.com.")
            check("longer snippet first", snippets.apply("use my work email please"), "use work@example.com please")
            check("snippet inside word ignored", snippets.apply("my emailing list"), "my emailing list")

            let store = VocabularyStore.shared
            func dict(_ action: String, _ term: String, _ heard: [String] = [], anyway: Bool = false) -> String {
                let r = DictionaryBridge.perform(.init(action: action, term: term, heard: heard, anyway: anyway), store: store)
                return r.ok ? "ok" : "refused"
            }
            check("chat refuses an everyday word", dict("add", "Claude", ["claw"]), "refused")
            check("chat refused word left nothing", String(store.snapshot().contains { $0.term == "Claude" }), "false")
            check("chat adds a phrase", dict("add", "Claude chat", ["claw chat"]), "ok")
            check("chat phrase applies", store.replacer().apply("open a claw chat and the cat's claw").text,
                  "open a Claude chat and the cat's claw")
            check("chat adds a made up word", dict("add", "Rojo", ["roho"]), "ok")
            check("chat forgets one variant", dict("remove", "Claude chat", ["claw chat"]), "ok")
            check("chat variant gone", store.replacer().apply("a claw chat").text, "a claw chat")
            check("chat removes a word", dict("remove", "Rojo"), "ok")
            check("chat remove missing", dict("remove", "Rojo"), "refused")
        }
        check("warning chime exists", String(NSSound(named: "Glass") != nil), "true")
        check("five then one minute warnings", DictationController.warnings.map { "\(Int($0.at))" }.joined(separator: ","), "900,1140")
        check("paste probes", PasteCheck.probes(for: "Hello there, this is a fairly long dictated message about Deepwoken.").joined(separator: "|"),
              "hellotherethisisafairlylongdicta|ongdictatedmessageaboutdeepwoken")
        let now = Date()
        let aged = [8.0, 6.9, 0.1].map { days in
            HistoryItem(date: now.addingTimeInterval(-days * 86400), text: "\(days)", raw: "", appName: "", duration: 1, outcome: .pasted)
        }
        let gone = HistoryStore.expired(aged, now: now)
        check("history forgets after a week", aged.filter { gone.contains($0.id) }.map(\.text).joined(separator: ","), "8.0")
        let oldFile = #"[{"id":"9E2A0F4C-3B1D-4C55-9D7E-2F1A6B0C8D11","date":"2026-11-08T06:05:29Z","text":"hi","raw":"hi","appName":"","duration":1,"outcome":"copied"}]"#
        check("old history files still load", (try? JSONDecoder.iso.decode([HistoryItem].self, from: Data(oldFile.utf8)))?.first.map { "\($0.outcome)" } ?? "nil", "notPasted")

        print(failures == 0 ? "all passed" : "\(failures) failed")
        return failures == 0
    }
}
