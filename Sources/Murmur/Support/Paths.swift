import Foundation

enum Paths {
    static let appSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ensure(base.appendingPathComponent("Murmur", isDirectory: true))
    }()

    static var models: URL { ensure(appSupport.appendingPathComponent("Models", isDirectory: true)) }
    static var recordings: URL { ensure(dataDir.appendingPathComponent("Recordings", isDirectory: true)) }
    static var logs: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return ensure(base.appendingPathComponent("Logs/Murmur", isDirectory: true))
    }

    // Tests point this somewhere disposable so they never touch the real dictionary history or recordings
    static var dataDir: URL {
        if let dir = ProcessInfo.processInfo.environment["MURMUR_DATA_DIR"] { return ensure(URL(fileURLWithPath: dir)) }
        return appSupport
    }
    static var dictionaryFile: URL { dataDir.appendingPathComponent("dictionary.json") }
    static var historyFile: URL { dataDir.appendingPathComponent("history.json") }

    static var whisperModel: URL { models.appendingPathComponent(ModelCatalog.whisper.fileName) }
    static var vadModel: URL { models.appendingPathComponent(ModelCatalog.vad.fileName) }
    static var llmModel: URL { models.appendingPathComponent(ModelCatalog.llm.fileName) }

    // Inside the app bundle the server sits in Resources and in a dev build it sits in Vendor
    static var llamaServer: URL? {
        if let res = Bundle.main.resourceURL?.appendingPathComponent("llama/llama-server"),
           FileManager.default.isExecutableFile(atPath: res.path) {
            return res
        }
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let dev = repo.appendingPathComponent("Vendor/llama/llama-server")
        return FileManager.default.isExecutableFile(atPath: dev.path) ? dev : nil
    }

    @discardableResult
    static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

struct ModelFile {
    let fileName: String
    let url: URL
    let approxBytes: Int64
    let label: String
}

enum ModelCatalog {
    static let whisper = ModelFile(
        fileName: "ggml-large-v3-turbo-q8_0.bin",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q8_0.bin")!,
        approxBytes: 874_188_075,
        label: "Speech model (Whisper large v3 turbo)")
    static let vad = ModelFile(
        fileName: "ggml-silero-v6.2.0.bin",
        url: URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin")!,
        approxBytes: 885_098,
        label: "Silence detector (Silero VAD)")
    static let llm = ModelFile(
        fileName: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
        url: URL(string: "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf")!,
        approxBytes: 2_497_281_120,
        label: "Correction model (Qwen3 4B Instruct)")
    static let all = [whisper, vad, llm]
}
