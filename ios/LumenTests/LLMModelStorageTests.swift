import Foundation
import Testing
@testable import Lumen

struct LLMModelStorageTests {
    @Test func sha256FileHasherReturnsKnownHashForSmallFile() throws {
        let temp = try makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: temp.baseDirectory) }
        let fileURL = temp.baseDirectory.appendingPathComponent("hello.txt")
        try Data("hello".utf8).write(to: fileURL)

        let hash = try SHA256FileHasher.sha256Hex(for: fileURL)

        #expect(hash == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }

    @Test func modelFileValidatorAcceptsGGUFExtension() throws {
        let url = URL(fileURLWithPath: "/tmp/model.gguf")

        try ModelFileValidator.validateExtension(for: url, backend: .gguf)
    }

    @Test func modelFileValidatorRejectsWrongGGUFExtension() {
        let url = URL(fileURLWithPath: "/tmp/model.bin")

        do {
            try ModelFileValidator.validateExtension(for: url, backend: .gguf)
            #expect(Bool(false))
        } catch ModelStorageError.invalidModelFileExtension(let fileName) {
            #expect(fileName == "model.bin")
        } catch {
            #expect(Bool(false))
        }
    }

    @Test func modelStorageRegistersTinyIntentRecord() async throws {
        let temp = try makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: temp.baseDirectory) }
        let storage = LLMModelStorage(location: temp.location)

        let record = try await storage.registerTinyIntentModel()
        let fetched = try await storage.record(for: record.id)

        #expect(record.id == "builtin.tiny-intent")
        #expect(record.model.backend == .tinyIntent)
        #expect(record.isUsable)
        #expect(fetched == record)
    }

    @Test func modelStorageImportsSmallFakeGGUFIntoTempStorage() async throws {
        let temp = try makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: temp.baseDirectory) }
        let storage = LLMModelStorage(location: temp.location)
        let sourceURL = temp.baseDirectory.appendingPathComponent("source.gguf")
        try Data("fake gguf".utf8).write(to: sourceURL)

        let record = try await storage.importExistingModelFile(
            fileURL: sourceURL,
            catalogEntry: BuiltInModelCatalog.entry(id: "qwen2.5-1.5b-instruct-q4-k-m-gguf"),
            backend: .gguf,
            displayName: "Imported Test GGUF",
            expectedSHA256: nil
        )

        #expect(record.model.backend == .gguf)
        #expect(record.verificationStatus == .unverified)
        #expect(record.fileURL?.deletingLastPathComponent() == temp.location.modelsDirectory)
        #expect(record.relativePath?.hasPrefix("Models/") == true)
        #expect(record.sizeBytes == 9)
        #expect(record.isUsable)
        #expect(try await storage.record(for: record.id) == record)
    }

    @Test func modelStorageWritesAndReadsMetadataRecord() async throws {
        let temp = try makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: temp.baseDirectory) }
        let storage = LLMModelStorage(location: temp.location)
        let record = InstalledModelRecord(
            id: "test.record",
            catalogID: nil,
            model: LocalLLMModel(
                id: "test.record",
                displayName: "Test Record",
                backend: .tinyIntent,
                contextLength: 128
            ),
            fileURL: nil,
            relativePath: nil,
            sha256: nil,
            sizeBytes: nil,
            installedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastVerifiedAt: nil,
            verificationStatus: .verified
        )

        try await storage.saveRecord(record)

        #expect(try await storage.record(for: "test.record") == record)
        #expect(try await storage.listInstalledModels() == [record])
    }

    @Test func deleteModelDeletesFileUnderStorageRoot() async throws {
        let temp = try makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: temp.baseDirectory) }
        let storage = LLMModelStorage(location: temp.location)
        let modelURL = temp.location.modelsDirectory.appendingPathComponent("delete-me.gguf")
        try Data("delete".utf8).write(to: modelURL)
        let record = installedGGUFRecord(id: "delete.under.root", fileURL: modelURL)
        try await storage.saveRecord(record)

        try await storage.deleteModel(id: record.id, deleteFile: true)

        #expect(FileManager.default.fileExists(atPath: modelURL.path) == false)
        #expect(try await storage.record(for: record.id) == nil)
    }

    @Test func deleteModelDoesNotDeleteOutsideRootFile() async throws {
        let temp = try makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: temp.baseDirectory) }
        let storage = LLMModelStorage(location: temp.location)
        let outsideURL = temp.baseDirectory.appendingPathComponent("outside.gguf")
        try Data("outside".utf8).write(to: outsideURL)
        let record = installedGGUFRecord(id: "outside.root", fileURL: outsideURL)
        try await storage.saveRecord(record)

        try await storage.deleteModel(id: record.id, deleteFile: true)

        #expect(FileManager.default.fileExists(atPath: outsideURL.path))
        #expect(try await storage.record(for: record.id) == nil)
    }

    @Test func builtInModelCatalogContainsTinyIntent() {
        let entry = BuiltInModelCatalog.entry(id: "builtin.tiny-intent")

        #expect(entry?.backend == .tinyIntent)
        #expect(entry?.recommendedUse == .tinyIntent)
    }

    @Test func modelSelectionServiceReturnsTinyIntentFallbackWhenOnlyUsableModel() async throws {
        let temp = try makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: temp.baseDirectory) }
        let storage = LLMModelStorage(location: temp.location)
        _ = try await storage.registerTinyIntentModel()
        let policy = DeviceModelPolicy(provider: TestDeviceCapabilityProvider())
        let selection = ModelSelectionService(storage: storage, policy: policy)

        let best = try await selection.bestModel(for: .standardChat, appIsForeground: true)

        #expect(best?.id == "builtin.tiny-intent")
        #expect(best?.model.backend == .tinyIntent)
    }

    @Test func hashMismatchThrowsModelStorageError() async throws {
        let temp = try makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: temp.baseDirectory) }
        let storage = LLMModelStorage(location: temp.location)
        let sourceURL = temp.baseDirectory.appendingPathComponent("hash-mismatch.gguf")
        try Data("actual".utf8).write(to: sourceURL)

        do {
            _ = try await storage.importExistingModelFile(
                fileURL: sourceURL,
                catalogEntry: nil,
                backend: .gguf,
                displayName: "Hash Mismatch",
                expectedSHA256: "0000000000000000000000000000000000000000000000000000000000000000"
            )
            #expect(Bool(false))
        } catch ModelStorageError.hashMismatch(let expected, let actual) {
            #expect(expected == "0000000000000000000000000000000000000000000000000000000000000000")
            #expect(actual.count == 64)
        } catch {
            #expect(Bool(false))
        }
    }

    private func installedGGUFRecord(id: String, fileURL: URL) -> InstalledModelRecord {
        InstalledModelRecord(
            id: id,
            catalogID: nil,
            model: LocalLLMModel(
                id: id,
                displayName: "Installed GGUF",
                backend: .gguf,
                localURL: fileURL,
                contextLength: 512
            ),
            fileURL: fileURL,
            relativePath: nil,
            sha256: nil,
            sizeBytes: nil,
            installedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastVerifiedAt: nil,
            verificationStatus: .unverified
        )
    }

    private func makeTemporaryStorage() throws -> (baseDirectory: URL, location: ModelStorageLocation) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumenModelStorageTests-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("Lumen", isDirectory: true)
        let models = root.appendingPathComponent("Models", isDirectory: true)
        let metadata = models.appendingPathComponent("Metadata", isDirectory: true)
        let temporary = models.appendingPathComponent("Tmp", isDirectory: true)

        for directory in [base, root, models, metadata, temporary] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        return (
            base,
            ModelStorageLocation(
                rootDirectory: root,
                modelsDirectory: models,
                metadataDirectory: metadata,
                temporaryDirectory: temporary
            )
        )
    }
}
