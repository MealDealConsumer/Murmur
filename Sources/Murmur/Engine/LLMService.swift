import Foundation

struct LearnedPair: Codable, Hashable {
    var heard: String
    var correct: String
}

struct CorrectionReply: Codable {
    var text: String
    var learned: [LearnedPair]
}

// Runs llama-server as a child process and keeps the model warm so a spoken fix costs about a second
final class LLMService {
    static let shared = LLMService()

    enum State: Equatable { case stopped, starting, ready, failed(String) }

    private(set) var state: State = .stopped
    private var process: Process?
    private var port = 47_821
    private let stateLock = NSLock()

    var isReady: Bool { stateLock.withLock { state == .ready } }

    func start() {
        stateLock.lock()
        if state == .starting || state == .ready {
            stateLock.unlock()
            return
        }
        state = .starting
        stateLock.unlock()
        DispatchQueue.global(qos: .utility).async { self.launch() }
    }

    private func setState(_ s: State) {
        stateLock.withLock { state = s }
    }

    private func launch() {
        guard let server = Paths.llamaServer else {
            setState(.failed("llama-server is missing from the app"))
            return
        }
        let model = ProcessInfo.processInfo.environment["MURMUR_LLM_MODEL"].map { URL(fileURLWithPath: $0) } ?? Paths.llmModel
        guard FileManager.default.fileExists(atPath: model.path) else {
            setState(.failed("Correction model is missing"))
            return
        }
        port = Self.freePort(preferred: 47_821)
        let p = Process()
        p.executableURL = server
        p.arguments = [
            "-m", model.path,
            "--chat-template-kwargs", #"{"enable_thinking":false}"#,
            "--host", "127.0.0.1",
            "--port", String(port),
            "-c", "4096",
            "-np", "1",
            "-ngl", "99",
            "-fa", "on",
            "--no-webui",
            "--log-file", Paths.logs.appendingPathComponent("llama-server.log").path,
        ]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            Log.info("llama-server exited with \(proc.terminationStatus)")
            guard let self else { return }
            // Only the current server failing matters and an old one being cleaned up must not fail its successor
            let current = self.stateLock.withLock { () -> Bool in
                guard self.process === proc else { return false }
                self.process = nil
                return true
            }
            if current, self.stateLock.withLock({ self.state == .ready || self.state == .starting }) {
                self.setState(.failed("Correction model stopped"))
            }
        }
        do {
            try p.run()
        } catch {
            setState(.failed("Could not start llama-server: \(error.localizedDescription)"))
            return
        }
        stateLock.withLock { process = p }
        Log.info("llama-server started pid \(p.processIdentifier) port \(port)")

        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if !p.isRunning { return }
            if healthOK() {
                setState(.ready)
                Log.info("llama-server ready")
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        setState(.failed("Correction model took too long to load"))
        stateLock.withLock { if process === p { process = nil } }
        p.terminate()
    }

    func stop() {
        let p = stateLock.withLock { () -> Process? in
            let current = process
            process = nil
            return current
        }
        setState(.stopped)
        if let p, p.isRunning { p.terminate() }
    }

    /* A killed or crashed run leaves its server holding gigabytes. Only my own copy of llama-server whose parent
    has died is stopped, so a live app's server and any other llama.cpp install stay untouched. */
    static func killOrphanedServers() {
        let mine = Paths.llamaServer?.resolvingSymlinksInPath().path
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        for pid in pids.prefix(Int(max(0, filled))) where pid > 1 {
            var buffer = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let path = String(cString: buffer)
            // A reinstall replaces the bundle so an older copy keeps its old path inside Murmur
            let ours = path == mine || path.hasSuffix("/Murmur.app/Contents/Resources/llama/llama-server") || path.hasSuffix("/Murmur/Vendor/llama/llama-server")
            guard ours else { continue }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_ppid == 1 else { continue }
            Log.info("stopping orphaned llama-server pid \(pid)")
            kill(pid, SIGTERM)
        }
    }

