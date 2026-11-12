import Foundation

// Timers in common mode keep firing while a menu is being tracked
func commonTimer(_ interval: TimeInterval, repeats: Bool, _ block: @escaping (Timer) -> Void) -> Timer {
    let timer = Timer(timeInterval: interval, repeats: repeats, block: block)
    RunLoop.main.add(timer, forMode: .common)
    return timer
}

enum Log {
    static var echo = false
    private static let queue = DispatchQueue(label: "murmur.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
    private static let fileURL = Paths.logs.appendingPathComponent("murmur.log")

    static func info(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        if echo { FileHandle.standardError.write(line.data(using: .utf8)!) }
        queue.async {
            rotateIfNeeded()
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                try? handle.close()
            } else {
                try? line.data(using: .utf8)!.write(to: fileURL)
            }
        }
    }

    // Keeps one old file so the log never grows past a few megabytes
    private static func rotateIfNeeded() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let size = attrs?[.size] as? Int, size > 4_000_000 else { return }
        let old = fileURL.deletingPathExtension().appendingPathExtension("old.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: fileURL, to: old)
    }
}
