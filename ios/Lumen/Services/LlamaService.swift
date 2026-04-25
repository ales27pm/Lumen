import Foundation
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
    let relevantMemories: [String]
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
        relevantMemories: [String],
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
}

nonisolated enum GenerationToken: Sendable {
    case text(String)
    case done
}

nonisolated enum LlamaError: Error, Sendable {
    case noModelLoaded
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

final actor AppLlamaService {
    static let shared = AppLlamaService()

    private var chatService: SwiftLlama.LlamaService?
    private var chatModelPath: String?
    private var chatContextSize: Int = 2048

    private var embeddingModelPath: String?
    private var embeddingModel: LlamaModel?
    private var embeddingContext: LlamaContext?

    private init() {}

    var isChatLoaded: Bool { chatService != nil }
    var isEmbedLoaded: Bool { embeddingContext != nil }
    var hasSemanticEmbeddingRuntime: Bool { embeddingContext != nil }
    var loadedChatPath: String? { chatModelPath }
    var loadedEmbedPath: String? { embeddingModelPath }

    func loadModel(named name: String, contextSize: UInt32 = 2048, batchSize: UInt32 = 256) throws {
        guard let url = Bundle.main.url(forResource: name, withExtension: "gguf") else {
            throw LlamaError.modelFileNotFound("Bundle resource: \(name).gguf")
        }
        try loadChatModelSync(path: url.path, contextSize: Int(contextSize), batchSize: batchSize)
    }

    func loadChatModel(path: String, contextSize: Int = 2048) async throws {
        try loadChatModelSync(path: path, contextSize: contextSize, batchSize: 256)
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

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = 2048
        contextParams.n_batch = 256
        contextParams.n_ubatch = 256
        contextParams.n_threads = 1
        contextParams.n_threads_batch = 1
        contextParams.offload_kqv = false

        guard let context = LlamaContext(model: model, parameters: contextParams) else {
            throw LlamaError.failedToInitializeContext("Unable to create embedding context")
        }

        context.setEmbeddingsOutput(true)
        context.setCausalAttention(false)

        embeddingModel = model
        embeddingContext = context
        embeddingModelPath = path
    }

    func unloadChat() async {
        chatService = nil
        chatModelPath = nil
    }

    func unloadEmbed() async {
        embeddingModelPath = nil
        embeddingModel = nil
        embeddingContext = nil
    }

    func reloadChat(contextSize: Int = 2048) async throws {
        guard let chatModelPath else { throw LlamaError.noModelLoaded }
        try loadChatModelSync(path: chatModelPath, contextSize: contextSize, batchSize: 256)
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
        guard let chatService else { throw LlamaError.noModelLoaded }

        let resolvedSeed = seed ?? makeRandomSeed()
        let sampling = LlamaSamplingConfig(
            temperature: temperature,
            seed: resolvedSeed,
            topP: topP,
            repetitionPenaltyConfig: LlamaRepetitionPenaltyConfig(repeatPenalty: repetitionPenalty)
        )
        let rawStream = try await chatService.streamCompletion(of: messages, samplingConfig: sampling)
        guard let maxTokens else { return rawStream }

        return AsyncThrowingStream { continuation in
            let cap = max(0, maxTokens)
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                if cap == 0 {
                    await self.stopActiveCompletion()
                    continuation.finish()
                    return
                }

                var emitted = 0
                do {
                    for try await chunk in rawStream {
                        continuation.yield(chunk)
                        emitted += 1
                        if emitted >= cap {
                            await self.stopActiveCompletion()
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
        guard chatService != nil else { throw LlamaError.noModelLoaded }
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

    func resetKVCache() async {
        guard let currentChatModelPath = chatModelPath else { return }
        do {
            try loadChatModelSync(path: currentChatModelPath, contextSize: chatContextSize, batchSize: 256)
        } catch {
            chatService = nil
            chatModelPath = nil
        }
    }

    func stream(_ req: GenerateRequest) -> AsyncStream<GenerationToken> {
        let messages = buildMessages(req: req)

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
        guard let embeddingContext else { throw LlamaError.embeddingModelNotLoaded }

        let tokens = embeddingModel.tokenize(text: trimmed, addBos: embeddingModel.shouldAddBos(), special: false)
        guard !tokens.isEmpty else { return [] }

        if tokens.count >= Int(embeddingContext.contextSize()) {
            throw LlamaError.embeddingFailed("Input exceeds embedding context window")
        }

        // NOTE:
        // `LlamaContext.clearKVCache()` can trap on some iOS/TestFlight builds when the
        // underlying runtime reports an unavailable buffer, even when `embeddingContext`
        // itself is non-nil. We avoid that call here and run each embedding pass with a
        // fresh `LlamaBatch` sequence instead.
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
        do {
            return try await embed(text)
        } catch {
            print("Embedding error: \(error.localizedDescription)")
            return []
        }
    }

    private func loadChatModelSync(path: String, contextSize: Int, batchSize: UInt32) throws {
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
        chatService = SwiftLlama.LlamaService(modelUrl: URL(fileURLWithPath: path), config: config)
        chatModelPath = path
        chatContextSize = contextSize
    }

    private func stopActiveCompletion() async {
        await chatService?.stopCompletion()
    }

    private func normalize(_ vector: [Double]) -> [Double] {
        let norm = sqrt(vector.reduce(0.0) { $0 + ($1 * $1) })
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    private func makeRandomSeed() -> UInt32 {
        UInt32.random(in: UInt32.min...UInt32.max)
    }

    private func buildMessages(req: GenerateRequest) -> [LlamaChatMessage] {
        let budget = PromptBudget.make(
            contextSize: chatContextSize,
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
}
