import Foundation
import OSLog

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

nonisolated enum LumenFleetRuntimeMode: String, Codable, Sendable {
    case v0SingleRuntime
    case v1MultiResidentPlanned

    var displayName: String {
        switch self {
        case .v0SingleRuntime: return "v0 single runtime"
        case .v1MultiResidentPlanned: return "v1 multi-resident planned"
        }
    }
}

nonisolated struct LumenModelSlotContract: Sendable, Hashable {
    nonisolated static let fleetContractVersion = "2026.04.29"
    private nonisolated static let logger = Logger(subsystem: "ai.lumen.app", category: "model-fleet")

    nonisolated enum ContractError: LocalizedError, Equatable {
        case missingContract(slot: LumenModelSlot, appVersion: String, modelConfigVersion: String)
        case incompleteMapping(missingSlots: [LumenModelSlot], appVersion: String, modelConfigVersion: String)

        var errorDescription: String? {
            switch self {
            case .missingContract(let slot, let appVersion, let modelConfigVersion):
                return "Missing LumenModelSlotContract for slot=\(slot.rawValue) appVersion=\(appVersion) modelConfigVersion=\(modelConfigVersion)"
            case .incompleteMapping(let missingSlots, let appVersion, let modelConfigVersion):
                let slots = missingSlots.map(\.rawValue).sorted().joined(separator: ",")
                return "Incomplete LumenModelSlotContract mapping missingSlots=[\(slots)] appVersion=\(appVersion) modelConfigVersion=\(modelConfigVersion)"
            }
        }
    }
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

    private static let contractsBySlot: [LumenModelSlot: LumenModelSlotContract] = [
        .cortex: .cortex,
        .executor: .executor,
        .mouth: .mouth,
        .mimicry: .mimicry,
        .rem: .rem,
        .embedding: .embedding,
    ]

    static func contract(for slot: LumenModelSlot) -> LumenModelSlotContract? {
        switch slot {
        case .cortex: return contractsBySlot[.cortex]
        case .executor: return contractsBySlot[.executor]
        case .mouth: return contractsBySlot[.mouth]
        case .mimicry: return contractsBySlot[.mimicry]
        case .rem: return contractsBySlot[.rem]
        case .embedding: return contractsBySlot[.embedding]
        }
    }

    static func requiredContract(for slot: LumenModelSlot) throws -> LumenModelSlotContract {
        try requiredContract(for: slot, using: contractsBySlot)
    }

    static func requiredContract(for slot: LumenModelSlot, using mapping: [LumenModelSlot: LumenModelSlotContract]) throws -> LumenModelSlotContract {
        if let contract = mapping[slot] {
            return contract
        }
        let error = ContractError.missingContract(
            slot: slot,
            appVersion: appVersionString(),
            modelConfigVersion: fleetContractVersion
        )
        emitMissingContractTelemetry(for: error)
        throw error
    }

    static func validateCompletenessAtStartup() throws {
        try validateCompleteness(using: contractsBySlot)
    }

    static func validateCompleteness(using mapping: [LumenModelSlot: LumenModelSlotContract]) throws {
        let missing = LumenModelSlot.allCases.filter { mapping[$0] == nil }
        guard missing.isEmpty else {
            let error = ContractError.incompleteMapping(
                missingSlots: missing,
                appVersion: appVersionString(),
                modelConfigVersion: fleetContractVersion
            )
            missing.forEach { slot in
                emitMissingContractTelemetry(
                    for: .missingContract(slot: slot, appVersion: appVersionString(), modelConfigVersion: fleetContractVersion)
                )
            }
            throw error
        }
    }

    private static func emitMissingContractTelemetry(for error: ContractError) {
        guard case .missingContract(let slot, let appVersion, let modelConfigVersion) = error else { return }
        logger.error("slot_contract_missing slot=\(slot.rawValue, privacy: .public) appVersion=\(appVersion, privacy: .public) modelConfigVersion=\(modelConfigVersion, privacy: .public)")
    }

    private static func appVersionString() -> String {
        let bundle = Bundle.main
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return "\(short) (\(build))"
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
    let mode: LumenFleetRuntimeMode
    let assignments: [LumenModelSlot: LumenModelAssignment]
    let missingSlots: [LumenModelSlot]
    let targetResidentSlots: Set<LumenModelSlot>
    let runtimeResidentSlots: Set<LumenModelSlot>

    init(
        mode: LumenFleetRuntimeMode = .v0SingleRuntime,
        assignments: [LumenModelSlot: LumenModelAssignment],
        missingSlots: [LumenModelSlot],
        targetResidentSlots: Set<LumenModelSlot> = [],
        runtimeResidentSlots: Set<LumenModelSlot> = []
    ) {
        self.mode = mode
        self.assignments = assignments
        self.missingSlots = missingSlots
        self.targetResidentSlots = targetResidentSlots
        self.runtimeResidentSlots = runtimeResidentSlots
    }

    func assignment(for slot: LumenModelSlot) -> LumenModelAssignment? {
        assignments[slot]
    }

    var isRunnableV0: Bool {
        assignment(for: .cortex) != nil && assignment(for: .mouth) != nil
    }

    var isRunnableV1: Bool {
        assignment(for: .cortex) != nil
        && assignment(for: .executor) != nil
        && assignment(for: .mouth) != nil
        && assignment(for: .mimicry) != nil
    }
}

@MainActor
enum LumenModelFleetResolver {
    static func resolveV0(appState: AppState, storedModels: [StoredModel]) -> LumenModelFleetSnapshot {
        resolveV0(
            activeChatModelID: appState.activeChatModelID,
            activeEmbeddingModelID: appState.activeEmbeddingModelID,
            storedModels: storedModels
        )
    }

    static func resolveV0(settings: SettingsSnapshot, storedModels: [StoredModel]) -> LumenModelFleetSnapshot {
        resolveV0(
            activeChatModelID: settings.activeChatModelID,
            activeEmbeddingModelID: settings.activeEmbeddingModelID,
            storedModels: storedModels
        )
    }

    static func resolveV0(activeChatModelID: String?, activeEmbeddingModelID: String?, storedModels: [StoredModel]) -> LumenModelFleetSnapshot {
        var assignments: [LumenModelSlot: LumenModelAssignment] = [:]
        let textModels = storedModels.filter { $0.modelRole == .chat }
        let activeText = activeChatModelID.flatMap { id in textModels.first { $0.id.uuidString == id } }
        let runtimeText = activeText ?? preferredTextModel(from: textModels)

        if let runtimeText {
            for slot in [LumenModelSlot.cortex, .executor, .mouth, .mimicry, .rem] {
                assignments[slot] = assignment(slot: slot, model: runtimeText)
            }
        }

        if let embed = preferredEmbedding(activeEmbeddingModelID: activeEmbeddingModelID, storedModels: storedModels) {
            assignments[.embedding] = assignment(slot: .embedding, model: embed)
        }

        let missing = LumenModelSlot.allCases.filter { assignments[$0] == nil }
        return LumenModelFleetSnapshot(
            mode: .v0SingleRuntime,
            assignments: assignments,
            missingSlots: missing,
            targetResidentSlots: Set(assignments.keys),
            runtimeResidentSlots: Set(assignments.keys)
        )
    }

    static func resolveV1(appState: AppState, storedModels: [StoredModel]) -> LumenModelFleetSnapshot {
        resolveV1(
            activeChatModelID: appState.activeChatModelID,
            activeEmbeddingModelID: appState.activeEmbeddingModelID,
            storedModels: storedModels
        )
    }

    static func resolveV1(settings: SettingsSnapshot, storedModels: [StoredModel]) -> LumenModelFleetSnapshot {
        resolveV1(
            activeChatModelID: settings.activeChatModelID,
            activeEmbeddingModelID: settings.activeEmbeddingModelID,
            storedModels: storedModels
        )
    }

    static func resolveV1(activeChatModelID: String?, activeEmbeddingModelID: String?, storedModels: [StoredModel]) -> LumenModelFleetSnapshot {
        var assignments: [LumenModelSlot: LumenModelAssignment] = [:]
        let textModels = storedModels.filter { $0.modelRole == .chat }
        let activeText = activeChatModelID.flatMap { id in textModels.first { $0.id.uuidString == id } }
        let fallbackText = activeText ?? preferredTextModel(from: textModels)

        for slot in [LumenModelSlot.cortex, .executor, .mouth, .mimicry, .rem] {
            if let model = preferredModel(for: slot, storedModels: textModels) ?? fallbackText {
                assignments[slot] = assignment(slot: slot, model: model)
            }
        }

        if let embed = preferredEmbedding(activeEmbeddingModelID: activeEmbeddingModelID, storedModels: storedModels) {
            assignments[.embedding] = assignment(slot: .embedding, model: embed)
        }

        let missing = LumenModelSlot.allCases.filter { assignments[$0] == nil }
        let runtimeResident = Set([LumenModelSlot.cortex, .embedding].filter { assignments[$0] != nil })
        return LumenModelFleetSnapshot(
            mode: .v1MultiResidentPlanned,
            assignments: assignments,
            missingSlots: missing,
            targetResidentSlots: Set(assignments.keys),
            runtimeResidentSlots: runtimeResident
        )
    }

    private static func preferredEmbedding(activeEmbeddingModelID: String?, storedModels: [StoredModel]) -> StoredModel? {
        let embedModels = storedModels.filter { $0.modelRole == .embedding }
        let activeEmbed = activeEmbeddingModelID.flatMap { id in
            embedModels.first { $0.id.uuidString == id }
        }
        return activeEmbed
            ?? preferredModel(for: .embedding, storedModels: embedModels)
            ?? mostRecentModel(from: embedModels)
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
            return ["1.5b": 70, "coder": 60, "qwen": 35, "cortex": 25, "0.5b": 10]
        case .executor:
            return ["coder": 65, "qwen": 35, "0.5b": 25, "json": 15, "structured": 15]
        case .mouth:
            return ["qwen": 40, "voice": 25, "mouth": 25, "smollm": 15, "0.5b": 15]
        case .mimicry:
            return ["qwen": 40, "mimicry": 30, "voice": 20, "0.5b": 20, "smollm": 10]
        case .rem:
            return ["phi": 60, "3.5": 35, "smollm": 35, "rem": 30, "idle": 15, "1.7b": 10]
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
