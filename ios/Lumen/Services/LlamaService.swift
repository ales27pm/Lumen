import Foundation
import SwiftLlama

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
    case modelNotFound
}

extension LlamaError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .noModelLoaded:
            return "No model is currently loaded."
        case .modelNotFound:
            return "Model file could not be found."
        }
    }
}

/// A high-level service for GGUF models powered by llama.cpp.
/// Manages the model and KV cache using SwiftLlama's built-in types.
final actor AppLlamaService {
    static let shared = AppLlamaService()

    private var service: SwiftLlama.LlamaService?
    private var modelPath: String?
    private var embedModelPath: String?
    private var contextSize: Int = 4096

    private init() {}

    // MARK: - Compatibility API

    var isChatLoaded: Bool { service != nil }
    var isEmbedLoaded: Bool { embedModelPath != nil }
    var hasSemanticEmbeddingRuntime: Bool { false }
    var loadedChatPath: String? { modelPath }
    var loadedEmbedPath: String? { embedModelPath }

    /// Load a GGUF model from your bundle.
    func loadModel(named name: String, contextSize: UInt32 = 4096, batchSize: UInt32 = 512) throws {
        guard let url = Bundle.main.url(forResource: name, withExtension: "gguf") else {
            throw LlamaError.modelNotFound
        }

        let config = LlamaConfig(batchSize: batchSize, maxTokenCount: contextSize, useGPU: false)
        service = SwiftLlama.LlamaService(modelUrl: url, config: config)
        modelPath = url.path
        self.contextSize = Int(contextSize)
    }

    func loadChatModel(path: String, contextSize: Int = 4096) async throws {
        let url = URL(fileURLWithPath: path)
        let config = LlamaConfig(batchSize: 512, maxTokenCount: UInt32(max(1, contextSize)), useGPU: false)
        service = SwiftLlama.LlamaService(modelUrl: url, config: config)
        modelPath = path
        self.contextSize = contextSize
    }

    func loadEmbeddingModel(path: String) async throws {
        // TODO: SwiftLlama chat path is integrated, but semantic embedding extraction has not
        // been wired yet. Keep this path so settings can retain user preference while `embed(text:)`
        // continues to use deterministic hash embeddings.
        guard !path.isEmpty else { throw LlamaError.noModelLoaded }
        embedModelPath = path
    }

    func unloadChat() async {
        service = nil
        modelPath = nil
    }

    func unloadEmbed() async {
        embedModelPath = nil
    }

    func reloadChat(contextSize: Int = 4096) async throws {
        guard let modelPath else { throw LlamaError.noModelLoaded }
        try await loadChatModel(path: modelPath, contextSize: contextSize)
    }

    func reloadEmbed() async throws {
        guard let embedModelPath else { throw LlamaError.noModelLoaded }
        try await loadEmbeddingModel(path: embedModelPath)
    }

    /// Stream a response from the LLM, yielding tokens incrementally.
    func streamResponse(
        messages: [LlamaChatMessage],
        temperature: Float = 0.8,
        topP: Float = 0.95,
        repetitionPenalty: Float = 1.1,
        maxTokens: Int? = nil,
        seed: UInt32? = nil
    ) async throws -> AsyncThrowingStream<String, Error> {
        guard let service else { throw LlamaError.noModelLoaded }

        let resolvedSeed = seed ?? makeRandomSeed()
        let sampling = LlamaSamplingConfig(
            temperature: temperature,
            seed: resolvedSeed,
            topP: topP,
            repetitionPenaltyConfig: LlamaRepetitionPenaltyConfig(repeatPenalty: repetitionPenalty)
        )
        let rawStream = try await service.streamCompletion(of: messages, samplingConfig: sampling)
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

    /// Generate a full response at once.
    func respond(
        messages: [LlamaChatMessage],
        temperature: Float = 0.8,
        topP: Float = 0.95,
        repetitionPenalty: Float = 1.1,
        maxTokens: Int? = nil,
        seed: UInt32? = nil
    ) async throws -> String {
        guard service != nil else { throw LlamaError.noModelLoaded }
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

    /// Fully restarts the model service to force a fresh session.
    /// This is expensive because it recreates `SwiftLlama.LlamaService` and remaps GGUF.
    func restartSession() async {
        service = nil
        guard let modelPath else { return }
        let config = LlamaConfig(batchSize: 512, maxTokenCount: UInt32(max(1, contextSize)), useGPU: false)
        service = SwiftLlama.LlamaService(modelUrl: URL(fileURLWithPath: modelPath), config: config)
    }

    /// Backwards-compatible alias for older call sites.
    /// Note: this performs a full model service restart (not an in-place KV clear).
    func resetKVCache() async {
        await restartSession()
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

    func embed(text: String, dimensions: Int = 256) async -> [Double] {
        hashEmbed(text: text, dimensions: dimensions)
    }

    private func stopActiveCompletion() async {
        await service?.stopCompletion()
    }

    private func makeRandomSeed() -> UInt32 {
        UInt32.random(in: UInt32.min...UInt32.max)
    }

    // MARK: - Prompt building

    private func buildMessages(req: GenerateRequest) -> [LlamaChatMessage] {
        let budget = PromptBudget.make(
            contextSize: contextSize,
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

    private func hashEmbed(text: String, dimensions: Int) -> [Double] {
        var v = [Double](repeating: 0, count: dimensions)
        let tokens = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        for token in tokens {
            var hash: UInt64 = 5381
            for ch in token.unicodeScalars {
                hash = (hash &* 33) &+ UInt64(ch.value)
            }
            let idx = Int(hash % UInt64(dimensions))
            v[idx] += 1.0
        }

        let norm = sqrt(v.reduce(0.0) { $0 + $1 * $1 })
        if norm > 0 {
            for i in 0..<v.count {
                v[i] /= norm
            }
        }

        return v
    }
}
