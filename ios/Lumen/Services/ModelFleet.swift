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

    var isMemoryResidentCandidate: Bool {
        switch self {
        case .mimicry, .embedding: return true
        case .cortex, .executor, .mouth, .rem: return false
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

    static func contract(for slot: LumenModelSlot) -> LumenModelSlotContract? {
        all.first { $0.slot == slot }
    }

    static func requiredContract(for slot: LumenModelSlot) -> LumenModelSlotContract {
        if let contract = contract(for: slot) {
            return contract
        }
        assertionFailure("Missing LumenModelSlotContract for slot: \(slot.rawValue)")
        return .mouth
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
        let activeText = appState.activeChatModelID.flatMap { id in textModels.first { $0.id.uuidString == id } }
        let fallbackText = activeText ?? preferredTextModel(from: textModels)

        for slot in [LumenModelSlot.cortex, .executor, .mouth, .mimicry, .rem] {
            if let model = preferredModel(for: slot, storedModels: textModels) ?? fallbackText {
                assignments[slot] = assignment(slot: slot, model: model)
            }
        }

        let embedModels = storedModels.filter { $0.modelRole == .embedding }
        let activeEmbed = appState.activeEmbeddingModelID.flatMap { id in
            embedModels.first { $0.id.uuidString == id }
        }
        let fallbackEmbed = activeEmbed
            ?? preferredModel(for: .embedding, storedModels: embedModels)
            ?? mostRecentModel(from: embedModels)

        if let embed = fallbackEmbed {
            assignments[.embedding] = assignment(slot: .embedding, model: embed)
        }

        let missing = LumenModelSlot.allCases.filter { assignments[$0] == nil }
        return LumenModelFleetSnapshot(assignments: assignments, missingSlots: missing)
    }

    private static func preferredModel(for slot: LumenModelSlot, storedModels: [StoredModel]) -> StoredModel? {
        let weights = hintWeights(for: slot)
        return storedModels
            .map { model in (model: model, score: score(model, weights: weights)) }
            .filter { $0.score > 0 }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.model.downloadedAt > rhs.model.downloadedAt
            }
            .first?
            .model
    }

    private static func preferredTextModel(from models: [StoredModel]) -> StoredModel? {
        preferredModel(for: .cortex, storedModels: models)
        ?? preferredModel(for: .mouth, storedModels: models)
        ?? mostRecentModel(from: models)
    }

    private static func mostRecentModel(from models: [StoredModel]) -> StoredModel? {
        models.sorted { $0.downloadedAt > $1.downloadedAt }.first
    }

    private static func hintWeights(for slot: LumenModelSlot) -> [String: Int] {
        switch slot {
        case .cortex:
            return ["coder": 50, "qwen": 35, "0.5b": 15, "1.5b": 12, "fleet": 10]
        case .executor:
            return ["coder": 55, "qwen": 35, "0.5b": 20, "json": 10, "structured": 10]
        case .mouth:
            return ["qwen": 35, "smollm": 30, "voice": 20, "mouth": 20, "0.5b": 10]
        case .mimicry:
            return ["qwen": 35, "mimicry": 25, "voice": 15, "0.5b": 15, "smollm": 10]
        case .rem:
            return ["smollm": 45, "phi": 35, "rem": 25, "idle": 10, "1.7b": 10]
        case .embedding:
            return ["nomic": 50, "embed": 40, "embedding": 30, "memory": 15]
        }
    }

    private static func score(_ model: StoredModel, weights: [String: Int]) -> Int {
        let primary = [model.name, model.repoId, model.fileName]
            .joined(separator: " ")
            .lowercased()
        let secondary = [model.parameters, model.quantization, model.role]
            .joined(separator: " ")
            .lowercased()

        return weights.reduce(0) { partial, item in
            let hint = item.key.lowercased()
            let weight = item.value
            if primary.contains(hint) { return partial + weight }
            if secondary.contains(hint) { return partial + max(1, weight / 2) }
            return partial
        }
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
