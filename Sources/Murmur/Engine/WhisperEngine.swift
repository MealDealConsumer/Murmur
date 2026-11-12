import Foundation
import whisper

// One loaded model shared by everything and whisper_full is not reentrant so all calls go through one queue
final class WhisperEngine {
    static let shared = WhisperEngine()

    struct Tuning {
        var beamSize = 5
        var vadThreshold: Float = 0.35
        var autoGain = true
    }
    var tuning = Tuning()

    let queue = DispatchQueue(label: "murmur.whisper", qos: .userInitiated)
    private var ctx: OpaquePointer?
    private var loadError: String?

    var isLoaded: Bool { queue.sync { ctx != nil } }

    func loadIfNeeded() -> Bool {
        queue.sync { loadLocked() }
    }

    private func loadLocked() -> Bool {
        if ctx != nil { return true }
        let path = Paths.whisperModel.path
        guard FileManager.default.fileExists(atPath: path) else {
            loadError = "Speech model is missing"
            return false
        }
        whisper_log_set({ _, _, _ in }, nil)
        var cparams = whisper_context_default_params()
        cparams.use_gpu = true
        cparams.flash_attn = true
        let start = Date()
        ctx = whisper_init_from_file_with_params(path, cparams)
        if ctx == nil {
            loadError = "Speech model failed to load"
            return false
        }
        Log.info("whisper loaded in \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
        return true
    }

    // The Metal device asserts at exit if a model still holds its buffers so this has to run before quitting
    func unload() {
        queue.sync {
            if let ctx { whisper_free(ctx) }
            ctx = nil
        }
    }

    /* Blocking call that must not run on the main thread. Nil means whisper failed rather than heard nothing so the
    caller can keep the audio for a retry. */
    func transcribe(_ input: [Float], prompt: String, language: String = "en") -> String? {
        queue.sync { transcribeLocked(input, prompt: prompt, language: language) }
    }

    private func transcribeLocked(_ input: [Float], prompt: String, language: String) -> String? {
        guard loadLocked(), let ctx else { return nil }
        var samples = tuning.autoGain ? Self.normalize(input) : input
        // whisper warns below one second and tends to invent words on very short clips
        if samples.count < 17600 { samples.append(contentsOf: [Float](repeating: 0, count: 17600 - samples.count)) }

        var p = whisper_full_default_params(tuning.beamSize > 1 ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY)
        if tuning.beamSize > 1 { p.beam_search.beam_size = Int32(tuning.beamSize) }
        p.n_threads = Int32(max(4, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        p.no_context = true
        p.no_timestamps = false
        p.print_special = false
        p.print_progress = false
        p.print_realtime = false
        p.print_timestamps = false
        p.suppress_blank = true
        p.suppress_nst = true
        p.carry_initial_prompt = !prompt.isEmpty

        let promptC = strdup(prompt)
        let langC = strdup(language)
        let vadPath = Paths.vadModel.path
        let useVad = FileManager.default.fileExists(atPath: vadPath)
        let vadC = strdup(vadPath)
        defer { free(promptC); free(langC); free(vadC) }

        p.initial_prompt = prompt.isEmpty ? nil : UnsafePointer(promptC)
        p.language = UnsafePointer(langC)
        if useVad {
            p.vad = true
            p.vad_model_path = UnsafePointer(vadC)
            var vp = whisper_vad_default_params()
            vp.threshold = tuning.vadThreshold
            vp.min_silence_duration_ms = 500
            vp.speech_pad_ms = 200
            p.vad_params = vp
        }

        let status = samples.withUnsafeBufferPointer { buf in
            whisper_full(ctx, p, buf.baseAddress, Int32(buf.count))
        }
        guard status == 0 else {
            Log.info("whisper_full failed with \(status)")
            return nil
        }
        var parts: [String] = []
        for i in 0..<whisper_full_n_segments(ctx) {
            guard let cstr = whisper_full_get_segment_text(ctx, i) else { continue }
            let text = String(cString: cstr).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || Self.isNoiseMarker(text) { continue }
            parts.append(text)
        }
        return parts.joined(separator: " ")
    }

    /* Whispered or distant speech is lifted towards normal speaking level before the silence detector sees it.
    Only boosts and never above 30x so room noise on its own stays quiet enough to be ignored. */
    static func normalize(_ input: [Float]) -> [Float] {
        let frame = 480
        guard input.count > frame * 4 else { return input }
        var levels: [Float] = []
        levels.reserveCapacity(input.count / frame)
        var i = 0
        while i + frame <= input.count {
            levels.append(WavIO.rms(input[i..<(i + frame)]))
            i += frame
        }
        levels.sort()
        let speech = levels[Int(Double(levels.count) * 0.9)]
        let floor = levels[Int(Double(levels.count) * 0.1)]
        // Pure room noise has no gap between its loud and quiet frames and boosting it invites invented words
        guard speech > 0.0008, speech > floor * 3 else { return input }
        let gain = min(30, max(1, 0.06 / speech))
        guard gain > 1.05 else { return input }
        return input.map { x in
            let y = x * gain
            return y > 0.95 ? 0.95 + (y - 0.95) * 0.05 : (y < -0.95 ? -0.95 + (y + 0.95) * 0.05 : y)
        }
    }

    // whisper sometimes emits bracketed sound labels instead of words
    static func isNoiseMarker(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        if (t.hasPrefix("[") && t.hasSuffix("]")) || (t.hasPrefix("(") && t.hasSuffix(")")) || (t.hasPrefix("*") && t.hasSuffix("*")) {
            return true
        }
        return false
    }
}
