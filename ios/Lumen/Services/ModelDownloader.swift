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
    private var resumeData: [String: Data] = [:]
    @ObservationIgnored
    private var completionHandlers: [String: (URL) -> Void] = [:]

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

    private static var resumeDirectory: URL {
        let dir = modelsDirectory.appendingPathComponent(".resume", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func localURL(for model: CatalogModel) -> URL {
        Self.modelsDirectory.appendingPathComponent(model.fileName)
    }

    func isDownloaded(_ model: CatalogModel) -> Bool {
        FileManager.default.fileExists(atPath: localURL(for: model).path)
    }

    func isDownloading(_ model: CatalogModel) -> Bool {
        sessions[model.id] != nil
    }

    func start(_ model: CatalogModel, onComplete: @escaping (URL) -> Void) {
        if sessions[model.id] != nil {
            NotificationCenter.default.post(name: .modelDownloaderInfo, object: nil, userInfo: ["message": "\(model.name) is already downloading."])
            return
        }
        completionHandlers[model.id] = onComplete

        // Try to resume from persisted data
        let data = resumeData[model.id] ?? loadPersistedResume(for: model)
        let task: URLSessionDownloadTask
        if let data {
            task = session.downloadTask(withResumeData: data)
        } else {
            task = session.downloadTask(with: model.downloadURL)
        }
        progresses[model.id] = DownloadProgress(
            fractionCompleted: progresses[model.id]?.fractionCompleted ?? 0,
            bytesReceived: progresses[model.id]?.bytesReceived ?? 0,
            totalBytes: model.sizeBytes,
            state: .downloading
        )
        sessions[model.id] = task
        targets[task.taskIdentifier] = (model, localURL(for: model), onComplete)
        resumeData[model.id] = nil
        task.resume()
    }

    func pause(_ model: CatalogModel) {
        guard let task = sessions[model.id] else { return }
        let modelID = model.id
        let sizeBytes = model.sizeBytes
        let modelCopy = model
        task.cancel { data in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let data {
                    self.resumeData[modelID] = data
                    self.persistResume(data, for: modelCopy)
                }
                self.sessions[modelID] = nil
                let existing = self.progresses[modelID]
                self.progresses[modelID] = DownloadProgress(
                    fractionCompleted: existing?.fractionCompleted ?? 0,
                    bytesReceived: existing?.bytesReceived ?? 0,
                    totalBytes: sizeBytes,
                    state: .paused
                )
            }
        }
    }

    func resume(_ model: CatalogModel) {
        guard sessions[model.id] == nil else { return }
        guard let handler = completionHandlers[model.id] else {
            // No in-memory handler — caller should call start() again
            return
        }
        start(model, onComplete: handler)
    }

    func cancel(_ model: CatalogModel) {
        sessions[model.id]?.cancel()
        sessions[model.id] = nil
        resumeData[model.id] = nil
        completionHandlers[model.id] = nil
        clearPersistedResume(for: model)
        progresses[model.id] = nil
    }

    func deleteLocal(_ model: CatalogModel) {
        try? FileManager.default.removeItem(at: localURL(for: model))
        clearPersistedResume(for: model)
        progresses[model.id] = nil
    }

    private func persistResume(_ data: Data, for model: CatalogModel) {
        let url = Self.resumeDirectory.appendingPathComponent("\(model.id).resume")
        try? data.write(to: url)
    }

    private func loadPersistedResume(for model: CatalogModel) -> Data? {
        let url = Self.resumeDirectory.appendingPathComponent("\(model.id).resume")
        return try? Data(contentsOf: url)
    }

    private func clearPersistedResume(for model: CatalogModel) {
        let url = Self.resumeDirectory.appendingPathComponent("\(model.id).resume")
        try? FileManager.default.removeItem(at: url)
    }
}

extension Notification.Name {
    static let modelDownloaderInfo = Notification.Name("modelDownloaderInfo")
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
        // Must synchronously move file before this delegate returns (temp file is deleted after)
        let fm = FileManager.default
        // Compute models directory without touching MainActor-isolated static
        let base = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let modelsDir = base.appendingPathComponent("Models", isDirectory: true)
        try? fm.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        let staging = modelsDir.appendingPathComponent(".staging-\(UUID().uuidString)")
        try? fm.removeItem(at: staging)
        let movedURL: URL?
        do {
            try fm.moveItem(at: location, to: staging)
            movedURL = staging
        } catch {
            movedURL = nil
        }
        Task { @MainActor in
            let fm = FileManager.default
            guard let entry = targets[taskId] else {
                if let moved = movedURL { try? fm.removeItem(at: moved) }
                return
            }
            var finalDest: URL?
            if let moved = movedURL {
                try? fm.removeItem(at: entry.destination)
                do {
                    try fm.moveItem(at: moved, to: entry.destination)
                    finalDest = entry.destination
                } catch {
                    try? fm.copyItem(at: moved, to: entry.destination)
                    try? fm.removeItem(at: moved)
                    finalDest = entry.destination
                }
            }
            if let finalDest {
                progresses[entry.model.id] = DownloadProgress(
                    fractionCompleted: 1,
                    bytesReceived: entry.model.sizeBytes,
                    totalBytes: entry.model.sizeBytes,
                    state: .completed
                )
                clearPersistedResume(for: entry.model)
                entry.onComplete(finalDest)
            }
            sessions[entry.model.id] = nil
            completionHandlers[entry.model.id] = nil
            targets[taskId] = nil
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let taskId = task.taskIdentifier
        guard let error else { return }
        let nsError = error as NSError
        let resume = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        Task { @MainActor in
            guard let entry = targets[taskId] else { return }
            // If cancellation produced resume data, state is already set by pause()
            if let resume {
                self.resumeData[entry.model.id] = resume
                self.persistResume(resume, for: entry.model)
            }
            if nsError.code == NSURLErrorCancelled {
                // Don't flip to failed on user-initiated cancel
                sessions[entry.model.id] = nil
                targets[taskId] = nil
                return
            }
            progresses[entry.model.id] = DownloadProgress(
                fractionCompleted: progresses[entry.model.id]?.fractionCompleted ?? 0,
                bytesReceived: progresses[entry.model.id]?.bytesReceived ?? 0,
                totalBytes: entry.model.sizeBytes,
                state: .failed(error.localizedDescription)
            )
            sessions[entry.model.id] = nil
            targets[taskId] = nil
        }
    }
}
