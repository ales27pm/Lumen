import Foundation
import SwiftData

@MainActor
enum SharedContainer {
    static var shared: ModelContainer?
}

nonisolated enum FileStore {
    static var importsDirectory: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Imports", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func importedFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: importsDirectory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
    }

    static func importFile(from source: URL) -> URL? {
        let fm = FileManager.default
        let needsAccess = source.startAccessingSecurityScopedResource()
        defer { if needsAccess { source.stopAccessingSecurityScopedResource() } }
        let dest = importsDirectory.appendingPathComponent(source.lastPathComponent)
        try? fm.removeItem(at: dest)
        do {
            try fm.copyItem(at: source, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    static func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
