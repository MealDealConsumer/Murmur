import AppKit
import AVFoundation
import Combine

// Transcribed pieces of the current recording, written from the piece queue and read at the end
final class PieceBuffer {
    private let lock = NSLock()
    private var session = 0
    private var texts: [String] = []
    private var failures = 0

    func reset(_ s: Int) { lock.withLock { session = s; texts = []; failures = 0 } }
    func isCurrent(_ s: Int) -> Bool { lock.withLock { session == s } }
    func append(_ text: String?, session s: Int) {
        lock.withLock {
            guard session == s else { return }
            if let text { texts.append(text) } else { failures += 1 }
        }
    }
    var lastText: String { lock.withLock { texts.last { !$0.isEmpty } ?? "" } }
    var joined: String { lock.withLock { texts.filter { !$0.isEmpty }.joined(separator: " ") } }
    var failed: Bool { lock.withLock { failures > 0 } }
}

final class DictationController: ObservableObject {
    enum Phase { case idle, recording, processing }

    static let shared = DictationController()
    static let warnings: [(at: TimeInterval, text: String)] = [(15 * 60, "Five minutes left"), (19 * 60, "One minute left")]
    static let maxDuration: TimeInterval = 20 * 60

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var hotkeyActive = false

    let recorder = AudioRecorder()
    let hotkeys = HotkeyMonitor()
    let overlay = OverlayController()
    let editWatcher = EditWatcher()
    let missedCard = MissedPasteCard()

    private let settings = AppSettings.shared
    private let vocab = VocabularyStore.shared
    private let history = HistoryStore.shared
    private let pieces = PieceBuffer()
    private let pieceQueue = DispatchQueue(label: "murmur.pieces", qos: .userInitiated)
    private var session = 0
    private var cursor = 0
    private var startedAt = Date()
    private var tickTimer: Timer?
    private var trustTimer: Timer?
    private var warningsGiven = 0
    private var injected = false
    private(set) var chimes = 0
    var muteChime = false
    private var vocabPrompt = ""
    private var language = "en"
    private var handsFree = false
    private var stopOnRelease = false
    private var processingAudio: (name: String, duration: Double)?
    private var subs = Set<AnyCancellable>()

    // A test file plays in fast so its own length is the clock
    var elapsed: TimeInterval { injected ? Double(recorder.sampleCount) / 16000 : Date().timeIntervalSince(startedAt) }

