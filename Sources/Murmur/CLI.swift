import AppKit

// Developer entry points so the pipeline can be exercised without the microphone or permissions
enum CLI {
    static func run(_ args: [String]) -> Bool {
        guard let command = args.first, command.hasPrefix("--") else { return false }
        Log.echo = true
        let rest = Array(args.dropFirst())
        switch command {
        case "--transcribe":
            transcribe(rest)
        case "--process":
            process(rest.joined(separator: " "))
        case "--learn":
            guard rest.count == 2 else { print("usage: --learn <pasted> <edited>"); break }
            for c in EditLearner.corrections(original: rest[0], edited: rest[1]) {
                print("\(c.heard) -> \(c.correct)")
            }
        case "--import-voiceink":
            guard let path = rest.first else { break }
            let n = VocabularyStore.shared.importVoiceInkFile(URL(fileURLWithPath: path))
            print("imported \(n) entries, dictionary now has \(VocabularyStore.shared.snapshot().count)")
        case "--dictionary":
            exit(DictionaryBridge.command(rest))
        case "--paste-check":
            var words = rest
            var app = NSWorkspace.shared.frontmostApplication
            if words.count > 1, words[0] == "--app" {
                app = NSRunningApplication.runningApplications(withBundleIdentifier: words[1]).first
                words.removeFirst(2)
            }
            if let app { AX.prepare(app: app) }
            let start = Date()
            let r = PasteCheck.check(text: words.joined(separator: " "), original: nil, pid: app?.processIdentifier)
            print("\(app?.bundleIdentifier ?? "?") landed=\(r.landed) readable=\(r.readable) saw \(r.detail) in \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
        case "--add-term":
            guard let term = rest.first else { break }
            VocabularyStore.shared.add(term: term, heardAs: Array(rest.dropFirst()), source: .imported)
            print("added \(term)")
        case "--selftest":
            exit(SelfTest.run() ? 0 : 1)
        case "--render-ui":
            Snapshots.render(to: URL(fileURLWithPath: rest.first ?? "ui-snapshots"))
        case "--diag":
            Snapshots.diagnose()
        case "--live-test":
            DevTests.liveTest()
        case "--e2e-test":
            DevTests.endToEnd(rest.first ?? "")
        case "--limit-test":
            DevTests.limitTest(rest.first ?? "")
        default:
            // An unknown flag must never fall through and start a second copy of the whole app
            print("unknown option \(command)")
            exit(1)
        }
        LLMService.shared.stop()
        return true
    }

    private static func transcribe(_ files: [String]) {
        let usePrompt = !files.contains("--no-prompt")
        if files.contains("--greedy") { WhisperEngine.shared.tuning.beamSize = 1 }
        if files.contains("--no-agc") { WhisperEngine.shared.tuning.autoGain = false }
        if let i = files.firstIndex(of: "--vad"), i + 1 < files.count, let v = Float(files[i + 1]) {
            WhisperEngine.shared.tuning.vadThreshold = v
        }
        let paths = files.filter { !$0.hasPrefix("--") && Float($0) == nil }
        guard WhisperEngine.shared.loadIfNeeded() else { print("model failed to load"); return }
        let prompt = usePrompt ? VocabularyStore.shared.whisperPrompt() : ""
        for path in paths {
            do {
                let samples = try WavIO.read16kMono(URL(fileURLWithPath: path))
                let start = Date()
                var pieces: [String] = []
                for range in Chunker.split(samples) {
                    let piecePrompt = Chunker.prompt(vocabulary: prompt, previous: pieces.last ?? "")
                    pieces.append(WhisperEngine.shared.transcribe(Array(samples[range]), prompt: piecePrompt) ?? "")
                }
                let raw = pieces.filter { !$0.isEmpty }.joined(separator: " ")
                let asr = Date().timeIntervalSince(start)
                let result = runBlocking {
                    await TextPipeline.process(raw: raw, store: VocabularyStore.shared, corrections: true, llm: LLMService.shared)
                }
                let total = Date().timeIntervalSince(start)
                let seconds = Double(samples.count) / 16000
                print("FILE \(URL(fileURLWithPath: path).lastPathComponent) audio=\(String(format: "%.1f", seconds))s asr=\(String(format: "%.2f", asr))s total=\(String(format: "%.2f", total))s model=\(result.usedModel)")
                print("RAW  \(raw)")
                print("OUT  \(result.text)")
                if !result.learned.isEmpty { print("LEARNED \(result.learned.map { "\($0.heard) -> \($0.correct)" })") }
            } catch {
                print("FILE \(path) error \(error)")
            }
        }
    }

    private static func process(_ text: String) {
        let start = Date()
        let result = runBlocking {
            await TextPipeline.process(raw: text, store: VocabularyStore.shared, corrections: true, llm: LLMService.shared)
        }
        print("OUT  \(result.text)")
        print("MODEL \(result.usedModel) \(result.modelError ?? "") \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
        if !result.learned.isEmpty { print("LEARNED \(result.learned.map { "\($0.heard) -> \($0.correct)" })") }
    }

    // The pipeline hops to the main actor so the main run loop has to keep spinning while it waits
    static func runBlocking<T>(_ body: @escaping () async -> T) -> T {
        var value: T?
        Task { value = await body() }
        while value == nil {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return value!
    }
}
