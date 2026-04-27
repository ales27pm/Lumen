import Foundation
import SwiftData

@Model
final class StoredModel {
    var id: UUID = UUID()
    var name: String = ""
    var repoId: String = ""
    var fileName: String = ""
    var sizeBytes: Int64 = 0
    var quantization: String = "Q4_K_M"
    var parameters: String = ""
    var role: String = "chat"
    var downloadedAt: Date = Date()
    var localPath: String = ""

    init(name: String, repoId: String, fileName: String, sizeBytes: Int64, quantization: String, parameters: String, role: ModelRole, localPath: String) {
        self.name = name
        self.repoId = repoId
        self.fileName = fileName
        self.sizeBytes = sizeBytes
        self.quantization = quantization
        self.parameters = parameters
        self.role = role.rawValue
        self.localPath = localPath
    }

    var modelRole: ModelRole { ModelRole(rawValue: role) ?? .chat }
}

enum ModelRole: String, Codable, CaseIterable, Sendable {
    case chat, embedding
}

nonisolated struct CatalogModel: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let repoId: String
    let fileName: String
    let parameters: String
    let quantization: String
    let sizeBytes: Int64
    let role: ModelRole
    let description: String
    let tags: [String]

    var downloadURL: URL {
        URL(string: "https://huggingface.co/\(repoId)/resolve/main/\(fileName)?download=true")!
    }
}

nonisolated enum ModelCatalog {
    static let defaultOnboardingModelID = "qwen2.5-1.5b-q4"
    static let featured: [CatalogModel] = LumenModelFleetCatalog.v0Recommended + legacyFeatured

    static var defaultOnboardingModel: CatalogModel {
        legacyFeatured.first { $0.id == defaultOnboardingModelID }
        ?? featured.first { $0.id == defaultOnboardingModelID }
        ?? legacyFeatured.first
        ?? featured[0]
    }

    static let legacyFeatured: [CatalogModel] = [
        CatalogModel(
            id: "qwen2.5-1.5b-q4",
            name: "Qwen 2.5 Instruct",
            repoId: "Qwen/Qwen2.5-1.5B-Instruct-GGUF",
            fileName: "qwen2.5-1.5b-instruct-q4_k_m.gguf",
            parameters: "1.5B",
            quantization: "Q4_K_M",
            sizeBytes: 1_117_000_000,
            role: .chat,
            description: "Fast, capable default. Great on any iPhone.",
            tags: ["recommended", "fast", "tools"]
        ),
        CatalogModel(
            id: "llama-3.2-3b-q4",
            name: "Llama 3.2 Instruct",
            repoId: "bartowski/Llama-3.2-3B-Instruct-GGUF",
            fileName: "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
            parameters: "3B",
            quantization: "Q4_K_M",
            sizeBytes: 2_020_000_000,
            role: .chat,
            description: "Meta's smart compact model. Balanced quality.",
            tags: ["balanced", "tools"]
        ),
        CatalogModel(
            id: "dolphin-3.0-llama-3.2-3b-q4",
            name: "Dolphin 3.0 Llama 3.2",
            repoId: "itlwas/Dolphin3.0-Llama3.2-3B-Q4_K_M-GGUF",
            fileName: "dolphin3.0-llama3.2-3b-q4_k_m.gguf",
            parameters: "3B",
            quantization: "Q4_K_M",
            sizeBytes: 2_019_382_112,
            role: .chat,
            description: "Dolphin-tuned Llama 3.2 for assistant chat.",
            tags: ["chat", "tools"]
        ),
        CatalogModel(
            id: "gemma-2-2b-q4",
            name: "Gemma 2 Instruct",
            repoId: "bartowski/gemma-2-2b-it-GGUF",
            fileName: "gemma-2-2b-it-Q4_K_M.gguf",
            parameters: "2B",
            quantization: "Q4_K_M",
            sizeBytes: 1_630_000_000,
            role: .chat,
            description: "Google's polite and creative assistant.",
            tags: ["creative"]
        ),
        CatalogModel(
            id: "phi-3.5-mini-q4",
            name: "Phi 3.5 Mini",
            repoId: "bartowski/Phi-3.5-mini-instruct-GGUF",
            fileName: "Phi-3.5-mini-instruct-Q4_K_M.gguf",
            parameters: "3.8B",
            quantization: "Q4_K_M",
            sizeBytes: 2_390_000_000,
            role: .chat,
            description: "Microsoft's reasoning-focused model.",
            tags: ["reasoning"]
        ),
        CatalogModel(
            id: "mistral-7b-q4",
            name: "Mistral 7B Instruct",
            repoId: "TheBloke/Mistral-7B-Instruct-v0.2-GGUF",
            fileName: "mistral-7b-instruct-v0.2.Q4_K_M.gguf",
            parameters: "7B",
            quantization: "Q4_K_M",
            sizeBytes: 4_370_000_000,
            role: .chat,
            description: "Large, heavy. Needs 8GB+ device RAM.",
            tags: ["large", "quality"]
        ),
        CatalogModel(
            id: "nomic-embed-q4",
            name: "Nomic Embed v1.5",
            repoId: "nomic-ai/nomic-embed-text-v1.5-GGUF",
            fileName: "nomic-embed-text-v1.5.Q4_K_M.gguf",
            parameters: "137M",
            quantization: "Q4_K_M",
            sizeBytes: 85_000_000,
            role: .embedding,
            description: "Tiny, fast vector embeddings for memory.",
            tags: ["embedding", "tiny"]
        ),
    ]
}
