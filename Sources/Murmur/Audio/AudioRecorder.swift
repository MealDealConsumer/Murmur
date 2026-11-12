import AVFoundation
import Foundation

/* Records the default microphone into one growing 16 kHz buffer. When the input device changes the engine
is rebuilt and recording carries on into the same buffer so switching headphones never loses what was said. */
final class AudioRecorder {
    enum RecorderError: LocalizedError {
        case noInput, notAllowed, failed(String)
        var errorDescription: String? {
            switch self {
            case .noInput: return "No microphone found"
            case .notAllowed: return "Microphone access is off"
            case .failed(let s): return s
            }
        }
    }

    var onLevel: ((Float) -> Void)?
    var onProblem: ((String) -> Void)?

    private var engine: AVAudioEngine?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var samples: [Float] = []
    private var recording = false
    private var lastBuffer = Date()
    private var configObserver: NSObjectProtocol?
    private var watchdog: Timer?
    private var restarting = false
    private var restartsWithoutAudio = 0
    private(set) var deviceName = ""

    var isRecording: Bool { lock.withLock { recording } }
    var sampleCount: Int { lock.withLock { samples.count } }

    func copySamples() -> [Float] { lock.withLock { samples } }

    func copySamples(_ range: Range<Int>) -> [Float] {
        lock.withLock {
            let r = range.clamped(to: 0..<samples.count)
            return Array(samples[r])
        }
    }

    func start() throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw RecorderError.notAllowed }
        lock.withLock {
            samples = []
            samples.reserveCapacity(16000 * 120)
            recording = true
        }
        do {
            try buildEngine()
        } catch {
            lock.withLock { recording = false }
            throw error
        }
        lastBuffer = Date()
        restartsWithoutAudio = 0
        watchdog?.invalidate()
        watchdog = commonTimer(1, repeats: true) { [weak self] _ in self?.checkAlive() }
    }

    // Test hooks that stand in for the microphone so the controller can be driven from a file
    func beginInjected() {
        lock.withLock {
            samples = []
            recording = true
        }
        deviceName = "test file"
    }

    func inject(_ chunk: [Float]) {
        lock.withLock { if recording { samples.append(contentsOf: chunk) } }
    }

    func stop() -> [Float] {
        watchdog?.invalidate()
        watchdog = nil
        teardown()
        return lock.withLock {
            recording = false
            return samples
        }
    }

    private func buildEngine() throws {
        teardown()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInput }
        guard let converter = AVAudioConverter(from: format, to: outFormat) else {
            throw RecorderError.failed("Could not read this microphone format")
        }
        // Each tap keeps its own converter so a restart on main never swaps it under the audio thread
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.consume(buffer, with: converter)
        }
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.restart(reason: "audio device changed")
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.failed("Microphone would not start: \(error.localizedDescription)")
        }
        self.engine = engine
        deviceName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "Microphone"
        Log.info("recording from \(deviceName) at \(Int(format.sampleRate)) Hz \(format.channelCount) ch")
    }

    private func teardown() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }

    private func consume(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) {
        guard let converted = try? WavIO.convert(buffer, with: converter, to: outFormat), !converted.isEmpty else { return }
        let level = WavIO.rms(converted[...])
        let live = lock.withLock { () -> Bool in
            guard recording else { return false }
            samples.append(contentsOf: converted)
            return true
        }
        guard live else { return }
        DispatchQueue.main.async {
            self.lastBuffer = Date()
            self.restartsWithoutAudio = 0
            self.onLevel?(level)
        }
    }

    private func restart(reason: String) {
        guard isRecording, !restarting else { return }
        restarting = true
        Log.info("restarting microphone because \(reason)")
        // A short pause lets a Bluetooth headset finish switching profiles before reopening it
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            defer { self.restarting = false }
            guard self.isRecording else { return }
            do {
                try self.buildEngine()
                self.lastBuffer = Date()
            } catch {
                Log.info("microphone restart failed \(error)")
                self.onProblem?("Microphone dropped out")
            }
        }
    }

    private func checkAlive() {
        guard isRecording, Date().timeIntervalSince(lastBuffer) > 2 else { return }
        // One silent restart is normal for a headset switching over but a second means the mic is gone
        if restartsWithoutAudio >= 1 { onProblem?("Microphone is not sending sound") }
        restartsWithoutAudio += 1
        lastBuffer = Date()
        restart(reason: "no audio for two seconds")
    }
}
