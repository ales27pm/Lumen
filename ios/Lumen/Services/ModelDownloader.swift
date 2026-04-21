import Foundation
import Observation

@Observable
final class ModelDownloader: NSObject {
    static let shared = ModelDownloader()

    var progresses: [String: DownloadProgress] = [:]

    @ObservationIgnored
    private var sessions: [String: URLSessionDownloadTask] = [:]
    @ObservationIgnored
    private var targets: [Int: (model: CatalogModel, destination: URL, onComplete: (URL) -> Void)] = [:]

    @ObservationIgnored
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    static var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func localURL(for model: CatalogModel) -> URL {
        Self.modelsDirectory.appendingPathComponent(model.fileName)
    }

    func isDownloaded(_ model: CatalogModel) -> Bool {
        FileManager.default.fileExists(atPath: localURL(for: model).path)
    }

    func start(_ model: CatalogModel, onComplete: @escaping (URL) -> Void) {
        guard sessions[model.id] == nil else { return }
        progresses[model.id] = DownloadProgress(fractionCompleted: 0, bytesReceived: 0, totalBytes: model.sizeBytes, state: .downloading)
        let task = session.downloadTask(with: model.downloadURL)
        sessions[model.id] = task
        targets[task.taskIdentifier] = (model, localURL(for: model), onComplete)
        task.resume()
    }

    func cancel(_ model: CatalogModel) {
        sessions[model.id]?.cancel()
        sessions[model.id] = nil
        progresses[model.id] = nil
    }

    func deleteLocal(_ model: CatalogModel) {
        try? FileManager.default.removeItem(at: localURL(for: model))
        progresses[model.id] = nil
    }
}

extension ModelDownloader: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let taskId = downloadTask.taskIdentifier
        Task { @MainActor in
            guard let entry = targets[taskId] else { return }
            let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : entry.model.sizeBytes
            let fraction = total > 0 ? Double(totalBytesWritten) / Double(total) : 0
            progresses[entry.model.id] = DownloadProgress(
                fractionCompleted: fraction,
                bytesReceived: totalBytesWritten,
                totalBytes: total,
                state: .downloading
            )
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let taskId = downloadTask.taskIdentifier
        let tempLocation = location
        let fm = FileManager.default
        let entry = syncTarget(id: taskId)
        let destination: URL? = {
            guard let entry else { return nil }
            try? fm.removeItem(at: entry.destination)
            do {
                try fm.moveItem(at: tempLocation, to: entry.destination)
                return entry.destination
            } catch {
                try? fm.copyItem(at: tempLocation, to: entry.destination)
                return entry.destination
            }
        }()
        let finalDest = destination
        Task { @MainActor in
            guard let entry = targets[taskId] else { return }
            if let finalDest {
                progresses[entry.model.id] = DownloadProgress(
                    fractionCompleted: 1,
                    bytesReceived: entry.model.sizeBytes,
                    totalBytes: entry.model.sizeBytes,
                    state: .completed
                )
                entry.onComplete(finalDest)
            }
            sessions[entry.model.id] = nil
            targets[taskId] = nil
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let taskId = task.taskIdentifier
        guard let error else { return }
        Task { @MainActor in
            guard let entry = targets[taskId] else { return }
            progresses[entry.model.id] = DownloadProgress(
                fractionCompleted: 0, bytesReceived: 0, totalBytes: entry.model.sizeBytes,
                state: .failed(error.localizedDescription)
            )
            sessions[entry.model.id] = nil
            targets[taskId] = nil
        }
    }

    nonisolated private func syncTarget(id: Int) -> (model: CatalogModel, destination: URL, onComplete: (URL) -> Void)? {
        DispatchQueue.main.sync { targets[id] }
    }
}