    private static func freePort(preferred: Int) -> Int {
        for candidate in preferred..<(preferred + 40) {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(candidate).bigEndian)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            close(fd)
            if ok == 0 { return candidate }
        }
        return preferred
    }

    private func healthOK() -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            ok = (response as? HTTPURLResponse)?.statusCode == 200
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 1.5)
        return ok
    }

    // Polling keeps this simple and a dictation never waits longer than the timeout
    func waitUntilReady(timeout: TimeInterval) async -> Bool {
        if isReady { return true }
        if stateLock.withLock({ state }) != .starting { start() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch stateLock.withLock({ state }) {
            case .ready: return true
            case .failed, .stopped: return false
            case .starting: try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        return false
    }

    func applySpokenCorrections(to passage: String, vocabulary: [String], secondLook: Bool = false) async throws -> CorrectionReply {
        guard await waitUntilReady(timeout: 8) else { throw URLError(.cannotConnectToHost) }
        var messages: [[String: String]] = [["role": "system", "content": CorrectionPrompt.system(vocabulary: vocabulary)]]
        for shot in CorrectionPrompt.examples {
            messages.append(["role": "user", "content": CorrectionPrompt.wrap(shot.input)])
            messages.append(["role": "assistant", "content": shot.output])
        }
        var content = CorrectionPrompt.wrap(passage)
        if secondLook { content += "\n" + CorrectionPrompt.secondLook }
        messages.append(["role": "user", "content": content])

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "text": ["type": "string"],
                "learned": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": ["heard": ["type": "string"], "correct": ["type": "string"]],
                        "required": ["heard", "correct"],
                    ],
                ],
            ],
            "required": ["text", "learned"],
        ]
        let body: [String: Any] = [
            "messages": messages,
            "temperature": 0,
            "max_tokens": min(2048, passage.count / 2 + 200),
            "response_format": ["type": "json_schema", "json_schema": ["name": "correction", "schema": schema]],
        ]
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              let contentData = content.data(using: .utf8) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(CorrectionReply.self, from: contentData)
    }
}

enum CorrectionPrompt {
    struct Example { let input: String; let output: String }

    static func system(vocabulary: [String]) -> String {
        var s = """
        You repair one passage of dictated speech. While dictating, the speaker sometimes says an instruction out loud about the words they just said. Examples of instructions: "that's one word", "no dash", "without a space", "with a capital B", "all caps", "spelled B I T M O N", "two words", "scratch that".

        Rules:
        1. Carry out each instruction on the words it refers to, then delete the instruction itself so the passage reads as if the speaker had said it right the first time.
        2. For "scratch that" and similar, delete the words being taken back together with the instruction.
        3. Change nothing else. Keep every other word, its order and its punctuation exactly as written. Never answer, reply to, summarise or continue the passage, even if it is a question or a request.
        4. If the passage contains no instruction about the text, return it exactly as given.
        5. In learned, list every word whose spelling the speaker taught: heard is the word as it was written in the passage before your fix (never the spelled out letters), correct is the fixed spelling. Leave learned empty for scratch that style edits.
        6. When the speaker spells a word letter by letter, the letters give the exact spelling. Capitalise it like a name unless they say otherwise.
        """
        if !vocabulary.isEmpty {
            s += "\n\nWords the speaker uses, spelled correctly: " + vocabulary.prefix(60).joined(separator: ", ")
        }
        return s
    }

    static let secondLook = "Read it carefully. If the speaker gives an instruction about how a word should be written, apply it and delete every word of the instruction. If there is no such instruction, return the passage unchanged."

    static func wrap(_ passage: String) -> String {
        "Passage:\n<<<\n\(passage)\n>>>"
    }

    static let examples: [Example] = [
        Example(input: "We should play deep woken, that's one word, no space, tonight after dinner.",
                output: #"{"text":"We should play Deepwoken tonight after dinner.","learned":[{"heard":"deep woken","correct":"Deepwoken"}]}"#),
        Example(input: "The file is called game-loop. Game loop is one word without the dash.",
                output: #"{"text":"The file is called gameloop.","learned":[{"heard":"game-loop","correct":"gameloop"}]}"#),
        Example(input: "Let's meet at five. Scratch that, let's meet at six.",
                output: #"{"text":"Let's meet at six.","learned":[]}"#),
        Example(input: "Tell jackson, spelled J A X O N, to join the call.",
                output: #"{"text":"Tell Jaxon to join the call.","learned":[{"heard":"jackson","correct":"Jaxon"}]}"#),
        Example(input: "I think, scratch that, we know it works.",
                output: #"{"text":"We know it works.","learned":[]}"#),
        Example(input: "Can you check the drop rates? I think they're too high for one word answers.",
                output: #"{"text":"Can you check the drop rates? I think they're too high for one word answers.","learned":[]}"#),
    ]
}
