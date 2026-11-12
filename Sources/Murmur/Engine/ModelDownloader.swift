import Combine
import Foundation

final class ModelDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = ModelDownloader()

    @Published private(set) var active: String?
    @Published private(set) var progress: Double = 0
    @Published private(set) var error: String?

    private var queue: [ModelFile] = []
    private var current: ModelFile?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    func isPresent(_ model: ModelFile) -> Bool {
        FileManager.default.fileExists(atPath: Paths.models.appendingPathComponent(model.fileName).path)
    }

    var missing: [ModelFile] { ModelCatalog.all.filter { !isPresent($0) } }

    func downloadMissing() {
        guard active == nil else { return }
        queue = missing
        error = nil
        next()
    }

    private func next() {
        guard !queue.isEmpty else {
            active = nil
            current = nil
            if LLMService.shared.state != .ready, AppSettings.shared.spokenCorrections { LLMService.shared.start() }
            return
        }
        let model = queue.removeFirst()
        current = model
        active = model.label
        progress = 0
        session.downloadTask(with: model.url).resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (current?.approxBytes ?? 1)
        progress = Double(totalBytesWritten) / Double(total)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let model = current else { return }
        let dest = Paths.models.appendingPathComponent(model.fileName)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            self.error = "Could not save \(model.label)"
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            self.error = error.localizedDescription
            queue = []
            active = nil
            return
        }
        next()
    }
}
