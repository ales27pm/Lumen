import Foundation

nonisolated enum LumenModelFamily: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case qwen25 = "qwen2.5"
    case qwen3 = "qwen3"

    private static let defaultsKey = "selectedModelFamilyID"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .qwen25: return "Qwen 2.5 baseline"
        case .qwen3: return "Qwen3 bootstrap"
        }
    }

    var shortLabel: String {
        switch self {
        case .qwen25: return "Qwen2.5"
        case .qwen3: return "Qwen3"
        }
    }

    var description: String {
        switch self {
        case .qwen25:
            return "Stable Qwen2.5 baseline fleet: Qwen2.5 chat base plus lightweight embedding fallback."
        case .qwen3:
            return "Current bootstrap family: role-baked Qwen3 GGUF artifacts plus Qwen3 embedding candidate."
        }
    }

    static let defaultFamily: LumenModelFamily = .qwen3

    static func fromStoredID(_ id: String?) -> LumenModelFamily {
        guard let id, let family = LumenModelFamily(rawValue: id) else { return defaultFamily }
        return family
    }

    static var persistedSelected: LumenModelFamily {
        get { fromStoredID(UserDefaults.standard.string(forKey: defaultsKey)) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

nonisolated extension LumenModelFleetCatalog {
    static var qwen25BootstrapModels: [CatalogModel] {
        [
            CatalogModel(id: "fleet-bootstrap-qwen2.5-chat-base-q4", name: "Qwen2.5 Bootstrap Chat Base", repoId: "Qwen/Qwen2.5-1.5B-Instruct-GGUF", fileName: "qwen2.5-1.5b-instruct-q4_k_m.gguf", parameters: "1.5B", quantization: "Q4_K_M", sizeBytes: 1_117_000_000, role: .chat, description: "Qwen2.5 baseline shared chat base. Use this family as the rollback/baseline candidate.", tags: ["bootstrap", "qwen2.5", "baseline", "shared-base"]),
            CatalogModel(id: "fleet-bootstrap-qwen2.5-embedding-fallback-nomic-q4", name: "Qwen2.5 Bootstrap Embedding Fallback — Nomic", repoId: "nomic-ai/nomic-embed-text-v1.5-GGUF", fileName: "nomic-embed-text-v1.5.Q4_K_M.gguf", parameters: "137M", quantization: "Q4_K_M", sizeBytes: 85_000_000, role: .embedding, description: "Small embedding fallback for the Qwen2.5 baseline family.", tags: ["bootstrap", "qwen2.5", "embedding", "fallback", "nomic"]),
        ]
    }

    static var qwen3BootstrapModels: [CatalogModel] {
        [
            CatalogModel(id: "fleet-bootstrap-qwen3-cortex-q4", name: "Qwen3 Bootstrap Cortex", repoId: "ales27pm/lumen-qwen3-bootstrap-gguf", fileName: "lumen-cortex-release-bake-q4_k_m.gguf", parameters: "1.7B", quantization: "Q4_K_M", sizeBytes: 1_350_000_000, role: .chat, description: "Role-baked Qwen3 Cortex artifact for routing, planning, and orchestration.", tags: ["bootstrap", "qwen3", "cortex", "release-bake"]),
            CatalogModel(id: "fleet-bootstrap-qwen3-executor-q4", name: "Qwen3 Bootstrap Executor", repoId: "ales27pm/lumen-qwen3-bootstrap-gguf", fileName: "lumen-executor-release-bake-q4_k_m.gguf", parameters: "1.7B", quantization: "Q4_K_M", sizeBytes: 1_350_000_000, role: .chat, description: "Role-baked Qwen3 Executor artifact for strict tool JSON and native action requests.", tags: ["bootstrap", "qwen3", "executor", "release-bake"]),
            CatalogModel(id: "fleet-bootstrap-qwen3-mouth-q4", name: "Qwen3 Bootstrap Mouth", repoId: "ales27pm/lumen-qwen3-bootstrap-gguf", fileName: "lumen-mouth-release-bake-q4_k_m.gguf", parameters: "1.7B", quantization: "Q4_K_M", sizeBytes: 1_350_000_000, role: .chat, description: "Role-baked Qwen3 Mouth artifact for final user-facing responses.", tags: ["bootstrap", "qwen3", "mouth", "release-bake"]),
            CatalogModel(id: "fleet-bootstrap-qwen3-mimicry-q4", name: "Qwen3 Bootstrap Mimicry", repoId: "ales27pm/lumen-qwen3-bootstrap-gguf", fileName: "lumen-mimicry-release-bake-q4_k_m.gguf", parameters: "1.7B", quantization: "Q4_K_M", sizeBytes: 1_350_000_000, role: .chat, description: "Role-baked Qwen3 Mimicry artifact for tone and style adaptation without changing facts.", tags: ["bootstrap", "qwen3", "mimicry", "release-bake"]),
            CatalogModel(id: "fleet-bootstrap-qwen3-rem-q4", name: "Qwen3 Bootstrap REM", repoId: "ales27pm/lumen-qwen3-bootstrap-gguf", fileName: "lumen-rem-release-bake-q4_k_m.gguf", parameters: "1.7B", quantization: "Q4_K_M", sizeBytes: 1_350_000_000, role: .chat, description: "Role-baked Qwen3 REM artifact for reflection, repair, and idle-cycle training signals.", tags: ["bootstrap", "qwen3", "rem", "release-bake"]),
            CatalogModel(id: "fleet-bootstrap-qwen3-embedding-0.6b-q4", name: "Qwen3 Bootstrap Embedding 0.6B", repoId: "Qwen/Qwen3-Embedding-0.6B-GGUF", fileName: "Qwen3-Embedding-0.6B-Q4_K_M.gguf", parameters: "0.6B", quantization: "Q4_K_M", sizeBytes: 450_000_000, role: .embedding, description: "Qwen3 embedding candidate for source-map, tool-schema, memory, RAG, and repair retrieval.", tags: ["bootstrap", "qwen3", "embedding", "current"]),
        ]
    }

    static func bootstrapModels(for family: LumenModelFamily) -> [CatalogModel] {
        switch family {
        case .qwen25: return qwen25BootstrapModels
        case .qwen3: return qwen3BootstrapModels
        }
    }

    static var selectableBootstrapModels: [CatalogModel] {
        qwen3BootstrapModels + qwen25BootstrapModels
    }
}
