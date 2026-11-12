import Foundation

// Pure diff logic for turning a hand edit of pasted text into dictionary entries
enum EditLearner {
    static let maxPerPaste = 3
    private static let tokenRegex = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]+(?:['’\\-][\\p{L}\\p{N}]+)*")

    static func tokens(_ s: String) -> [String] {
        let ns = s as NSString
        return tokenRegex.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    struct Hunk { var removed: [String]; var inserted: [String] }

    // Plain LCS alignment which is fine for the few hundred words one dictation holds
    static func hunks(_ a: [String], _ b: [String]) -> [Hunk] {
        let n = a.count, m = b.count
        guard n > 0 || m > 0, n <= 1500, m <= 1500 else { return [] }
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }
        var result: [Hunk] = []
        var current = Hunk(removed: [], inserted: [])
        var i = 0, j = 0
        func flush() {
            if !current.removed.isEmpty || !current.inserted.isEmpty { result.append(current) }
            current = Hunk(removed: [], inserted: [])
        }
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                flush()
                i += 1; j += 1
            } else if j < m, i == n || dp[i][j + 1] >= dp[i + 1][j] {
                current.inserted.append(b[j]); j += 1
            } else {
                current.removed.append(a[i]); i += 1
            }
        }
        flush()
        return result
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[y.count]
    }

    static func corrections(original: String, edited: String) -> [LearnedPair] {
        var found: [LearnedPair] = []
        for h in hunks(tokens(original), tokens(edited)) {
            guard !h.removed.isEmpty, !h.inserted.isEmpty, h.removed.count <= 3, h.inserted.count <= 3 else { continue }
            let heard = h.removed.joined(separator: " ")
            let correct = h.inserted.joined(separator: " ")
            guard correct.count <= 40, heard != correct else { continue }
            let kh = Replacer.key(heard), kc = Replacer.key(correct)
            guard kc.count >= 3 else { continue }
            // A changed number or version is an edit of the content and learning it would rewrite every later one
            let digitless = { (s: String) in s.filter { !$0.isNumber } }
            guard !digitless(kc).isEmpty, kh == kc || digitless(kh) != digitless(kc) else { continue }
            // Taking capitals away is sentence shaping while adding them is a spelling the speaker wants
            if heard.lowercased() == correct.lowercased() {
                let capsBefore = heard.filter { $0.isUppercase }.count
                let capsAfter = correct.filter { $0.isUppercase }.count
                guard capsAfter > capsBefore else { continue }
            }
            let similar = kh == kc || Double(levenshtein(kh, kc)) / Double(max(kh.count, kc.count)) <= 0.45
            guard similar else { continue }
            // Ordinary English fixes like there to their are typos not vocabulary
            guard Replacer.isDistinctive(correct) else { continue }
            found.append(LearnedPair(heard: heard, correct: correct))
            if found.count >= maxPerPaste { break }
        }
        return found
    }
}
