import Foundation

public enum AgentManifestStore {
    public static let directoryName = "AgentManifest"
    public static let fileName = "AgentBehaviorManifest.json"

    public static func manifestDirectory(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent(directoryName, isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    public static func manifestURL(fileManager: FileManager = .default) throws -> URL {
        try manifestDirectory(fileManager: fileManager).appendingPathComponent(fileName, isDirectory: false)
    }

    public static func load(fileManager: FileManager = .default) throws -> AgentBehaviorManifest? {
        let url = try manifestURL(fileManager: fileManager)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AgentBehaviorManifest.self, from: data)
    }

    @discardableResult
    public static func persist(_ manifest: AgentBehaviorManifest, fileManager: FileManager = .default) throws -> URL {
        let url = try manifestURL(fileManager: fileManager)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: [.atomic])
        return url
    }

    @discardableResult
    public static func seedFromBundleIfNeeded(resourceName: String = "AgentBehaviorManifest", bundle: Bundle = .main, fileManager: FileManager = .default) throws -> URL? {
        let destinationURL = try manifestURL(fileManager: fileManager)
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            return destinationURL
        }
        guard let sourceURL = bundle.url(forResource: resourceName, withExtension: "json") else {
            return nil
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }
}
