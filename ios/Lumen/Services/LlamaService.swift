import Foundation
import OSLog
import SwiftLlama
import llama

nonisolated struct GenerateRequest: Sendable {
    let sessionID: String?
    let systemPrompt: String
    let history: [(role: MessageRole, content: String)]
    let userMessage: String
    let temperature: Double
    let topP: Double
    let repetitionPenalty: Double
    let maxTokens: Int
    let modelName: String
    let relevantMemories: [MemoryContextItem]
    let attachments: [ChatAttachment]
    let seed: UInt32?

    init(
        sessionID: String? = nil,
        systemPrompt: String,
        history: [(role: MessageRole, content: String)],
        userMessage: String,
        temperature: Double,
        topP: Double,
        repetitionPenalty: Double,
        maxTokens: Int,
        modelName: String,
        relevantMemories: [MemoryContextItem],
        attachments: [ChatAttachment] = [],
        seed: UInt32? = nil
    ) {
        self.sessionID = sessionID
        self.systemPrompt = systemPrompt
        self.history = history
        self.userMessage = userMessage
        self.temperature = temperature
        self.topP = topP
        self.repetitionPenalty = repetitionPenalty
        self.maxTokens = maxTokens
        self.modelName = modelName
        self.relevantMemories = relevantMemories
        self.attachments = attachments
        self.seed = seed
    }

    init(
        sessionID: String? = nil,
        systemPrompt: String,
        history: [(role: MessageRole, content: String)],
        userMessage: String,
        temperature: Double,
        topP: Double,
        repetitionPenalty: Double,
        maxTokens: Int,
        modelName: String,
        legacyRelevantMemories: [String],
        attachments: [ChatAttachment] = [],
        seed: UInt32? = nil
    ) {
        self.init(
            sessionID: sessionID,
            systemPrompt: systemPrompt,
            history: history,
            userMessage: userMessage,
            temperature: temperature,
            topP: topP,
            repetitionPenalty: repetitionPenalty,
            maxTokens: maxTokens,
            modelName: modelName,
            relevantMemories: MemoryContextAdapter.fromLegacyStrings(legacyRelevantMemories),
            attachments: attachments,
            seed: seed
        )
    }
}

nonisolated enum GenerationToken: Sendable {
    case text(String)
    case done
}

nonisolated enum LlamaError: Error, Sendable {
    case noModelLoaded
    case slotModelNotLoaded(String)
    case modelFileNotFound(String)
    case failedToInitializeContext(String)
    case embeddingModelNotLoaded
    case embeddingFailed(String)
}

extension LlamaError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .noModelLoaded:
            return "No chat model is currently loaded."
        case .slotModelNotLoaded(let slot):
            return "No chat model is currently loaded for slot \(slot)."
        case .modelFileNotFound(let path):
            return "Model file not found at \(path)."
        case .failedToInitializeContext(let details):
            return "Failed to initialize context: \(details)"
        case .embeddingModelNotLoaded:
            return "No embedding model is currently loaded."
        case .embeddingFailed(let details):
            return "Failed to compute embedding: \(details)"
        }
    }
}

private struct ChatRuntime {
    var service: SwiftLlama.LlamaService
    var modelPath: String
    var contextSize: Int
    var batchSize: UInt32
}

private enum LlamaLog {
    static let subsystem = "com.lumen.runtime"
    static let category = "llama.service"
    static let service = Logger(subsystem: subsystem, category: category)
}

private enum LlamaErrorCode: String {
    case network = "network"
    case decode = "decode"
    case modelLoad = "model-load"
    case timeout = "timeout"
    case runtime = "runtime"
}

