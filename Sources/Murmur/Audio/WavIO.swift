import AVFoundation
import Foundation

enum WavIO {
    enum WavError: Error { case unreadable, convert }

    // Reads any audio file AVFoundation understands and returns 16 kHz mono floats
    static func read16kMono(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else { throw WavError.convert }
        var result: [Float] = []
        let chunk: AVAudioFramePosition = 16384
        // AVAudioFile throws instead of returning zero frames when asked to read past the end
        while file.framePosition < file.length {
            let count = AVAudioFrameCount(min(chunk, file.length - file.framePosition))
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: count) else { throw WavError.unreadable }
            try file.read(into: inBuf, frameCount: count)
            if inBuf.frameLength == 0 { break }
            result.append(contentsOf: try convert(inBuf, with: converter, to: outFormat))
        }
        return result
    }

    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to outFormat: AVAudioFormat) throws -> [Float] {
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { throw WavError.convert }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error { throw error ?? WavError.convert }
        guard let data = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
    }

    static func write16kMono(_ samples: [Float], to url: URL) throws {
        var data = Data()
        let byteCount = UInt32(samples.count * 2)
        func u32(_ v: UInt32) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 2)) }
        data.append("RIFF".data(using: .ascii)!)
        u32(36 + byteCount)
        data.append("WAVEfmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        data.append("data".data(using: .ascii)!)
        u32(byteCount)
        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            pcm[i] = Int16(max(-1, min(1, samples[i])) * 32767)
        }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url, options: .atomic)
    }

    static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }
}
