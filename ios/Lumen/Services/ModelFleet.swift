import Foundation

nonisolated enum LumenModelSlot: String, Codable, CaseIterable, Sendable, Identifiable {
    case cortex
    case executor
    case mouth
    case mimicry
    case rem
    case embedding

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cortex: return "Cortex"
        case .executor: return "Executor"
        case .mouth: return "Mouth"
        case .mimicry: return "Mimicry"
        case .rem: return "REM"
        case .embedding: return "Embedding"
        }
    }

    var defaultRole: ModelRole {
        switch self {
        case .cortex: return .chat
        case .executor: return .chat
        case .mouth: return .chat
        case .mimicry: return .chat
        case .rem: return .chat
        case .embedding: return .embedding
        }
    }

    var isMemoryResidentCandidate: Bool {
        switch self {
        case .mimicry, .embedding:
            return true
        case .cortex, .executor, .mouth, .rem:
            return false
        }
    }

    var shouldRunOnlyWhenIdle: Bool { self == .rem }
}

nonisolated struct LumenModelSlotContract: Sendable, Hashable {
    let slot: LumenModelSlot
    let systemContract: String
    let defaultTemperature: Double
    let defaultTopP: Double
    let maxOutputTokens: Int

    static let cortex = LumenModelSlotContract(
        slot: .cortex,
        systemContract: "You are Lumen Cortex. Read the user intent and app state. Return a compact decision object describing the next model slot, whether a native capability is required, and a short rationale. Do not write the final user-facing answer.",
        defaultTemperature: 0.15,
        defaultTopP: 0.85,
        maxOutputTokens: 220
    )

    static let executor = LumenModelSlotContract(
        slot: .executor,
        systemContract: "You are Lumen Executor. Convert a Cortex decision into one validated structured capability request. Return only valid JSON. Do not explain.",
        defaultTemperature: 0.0,
        defaultTopP: 0.1,
        maxOutputTokens: 180
    )

    static let mouth = LumenModelSlotContract(
        slot: .mouth,
        systemContract: "You are Lumen Mouth. Write the final user-facing response from approved facts and results. Be concise and do not invent actions.",
        defaultTemperature: 0.55,
        defaultTopP: 0.9,
        maxOutputTokens: 420
    )

    static let mimicry = LumenModelSlotContract(
        slot: .mimicry,
        systemContract: "You are Lumen Mimicry. Summarize the user's tone preference and rewrite assistant text without changing meaning.",
        defaultTemperature: 0.2,
        defaultTopP: 0.8,
        maxOutputTokens: 160
    )

    static let rem = LumenModelSlotContract(
        slot: .rem,
        systemContract: "You are Lumen REM. During idle cycles, compress traces, find repeated failures, and produce training records for later review.",
        defaultTemperature: 0.35,
        defaultTopP: 0.9,
        maxOutputTokens: 900
    )

    static let embedding = LumenModelSlotContract(
        slot: .embedding,
        systemContract: "Embedding model slot for semantic memory.",
        defaultTemperature: 0,
        defaultTopP: 1,
        maxOutputTokens: 0
    )

    static let all: [LumenModelSlotContract] = [.cortex, .executor, .mouth, .mimicry, .rem, .embedding]

    static func contract(for slot: LumenModelSlot) -> LumenModelSlotContract {
        all.first { $0.slot == slot } ?? .mouth
    }
}

nonisolated struct LumenModelAssignment: Sendable, Hashable {
    let slot: LumenModelSlot
    let modelID: UUID
    let localPath: String
    let fileName: String
    let displayName: String
    let parameters: String
    let quantization: String
}

nonisolated struct LumenModelFleetSnapshot: Sendable, Hashable {
    let assignments: [LumenModelSlot: LumenModelAssignment]
    let missingSlots: [LumenModelSlot]

    func assignment(for slot: LumenModelSlot) -> LumenModelAssignment? {
        assignments[slot]
    }

    var isRunnableV0: Bool {
        assignment(for: .cortex) != nil && assignment(for: .mouth) != nil
    }
}

@MainActor
enum LumenModelFleetResolver {
    static func resolveV0(appState: AppState, storedModels: [StoredModel]) -> LumenModelFleetSnapshot {
        var assignments: [LumenModelSlot: LumenModelAssignment] = [:]

        let textModels = storedModels.filter { $0.modelRole == .chat }
        let activeText = appState.activeChatModelID.flatMap { id in
            textModels.first { $0.id.uuidString == id }
        }
        let fallbackText = activeText ?? preferredTextModel(from: textModels)

        for slot in [LumenModelSlot.cortex, .executor, .mouth, .mimicry, .rem] {
            if let model = preferredModel(for: slot, storedModels: storedModels) ?? fallbackText {
                assignments[slot] = assignment(slot: slot, model: model)
            }
        }

        let embedModels = storedModels.filter { $0.modelRole == .embedding }
        let activeEmbed = appState.activeEmbeddingModelID.flatMap { id in
            embedModels.first { $0.id.uuidString == id }
        }
        if let embed = activeEmbed ?? embedModels.first {
            assignments[.embedding] = assignment(slot: .embedding, model: embed)
        }

        let missing = LumenModelSlot.allCases.filter { assignments[$0] == nil }
        return LumenModelFleetSnapshot(assignments: assignments, missingSlots: missing)
    }

    private static func preferredModel(for slot: LumenModelSlot, storedModels: [StoredModel]) -> StoredModel? {
        let hints: [String]
        switch slot {
        case .cortex, .executor:
            hints = ["coder", "qwen"]
        case .mouth, .mimicry:
            hints = ["qwen", "smollm"]
        case .rem:
            hints = ["smollm", "phi"]
        case .embedding:
            hints = ["embed", "nomic"]
        }

        return storedModels.first { model in
            let haystack = [model.name, model.repoId, model.fileName, model.parameters, model.quantization]
                .joined(separator: " ")
                .lowercased()
            return hints.allSatisfy { haystack.contains($0) }
        } ?? storedModels.first { model in
            let haystack = [model.name, model.repoId, model.fileName]
                .joined(separator: " ")
                .lowercased()
            return hints.contains { haystack.contains($0) }
        }
    }

    private static func preferredTextModel(from models: [StoredModel]) -> StoredModel? {
        models.first { $0.fileName.lowercased().contains("qwen") }
        ?? models.first { $0.fileName.lowercased().contains("smollm") }
        ?? models.first
    }

    private static func assignment(slot: LumenModelSlot, model: StoredModel) -> LumenModelAssignment {
        LumenModelAssignment(
            slot: slot,
            modelID: model.id,
            localPath: ModelStorage.resolvedModelURL(from: model.localPath, fileName: model.fileName).path,
            fileName: model.fileName,
            displayName: model.name,
            parameters: model.parameters,
            quantization: model.quantization
        )
    }
}
