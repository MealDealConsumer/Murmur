import Foundation

// Whisper loses whole stretches of long audio so recordings are cut at natural pauses into pieces under one 30 second window
enum Chunker {
    static let rate = 16_000
    static let frame = 480
    static let earliest = 12 * rate
    static let ready = 20 * rate
    static let latest = 28 * rate

    // Returns where the next piece should end or nil when there is not enough audio yet
    static func nextCut(_ samples: [Float], start: Int, end: Int) -> Int? {
        let available = end - start
        guard available >= ready else { return nil }
        let lo = start + earliest
        let hi = min(end - frame, start + latest)
        guard hi > lo else { return nil }

        var energies: [Float] = []
        var index = lo
        while index + frame <= hi {
            energies.append(WavIO.rms(samples[index..<(index + frame)]))
            index += frame
        }
        guard !energies.isEmpty else { return nil }
        let sorted = energies.sorted()
        let floor = sorted[sorted.count / 10]
        let threshold = max(floor * 2.5, 0.002)

        var bestStart = -1, bestLength = 0
        var runStart = -1
        for (i, e) in energies.enumerated() {
            if e < threshold {
                if runStart < 0 { runStart = i }
                let length = i - runStart + 1
                if length >= bestLength {
                    bestLength = length
                    bestStart = runStart
                }
            } else {
                runStart = -1
            }
        }
        if bestLength >= 8 {
            return lo + (bestStart + bestLength / 2) * frame
        }
        guard available >= latest else { return nil }
        // No real pause so the quietest moment in the back half has to do
        let backHalf = energies.count / 2
        var quietest = backHalf
        for i in backHalf..<energies.count where energies[i] < energies[quietest] { quietest = i }
        return lo + quietest * frame + frame / 2
    }

    static func split(_ samples: [Float]) -> [Range<Int>] {
        var pieces: [Range<Int>] = []
        var start = 0
        while let cut = nextCut(samples, start: start, end: samples.count) {
            pieces.append(start..<cut)
            start = cut
        }
        if start < samples.count { pieces.append(start..<samples.count) }
        return pieces
    }

    // The tail of the previous piece goes in the prompt so a sentence cut in half still reads on
    static func prompt(vocabulary: String, previous: String) -> String {
        let tail = previous.split(separator: " ").suffix(30).joined(separator: " ")
        if vocabulary.isEmpty { return tail }
        if tail.isEmpty { return vocabulary + "." }
        return vocabulary + ". " + tail
    }
}