final actor AppLlamaService {
    static let shared = AppLlamaService()

    private var chatRuntimes: [LumenModelSlot: ChatRuntime] = [:]
    private var primaryChatSlot: LumenModelSlot = .cortex

    private var embeddingModelPath: String?
    private var embeddingModel: LlamaModel?
    private var embeddingContext: LlamaContext?
    private var embeddingContextSize: UInt32 = 2048
    private var embeddingBatchSize: UInt32 = 256
    private var embeddingThreads: Int32 = 1

    private init() {}

    var isChatLoaded: Bool { chatRuntimes[primaryChatSlot] != nil || !chatRuntimes.isEmpty }
    var isEmbedLoaded: Bool { embeddingContext != nil }
    var hasSemanticEmbeddingRuntime: Bool { embeddingContext != nil }
    var loadedChatPath: String? { chatRuntimes[primaryChatSlot]?.modelPath ?? chatRuntimes.values.first?.modelPath }
    var loadedEmbedPath: String? { embeddingModelPath }

    var loadedChatPathsBySlot: [LumenModelSlot: String] {
        Dictionary(uniqueKeysWithValues: chatRuntimes.map { ($0.key, $0.value.modelPath) })
    }

    func isChatLoaded(for slot: LumenModelSlot) -> Bool {
        chatRuntimes[slot] != nil
    }

    func loadedChatPath(for slot: LumenModelSlot) -> String? {
        chatRuntimes[slot]?.modelPath
    }

    func loadModel(named name: String, contextSize: UInt32 = 2048, batchSize: UInt32 = 256) throws {
        guard let url = Bundle.main.url(forResource: name, withExtension: "gguf") else {
            throw LlamaError.modelFileNotFound("Bundle resource: \(name).gguf")
        }
        try loadChatModelSync(path: url.path, slot: primaryChatSlot, contextSize: Int(contextSize), batchSize: batchSize)
    }

    func loadChatModel(path: String, contextSize: Int = 2048) async throws {
        try loadChatModelSync(path: path, slot: primaryChatSlot, contextSize: contextSize, batchSize: 256)
    }

    func loadChatModel(path: String, for slot: LumenModelSlot, contextSize: Int = 2048) async throws {
        try loadChatModelSync(path: path, slot: slot, contextSize: contextSize, batchSize: 256)
        if primaryChatSlot == .cortex || chatRuntimes[primaryChatSlot] == nil {
            primaryChatSlot = slot
        }
    }

    func loadFleetChatModels(assignments: [LumenModelSlot: LumenModelAssignment], contextSize: Int = 2048) async -> [LumenModelSlot: String] {
        var failures: [LumenModelSlot: String] = [:]
        for slot in [LumenModelSlot.cortex, .executor, .mouth, .mimicry, .rem] {
            guard let assignment = assignments[slot] else { continue }
            do {
                try await loadChatModel(path: assignment.localPath, for: slot, contextSize: contextSize)
            } catch {
                failures[slot] = error.localizedDescription
            }
        }
        return failures
    }

    func loadEmbeddingModel(path: String) async throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw LlamaError.modelFileNotFound(path)
        }

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 0

        guard let model = LlamaModel(path: path, parameters: modelParams) else {
            throw LlamaError.failedToInitializeContext("Unable to load embedding GGUF")
        }

        guard let context = makeEmbeddingContext(for: model) else {
            throw LlamaError.failedToInitializeContext("Unable to create embedding context")
        }

        context.setEmbeddingsOutput(true)
        context.setCausalAttention(false)

        embeddingModel = model
        embeddingContext = context
        embeddingModelPath = path
    }

    func unloadChat() async {
        chatRuntimes.removeValue(forKey: primaryChatSlot)
        if let first = chatRuntimes.keys.first {
            primaryChatSlot = first
        }
    }

    func unloadChat(for slot: LumenModelSlot) async {
        chatRuntimes.removeValue(forKey: slot)
        if primaryChatSlot == slot, let first = chatRuntimes.keys.first {
            primaryChatSlot = first
        }
    }

    func unloadAllChat() async {
        chatRuntimes.removeAll()
        primaryChatSlot = .cortex
    }

    func unloadEmbed() async {
        embeddingModelPath = nil
        embeddingModel = nil
        embeddingContext = nil
    }

    func reloadChat(contextSize: Int = 2048) async throws {
        guard let runtime = chatRuntimes[primaryChatSlot] ?? chatRuntimes.values.first else { throw LlamaError.noModelLoaded }
        try loadChatModelSync(path: runtime.modelPath, slot: primaryChatSlot, contextSize: contextSize, batchSize: runtime.batchSize)
    }

    func reloadChat(for slot: LumenModelSlot, contextSize: Int = 2048) async throws {
        guard let runtime = chatRuntimes[slot] else { throw LlamaError.slotModelNotLoaded(slot.rawValue) }
        try loadChatModelSync(path: runtime.modelPath, slot: slot, contextSize: contextSize, batchSize: runtime.batchSize)
    }

    func reloadEmbed() async throws {
        guard let embeddingModelPath else { throw LlamaError.embeddingModelNotLoaded }
        try await loadEmbeddingModel(path: embeddingModelPath)
    }

    func streamResponse(
        messages: [LlamaChatMessage],
        temperature: Float = 0.8,
        topP: Float = 0.95,
        repetitionPenalty: Float = 1.1,
        maxTokens: Int? = nil,
        seed: UInt32? = nil
    ) async throws -> AsyncThrowingStream<String, Error> {
        guard let runtime = chatRuntimes[primaryChatSlot] ?? chatRuntimes.values.first else {
            throw LlamaError.noModelLoaded
        }
        return try await streamResponse(
            runtime: runtime,
            stopSlot: primaryChatSlot,
            messages: messages,
            temperature: temperature,
            topP: topP,
            repetitionPenalty: repetitionPenalty,
            maxTokens: maxTokens,
            seed: seed
        )
    }

    func streamResponse(
        slot: LumenModelSlot,
        messages: [LlamaChatMessage],
        temperature: Float = 0.8,
        topP: Float = 0.95,
        repetitionPenalty: Float = 1.1,
        maxTokens: Int? = nil,
        seed: UInt32? = nil
    ) async throws -> AsyncThrowingStream<String, Error> {
        guard let runtime = chatRuntimes[slot] else {
            throw LlamaError.slotModelNotLoaded(slot.rawValue)
        }
        return try await streamResponse(
            runtime: runtime,
            stopSlot: slot,
            messages: messages,
            temperature: temperature,
            topP: topP,
            repetitionPenalty: repetitionPenalty,
            maxTokens: maxTokens,
            seed: seed
        )
    }

    private func streamResponse(
        runtime: ChatRuntime,
        stopSlot: LumenModelSlot,
        messages: [LlamaChatMessage],
        temperature: Float,
        topP: Float,
        repetitionPenalty: Float,
        maxTokens: Int?,
        seed: UInt32?
    ) async throws -> AsyncThrowingStream<String, Error> {
        let resolvedSeed = seed ?? makeRandomSeed()
        let sampling = LlamaSamplingConfig(
            temperature: temperature,
            seed: resolvedSeed,
            topP: topP,
            repetitionPenaltyConfig: LlamaRepetitionPenaltyConfig(repeatPenalty: repetitionPenalty)
        )
        let rawStream = try await runtime.service.streamCompletion(of: messages, samplingConfig: sampling)
        guard let maxTokens else { return rawStream }

        return AsyncThrowingStream { continuation in
            let cap = max(0, maxTokens)
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                if cap == 0 {
                    await self.stopCompletion(for: stopSlot)
                    continuation.finish()
                    return
                }

                var emitted = 0
                do {
                    for try await chunk in rawStream {
                        continuation.yield(chunk)
                        emitted += 1
                        if emitted >= cap {
                            await self.stopCompletion(for: stopSlot)
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    func respond(
        messages: [LlamaChatMessage],
        temperature: Float = 0.8,
        topP: Float = 0.95,
        repetitionPenalty: Float = 1.1,
        maxTokens: Int? = nil,
        seed: UInt32? = nil
    ) async throws -> String {
        let stream = try await streamResponse(
            messages: messages,
            temperature: temperature,
            topP: topP,
            repetitionPenalty: repetitionPenalty,
            maxTokens: maxTokens,
            seed: seed
        )
        var output = ""
        for try await chunk in stream {
            output += chunk
        }
        return output
    }

    func respond(
        slot: LumenModelSlot,
        messages: [LlamaChatMessage],
        temperature: Float = 0.8,
        topP: Float = 0.95,
        repetitionPenalty: Float = 1.1,
        maxTokens: Int? = nil,
        seed: UInt32? = nil
    ) async throws -> String {
        let stream = try await streamResponse(
            slot: slot,
            messages: messages,
            temperature: temperature,
            topP: topP,
            repetitionPenalty: repetitionPenalty,
            maxTokens: maxTokens,
            seed: seed
        )
        var output = ""
        for try await chunk in stream {
            output += chunk
        }
        return output
    }

    func resetKVCache() async {
        let runtimes = chatRuntimes
        for (slot, runtime) in runtimes {
            do {
                try loadChatModelSync(path: runtime.modelPath, slot: slot, contextSize: runtime.contextSize, batchSize: runtime.batchSize)
            } catch {
                chatRuntimes.removeValue(forKey: slot)
            }
        }
    }

    func resetKVCache(for slot: LumenModelSlot) async {
        guard let runtime = chatRuntimes[slot] else { return }
        do {
            try loadChatModelSync(path: runtime.modelPath, slot: slot, contextSize: runtime.contextSize, batchSize: runtime.batchSize)
        } catch {
            chatRuntimes.removeValue(forKey: slot)
        }
    }

    func stream(_ req: GenerateRequest) -> AsyncStream<GenerationToken> {
        stream(req, slot: primaryChatSlot)
    }

    func stream(_ req: GenerateRequest, slot: LumenModelSlot) -> AsyncStream<GenerationToken> {
        let messages = buildMessages(req: req, contextSize: chatRuntimes[slot]?.contextSize ?? 2048)

        return AsyncStream { continuation in
            let generationTask = Task { [weak self] in
                guard let self else {
                    continuation.yield(.done)
                    continuation.finish()
                    return
                }

                do {
                    guard req.maxTokens > 0 else {
                        continuation.yield(.done)
                        continuation.finish()
                        return
                    }

                    let stream = try await self.streamResponse(
                        slot: slot,
                        messages: messages,
                        temperature: Float(req.temperature),
                        topP: Float(req.topP),
                        repetitionPenalty: Float(req.repetitionPenalty),
                        maxTokens: req.maxTokens,
                        seed: req.seed
                    )
                    for try await chunk in stream {
                        continuation.yield(.text(chunk))
                    }
                } catch {
                    continuation.yield(.text("Generation error: \(error.localizedDescription)"))
                }

                continuation.yield(.done)
                continuation.finish()
            }

            continuation.onTermination = { @Sendable _ in
                generationTask.cancel()
            }
        }
    }

    func embed(_ text: String) async throws -> [Double] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        guard let embeddingModel else { throw LlamaError.embeddingModelNotLoaded }
        guard embeddingContext != nil else { throw LlamaError.embeddingModelNotLoaded }
        guard let embeddingContext = makeEmbeddingContext(for: embeddingModel) else {
            throw LlamaError.failedToInitializeContext("Unable to reset embedding context")
        }

        self.embeddingContext = embeddingContext

        let tokens = embeddingModel.tokenize(text: trimmed, addBos: embeddingModel.shouldAddBos(), special: false)
        guard !tokens.isEmpty else { return [] }

        if tokens.count >= Int(embeddingContext.contextSize()) {
            throw LlamaError.embeddingFailed("Input exceeds embedding context window")
        }

        embeddingContext.setEmbeddingsOutput(true)
        embeddingContext.setCausalAttention(false)

        let batch = LlamaBatch(initialSize: 1)
        do {
            for (index, token) in tokens.enumerated() {
                batch.reset()
                batch.addToken(token, at: Int32(index), logits: index == (tokens.count - 1))
                try embeddingContext.decode(batch: batch)
            }
        } catch {
            throw LlamaError.embeddingFailed(error.localizedDescription)
        }

        let raw = embeddingContext.pooledEmbeddings(for: 0) ?? embeddingContext.embeddings(at: -1) ?? []
        guard !raw.isEmpty else {
            throw LlamaError.embeddingFailed("Model returned an empty embedding vector")
        }

        return normalize(raw.map(Double.init))
    }

    func embed(text: String, dimensions: Int = 256) async -> [Double] {
        let requestID = UUID().uuidString
        do {
            return try await embed(text)
        } catch {
            let errorCode = classifyError(error)
            LlamaLog.service.error(
                "event=llama.embedding.failure severity=error error_code=\(errorCode.rawValue, privacy: .public) request_id=\(requestID, privacy: .public) dimensions=\(dimensions, privacy: .public) message=\(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    private func loadChatModelSync(path: String, slot: LumenModelSlot, contextSize: Int, batchSize: UInt32) throws {
        guard slot != .embedding else {
            throw LlamaError.failedToInitializeContext("Embedding slot cannot be loaded as chat")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw LlamaError.modelFileNotFound(path)
        }
        guard contextSize > 0 else {
            throw LlamaError.failedToInitializeContext("Context size must be greater than 0")
        }

        let config = LlamaConfig(
            batchSize: batchSize,
            maxTokenCount: UInt32(max(1, contextSize)),
            useGPU: false
        )
        let service = SwiftLlama.LlamaService(modelUrl: URL(fileURLWithPath: path), config: config)
        chatRuntimes[slot] = ChatRuntime(
            service: service,
            modelPath: path,
            contextSize: contextSize,
            batchSize: batchSize
        )
    }

    private func makeEmbeddingContext(for model: LlamaModel) -> LlamaContext? {
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = embeddingContextSize
        contextParams.n_batch = embeddingBatchSize
        contextParams.n_ubatch = embeddingBatchSize
        contextParams.n_threads = embeddingThreads
        contextParams.n_threads_batch = embeddingThreads
        contextParams.offload_kqv = false
        return LlamaContext(model: model, parameters: contextParams)
    }

    private func stopCompletion(for slot: LumenModelSlot) async {
        await chatRuntimes[slot]?.service.stopCompletion()
    }

    private func normalize(_ vector: [Double]) -> [Double] {
        let norm = sqrt(vector.reduce(0.0) { $0 + ($1 * $1) })
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    private func makeRandomSeed() -> UInt32 {
        UInt32.random(in: UInt32.min...UInt32.max)
    }

    private func buildMessages(req: GenerateRequest, contextSize: Int? = nil) -> [LlamaChatMessage] {
        let budget = PromptBudget.make(
            contextSize: contextSize ?? 2048,
            maxTokens: req.maxTokens,
            systemPromptChars: req.systemPrompt.count,
            userMessageChars: req.userMessage.count,
            hasAttachments: !req.attachments.isEmpty,
            hasMemories: !req.relevantMemories.isEmpty
        )

        let assembly = PromptAssembler.assemble(
            systemPrompt: req.systemPrompt,
            history: req.history,
            userMessage: req.userMessage,
            memories: req.relevantMemories,
            attachments: req.attachments,
            budget: budget,
            attachmentNormalization: req.modelName == "agent-json" ? .agentRouting : .preserveRaw
        )

        var messages: [LlamaChatMessage] = [
            LlamaChatMessage(role: .system, content: assembly.systemPrompt)
        ]

        for h in assembly.history {
            switch h.role {
            case .system:
                continue
            case .user:
                messages.append(LlamaChatMessage(role: .user, content: h.content))
            case .assistant:
                messages.append(LlamaChatMessage(role: .assistant, content: h.content))
            case .tool:
                messages.append(LlamaChatMessage(role: .user, content: h.content))
            }
        }

        messages.append(LlamaChatMessage(role: .user, content: assembly.userMessage))
        return messages
    }

    private func classifyError(_ error: Error) -> LlamaErrorCode {
        if let llamaError = error as? LlamaError {
            switch llamaError {
            case .modelFileNotFound, .failedToInitializeContext, .noModelLoaded, .slotModelNotLoaded, .embeddingModelNotLoaded:
                return .modelLoad
            case .embeddingFailed:
                return .decode
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut:
                return .timeout
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet:
                return .network
            default:
                return .runtime
            }
        }
        return .runtime
    }
}