    private init() {
        hotkeys.onEvent = { [weak self] e in self?.handle(e) }
        hotkeys.onEscape = { [weak self] in self?.cancel(silent: false) }
        hotkeys.onPasteLast = { [weak self] in self?.pasteLast() }
        // Pasting the text by hand means the card has done its job
        hotkeys.onCommandV = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.missedCard.hide() }
        }
        recorder.onLevel = { [weak self] level in self?.overlay.level(level) }
        recorder.onProblem = { [weak self] message in
            guard let self, self.phase == .recording else { return }
            self.flashWarning(message)
        }
        editWatcher.onLearned = { [weak self] pairs in self?.learned(pairs, source: .learnedEdit) }
        settings.$shortcut.sink { [weak self] s in self?.hotkeys.shortcut = s }.store(in: &subs)
        settings.$mode.sink { [weak self] m in self?.hotkeys.spaceLatches = m == .holdHandsFree }.store(in: &subs)
        settings.$spokenCorrections.sink { on in
            if on { LLMService.shared.start() } else { LLMService.shared.stop() }
        }.store(in: &subs)
    }

    func launch() {
        hotkeys.shortcut = settings.shortcut
        installHotkeys()
        overlay.show(.idle)
        DispatchQueue.global(qos: .userInitiated).async { _ = WhisperEngine.shared.loadIfNeeded() }
    }

    // The event tap needs Accessibility so it is retried until the permission lands
    func installHotkeys() {
        trustTimer?.invalidate()
        if AX.trusted, hotkeys.start() {
            hotkeyActive = true
            return
        }
        hotkeyActive = false
        trustTimer = commonTimer(1.5, repeats: true) { [weak self] timer in
            guard let self, AX.trusted else { return }
            if self.hotkeys.start() {
                self.hotkeyActive = true
                timer.invalidate()
            }
        }
    }

    private func handle(_ e: HotkeyMonitor.Event) {
        let isModifier = settings.shortcut.kind == .modifier
        switch settings.mode {
        case .toggle:
            switch e {
            case .down where !isModifier: toggle()
            case .up(let interrupted) where isModifier && !interrupted: toggle()
            default: break
            }
        case .hold:
            switch e {
            case .down:
                if phase == .idle { startRecording() } else if phase == .processing { busyNote() }
            case .interrupted:
                if phase == .recording, elapsed < 0.6 { cancel(silent: true) }
            case .up:
                guard phase == .recording else { return }
                if elapsed < 0.3 { cancel(silent: true) } else { stopRecording() }
            case .space:
                break
            }
        case .holdHandsFree:
            handleHoldHandsFree(e)
        }
    }

    /* Holding the key talks and letting go pastes. Space while holding latches hands free so the key can be let go,
    and a clean tap of the key afterwards finishes. A tap that was part of a chord such as fn and an arrow is ignored. */
    private func handleHoldHandsFree(_ e: HotkeyMonitor.Event) {
        switch e {
        case .down:
            switch phase {
            case .idle:
                handsFree = false
                stopOnRelease = false
                startRecording()
            case .recording where handsFree:
                stopOnRelease = true
            case .processing:
                busyNote()
            default:
                break
            }
        case .space:
            guard phase == .recording, !handsFree else { return }
            handsFree = true
            overlay.show(.message("Hands free, tap \(settings.shortcut.kind == .modifier ? "the key" : "the shortcut") to finish", symbol: "lock.fill"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                if self?.phase == .recording { self?.overlay.show(.listening) }
            }
        case .interrupted:
            if phase == .recording, !handsFree, elapsed < 0.6 { cancel(silent: true) }
        case .up(let interrupted):
            guard phase == .recording else { return }
            if handsFree {
                guard stopOnRelease else { return }
                stopOnRelease = false
                if !interrupted { stopRecording() }
            } else if elapsed < 0.3 {
                cancel(silent: true)
            } else {
                stopRecording()
            }
        }
    }

    func toggle() {
        switch phase {
        case .idle: startRecording()
        case .recording: stopRecording()
        case .processing: busyNote()
        }
    }

    // A press while the last dictation is still being written is acknowledged so nobody talks into nothing
    private func busyNote() {
        overlay.show(.message("Still working on the last one", symbol: "hourglass"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            if self?.phase == .processing { self?.overlay.show(.working) }
        }
    }

    func startRecording() {
        guard phase == .idle else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            return
        default:
            flash(.warning("Microphone access is off"), seconds: 2.5)
            AppDelegate.shared?.showWindow(tab: .setup)
            return
        }
        guard FileManager.default.fileExists(atPath: Paths.whisperModel.path) else {
            flash(.warning("Speech model not downloaded"), seconds: 2.5)
            AppDelegate.shared?.showWindow(tab: .setup)
            return
        }
        editWatcher.finish()
        missedCard.hide()
        session += 1
        cursor = 0
        pieces.reset(session)
        vocabPrompt = vocab.whisperPrompt()
        language = settings.language
        do {
            try recorder.start()
        } catch {
            flash(.warning(error.localizedDescription), seconds: 2.5)
            return
        }
        startedAt = Date()
        warningsGiven = 0
        injected = false
        phase = .recording
        hotkeys.escapeActive = true
        overlay.show(.listening)
        if settings.playSounds { NSSound(named: "Tink")?.play() }
        tickTimer?.invalidate()
        tickTimer = commonTimer(1, repeats: true) { [weak self] _ in self?.tick() }
        Log.info("recording started")
    }

    private func tick() {
        guard phase == .recording else { return }
        if elapsed >= Self.maxDuration {
            Log.info("hit the twenty minute limit")
            stopRecording(limitReached: true)
            return
        }
        if warningsGiven < Self.warnings.count, elapsed >= Self.warnings[warningsGiven].at {
            flashWarning(Self.warnings[warningsGiven].text, chime: true)
            warningsGiven += 1
        }
        // Finished pieces are transcribed while the speaker keeps going so stopping only waits on the tail
        let count = recorder.sampleCount
        guard count - cursor >= Chunker.ready else { return }
        let region = recorder.copySamples(cursor..<count)
        if let cut = Chunker.nextCut(region, start: 0, end: region.count) {
            enqueue(Array(region[0..<cut]), session: session)
            cursor += cut
        }
    }

    private func enqueue(_ samples: [Float], session s: Int) {
        let prompt = vocabPrompt
        let language = language
        let pieces = pieces
        pieceQueue.async {
            guard pieces.isCurrent(s) else { return }
            let text = WhisperEngine.shared.transcribe(samples, prompt: Chunker.prompt(vocabulary: prompt, previous: pieces.lastText), language: language)
            pieces.append(text, session: s)
        }
    }

    private func newAudioName() -> String { "\(Int(Date().timeIntervalSince1970))-\(session).wav" }

    // Written straight away so quitting or crashing during processing can never lose what was said
    private func saveAudio(_ samples: [Float]) -> String? {
        let name = newAudioName()
        do {
            try WavIO.write16kMono(samples, to: Paths.recordings.appendingPathComponent(name))
            return name
        } catch {
            Log.info("could not save audio \(error)")
            return nil
        }
    }

    func stopRecording(limitReached: Bool = false) {
        guard phase == .recording else { return }
        tickTimer?.invalidate()
        hotkeys.escapeActive = false
        let all = recorder.stop()
        let duration = Double(all.count) / 16000
        Log.info("recording stopped after \(String(format: "%.1f", duration))s")
        guard duration >= 0.3 else {
            phase = .idle
            overlay.show(.idle)
            return
        }
        phase = .processing
        overlay.show(.working)
        if settings.playSounds { NSSound(named: "Pop")?.play() }
        let s = session
        let audioName = saveAudio(all)
        processingAudio = audioName.map { ($0, duration) }
        // The tail can run past one window if the timer was held up so it is cut the same way
        let tail = Array(all[min(cursor, all.count)...])
        for range in Chunker.split(tail) { enqueue(Array(tail[range]), session: s) }
        let pieces = pieces
        pieceQueue.async { [weak self] in
            let raw = pieces.joined
            let partial = pieces.failed
            DispatchQueue.main.async {
                self?.finish(raw: raw, partial: partial, duration: duration, audioName: audioName, session: s, holdBack: limitReached)
            }
        }
    }

    private func finish(raw: String, partial: Bool, duration: Double, audioName: String?, session s: Int, holdBack: Bool = false) {
        guard s == session else { return }
        Task { @MainActor in
            let result = await TextPipeline.process(raw: raw, store: vocab, corrections: settings.spokenCorrections, llm: LLMService.shared)
            deliver(result, raw: raw, partial: partial, duration: duration, audioName: audioName, holdBack: holdBack)
        }
    }

    private func deliver(_ result: PipelineResult, raw: String, partial: Bool, duration: Double, audioName: String?, holdBack: Bool = false) {
        phase = .idle
        processingAudio = nil
        let text = result.text
        guard !text.isEmpty else {
            history.add(HistoryItem(text: "", raw: raw, appName: "", duration: duration, outcome: partial ? .failed : .empty, audioFile: audioName))
            flash(partial ? .warning("Transcription failed, retry from History") : .message("Didn't catch that", symbol: "ear"), seconds: 2.2)
            return
        }
        // By the limit I may have walked off to another window so it waits in the card and History instead
        if holdBack {
            history.add(HistoryItem(text: text, raw: raw, appName: "", duration: duration, outcome: partial ? .failed : .notPasted, audioFile: audioName))
            missedCard.show(text, title: "Twenty minutes is up")
            if partial {
                flash(.warning("Part of this was missed, retry from History"), seconds: 3)
            } else {
                flash(.message("Twenty minutes is up", symbol: "clock"), seconds: 2.4)
            }
            return
        }
        guard AX.trusted else {
            history.add(HistoryItem(text: text, raw: raw, appName: "", duration: duration, outcome: partial ? .failed : .notPasted, audioFile: audioName))
            missedCard.show(text)
            flash(.message("Nowhere to paste", symbol: "doc.on.doc"), seconds: 1.4)
            return
        }
        TextInserter.insert(text) { [weak self] outcome in
            guard let self else { return }
            let kind: HistoryItem.Outcome = partial ? .failed : (outcome.kind == .pasted ? .pasted : .notPasted)
            let item = HistoryItem(text: text, raw: raw, appName: outcome.focus.appName, duration: duration, outcome: kind, audioFile: audioName)
            self.history.add(item)
            if outcome.kind == .notPasted { self.missedCard.show(text) } else { self.verifyPaste(outcome, item: item) }
            if partial {
                self.flash(.warning("Part of this was missed, retry from History"), seconds: 3)
            } else if !result.learned.isEmpty {
                self.flash(.message("Learned " + result.learned.map(\.correct).joined(separator: ", "), symbol: "text.book.closed"), seconds: 2.4)
            } else if outcome.kind == .pasted {
                self.flash(.message("Pasted", symbol: "checkmark"), seconds: 1.1)
            } else {
                self.flash(.message("Nowhere to paste", symbol: "doc.on.doc"), seconds: 1.8)
            }
            if outcome.kind == .pasted, self.settings.learnFromEdits { self.editWatcher.begin(outcome: outcome) }
        }
    }

    func cancel(silent: Bool) {
        guard phase == .recording else { return }
        tickTimer?.invalidate()
        hotkeys.escapeActive = false
        let all = recorder.stop()
        let duration = Double(all.count) / 16000
        session += 1
        pieces.reset(session)
        phase = .idle
        Log.info("recording cancelled after \(String(format: "%.1f", duration))s")
        if silent {
            overlay.show(.idle)
            return
        }
        // Anything longer than a few seconds is kept so an accidental Esc can be undone from History
        if duration > 3, let name = saveAudio(all) {
            history.add(HistoryItem(text: "", raw: "", appName: "", duration: duration, outcome: .cancelled, audioFile: name))
            flash(.message("Cancelled, the audio is in History", symbol: "xmark"), seconds: 1.8)
        } else {
            flash(.message("Cancelled", symbol: "xmark"), seconds: 1.0)
        }
    }

    private static let pasteCheckGaps: [TimeInterval] = [0.4, 0.6, 1.0]

    /* Reads the field back after pasting and tries again while slow apps catch up. Text that never shows up,
    or a guessed target that cannot be read, goes into the card with a Copy button so it is never lost. */
    private func verifyPaste(_ outcome: InsertOutcome, item: HistoryItem, attempt: Int = 0) {
        let s = session
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pasteCheckGaps[attempt]) { [weak self] in
            let element = outcome.focus.element
            let pid = outcome.focus.app?.processIdentifier
            PasteCheck.queue.async {
                let result = PasteCheck.check(text: item.text, original: element, pid: pid)
                DispatchQueue.main.async {
                    guard let self, s == self.session else { return }
                    if result.landed {
                        TextInserter.pasteLanded(outcome.token)
                        return
                    }
                    if attempt + 1 < Self.pasteCheckGaps.count {
                        self.verifyPaste(outcome, item: item, attempt: attempt + 1)
                        return
                    }
                    guard result.readable || outcome.focus.editable == .unknown else { return }
                    Log.info("paste not confirmed in \(outcome.focus.bundleId) role=\(outcome.focus.role) saw \(result.detail)")
                    var updated = item
                    updated.outcome = .notPasted
                    self.history.replace(updated)
                    self.missedCard.show(item.text)
                }
            }
        }
    }

    // Pastes the newest dictation again wherever the cursor is now
    func pasteLast() {
        guard phase == .idle, let last = history.last else { return }
        // Waiting a moment lets the control and command keys come up before the paste goes out
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            TextInserter.insert(last.text) { [weak self] outcome in
                self?.flash(.message(outcome.kind == .pasted ? "Pasted last" : "Nowhere to paste", symbol: "arrow.uturn.backward"), seconds: 1.1)
            }
        }
    }

    // Called on quit or logout so a live or half processed dictation survives as a History entry
    func saveBeforeQuit() {
        switch phase {
        case .recording:
            tickTimer?.invalidate()
            let all = recorder.stop()
            if all.count > 16000, let name = saveAudio(all) {
                history.add(HistoryItem(text: "", raw: "", appName: "", duration: Double(all.count) / 16000, outcome: .failed, audioFile: name))
            }
        case .processing:
            if let pending = processingAudio {
                history.add(HistoryItem(text: "", raw: "", appName: "", duration: pending.duration, outcome: .failed, audioFile: pending.name))
            }
        case .idle:
            break
        }
        history.saveNow()
    }

    private func learned(_ pairs: [LearnedPair], source: VocabEntry.Source) {
        for p in pairs { vocab.add(term: p.correct, heardAs: [p.heard], source: source) }
        guard phase == .idle else { return }
        flash(.message("Learned " + pairs.map(\.correct).joined(separator: ", "), symbol: "text.book.closed"), seconds: 2.4)
    }

    private func flash(_ state: PillState, seconds: TimeInterval) {
        overlay.show(state, for: seconds)
    }

    private func flashWarning(_ text: String, chime: Bool = false) {
        overlay.show(.warning(text))
        if chime {
            chimes += 1
            if !muteChime { NSSound(named: "Glass")?.play() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.phase == .recording { self?.overlay.show(.listening) }
        }
    }

    // Plays a file in fast as if it were the microphone so the real start, tick, stop and deliver path runs
    func runInjected(_ samples: [Float], secondsPerTick: Double, done: @escaping () -> Void) {
        guard phase == .idle else { return }
        editWatcher.finish()
        session += 1
        cursor = 0
        pieces.reset(session)
        vocabPrompt = vocab.whisperPrompt()
        recorder.beginInjected()
        startedAt = Date()
        warningsGiven = 0
        injected = true
        phase = .recording
        overlay.show(.listening)
        let step = Int(secondsPerTick * 16000)
        var offset = 0
        _ = commonTimer(0.05, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let end = min(samples.count, offset + step)
            self.recorder.inject(Array(samples[offset..<end]))
            offset = end
            self.tick()
            // The limit can stop the recording before the file runs out
            if offset >= samples.count || self.phase != .recording {
                timer.invalidate()
                self.stopRecording()
                _ = commonTimer(0.2, repeats: true) { t in
                    if self.phase == .idle { t.invalidate(); done() }
                }
            }
        }
    }

    // Reruns a saved recording through the whole pipeline and leaves the result in History to copy from
    func retry(_ item: HistoryItem) {
        guard let url = history.audioURL(item) else { return }
        flash(.working, seconds: 60)
        let prompt = vocab.whisperPrompt()
        pieceQueue.async { [weak self] in
            guard let samples = try? WavIO.read16kMono(url) else { return }
            var texts: [String] = []
            var failed = false
            for range in Chunker.split(samples) {
                let text = WhisperEngine.shared.transcribe(Array(samples[range]), prompt: Chunker.prompt(vocabulary: prompt, previous: texts.last ?? ""))
                if text == nil { failed = true }
                texts.append(text ?? "")
            }
            let raw = texts.filter { !$0.isEmpty }.joined(separator: " ")
            Task { @MainActor in
                guard let self else { return }
                let result = await TextPipeline.process(raw: raw, store: self.vocab, corrections: self.settings.spokenCorrections, llm: LLMService.shared)
                var updated = item
                updated.text = result.text
                updated.raw = raw
                updated.outcome = failed ? .failed : (result.text.isEmpty ? .empty : .notPasted)
                self.history.replace(updated)
                if result.text.isEmpty {
                    self.flash(failed ? .warning("Transcription failed again") : .message("Still nothing heard", symbol: "ear"), seconds: 1.8)
                } else {
                    self.flash(.message("Done, click it in History to copy", symbol: "checkmark"), seconds: 1.8)
                }
            }
        }
    }
}
