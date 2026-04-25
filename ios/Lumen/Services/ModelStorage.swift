import Foundation

enum ModelStorage {
    static func modelsDirectoryURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let directory = base.appendingPathComponent("Models", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func resumeDirectoryURL(fileManager: FileManager = .default) -> URL {
        let directory = modelsDirectoryURL(fileManager: fileManager).appendingPathComponent(".resume", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func resolvedModelURL(from storedPath: String, fileName: String, fileManager: FileManager = .default) -> URL {
        let storedURL = URL(fileURLWithPath: storedPath)
        if fileManager.fileExists(atPath: storedURL.path) {
            return storedURL
        }

        let preferred = modelsDirectoryURL(fileManager: fileManager).appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: preferred.path) {
            return preferred
        }

        let base = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let previousNested = base
            .appendingPathComponent("Hybrid Coder", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: previousNested.path) {
            return previousNested
        }

        return storedURL
    }
}
