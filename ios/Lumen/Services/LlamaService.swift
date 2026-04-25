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
        attachments: [ChatAttachment] = []
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
    var loadedChatPath: String? { modelPath }
    var loadedEmbedPath: String? { embedModelPath }

    /// Load a GGUF model from your bundle.
    func loadModel(named name: String, contextSize: UInt32 = 4096, batchSize: UInt32 = 512) throws {
        guard let url = Bundle.main.url(forResource: name, withExtension: "gguf") else {
            throw NSError(domain: "Model not found", code: 1)
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
        seed: UInt32 = 42
    ) async throws -> AsyncThrowingStream<String, Error> {
        guard let service else { throw NSError(domain: "Model not loaded", code: 2) }
        let sampling = LlamaSamplingConfig(temperature: temperature, seed: seed)
        return try await service.streamCompletion(of: messages, samplingConfig: sampling)
    }

    /// Generate a full response at once.
    func respond(
        messages: [LlamaChatMessage],
        temperature: Float = 0.8,
        seed: UInt32 = 42
    ) async throws -> String {
        guard let service else { throw NSError(domain: "Model not loaded", code: 2) }
        let sampling = LlamaSamplingConfig(temperature: temperature, seed: seed)
        return try await service.respond(to: messages, samplingConfig: sampling)
    }

    /// Clear the KV cache.
    func resetKVCache() async {
        service = nil
        guard let modelPath else { return }
        let config = LlamaConfig(batchSize: 512, maxTokenCount: UInt32(max(1, contextSize)), useGPU: false)
        service = SwiftLlama.LlamaService(modelUrl: URL(fileURLWithPath: modelPath), config: config)
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
                    let stream = try await self.streamResponse(
                        messages: messages,
                        temperature: Float(req.temperature),
                        seed: 42
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
