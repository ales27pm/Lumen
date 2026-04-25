import Foundation

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
    case modelLoadFailed(String)
    case contextInitFailed
    case tokenizationFailed
    case decodeFailed
}

private struct LlamaModelHandle {
    let modelPath: String
    let contextSize: Int

    func cancel() {
        // TODO: Cancel llama.cpp generation task when bridge is integrated.
    }

    func offload() async {
        // TODO: Release llama.cpp resources when bridge is integrated.
    }
}

actor LlamaService {
    static let shared = LlamaService()

    private var chatHandle: LlamaModelHandle?
    private var chatModelPath: String?

    private var embedHandle: LlamaModelHandle?
    private var embedModelPath: String?

    private var activeChatSessionID: String?

    // MARK: - Model loading

    func loadChatModel(path: String, contextSize: Int = 4096) async throws {
        if chatModelPath == path, chatHandle != nil { return }
        let hadPrevious = chatHandle != nil
        await unloadChat()
        if hadPrevious {
            try? await Task.sleep(for: .milliseconds(150))
        }

        do {
            chatHandle = try await makeHandle(path: path, contextSize: contextSize)
            chatModelPath = path
            invalidateChatCache()
        } catch {
            throw mapModelLoadError(error, modelPath: path)
        }
    }

    func loadEmbeddingModel(path: String) async throws {
        if embedModelPath == path, embedHandle != nil { return }
        let hadPrevious = embedHandle != nil
        await unloadEmbed()
        if hadPrevious {
            try? await Task.sleep(for: .milliseconds(150))
        }

        do {
            embedHandle = try await makeHandle(path: path, contextSize: 2048)
            embedModelPath = path
        } catch {
            throw mapModelLoadError(error, modelPath: path)
        }
    }

    func unloadChat() async {
        invalidateChatCache()
        guard let handle = chatHandle else {
            chatModelPath = nil
            return
        }
        handle.cancel()
        await handle.offload()
        chatHandle = nil
        chatModelPath = nil
    }

    func unloadEmbed() async {
        guard let handle = embedHandle else {
            embedModelPath = nil
            return
        }
        handle.cancel()
        await handle.offload()
        embedHandle = nil
        embedModelPath = nil
    }

    var isChatLoaded: Bool { chatHandle != nil }
    var isEmbedLoaded: Bool { embedHandle != nil }
    var loadedChatPath: String? { chatModelPath }
    var loadedEmbedPath: String? { embedModelPath }

    func reloadChat(contextSize: Int = 4096) async throws {
        guard let path = chatModelPath else { throw LlamaError.noModelLoaded }
        invalidateChatCache()
        await unloadChat()
        try await loadChatModel(path: path, contextSize: contextSize)
    }

    private func invalidateChatCache() {
        activeChatSessionID = nil
    }

    func reloadEmbed() async throws {
        guard let path = embedModelPath else { throw LlamaError.noModelLoaded }
        await unloadEmbed()
        try await loadEmbeddingModel(path: path)
    }

    // MARK: - Streaming generation

    func stream(_ req: GenerateRequest) -> AsyncStream<GenerationToken> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    guard var handle = chatHandle else {
                        throw LlamaError.noModelLoaded
                    }

                    let prompt = buildPrompt(req: req)
                    let stream = try await generate(prompt: prompt, req: req, using: &handle)
                    chatHandle = handle

                    for try await piece in stream {
                        if Task.isCancelled { break }
                        continuation.yield(.text(piece))
                    }

                    if !Task.isCancelled {
                        activeChatSessionID = req.sessionID ?? "model:\(req.modelName)"
                    }

                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    let message: String
                    switch error {
                    case LlamaError.noModelLoaded:
                        message = "No model loaded. Download and activate a chat model from the Models tab."
                    case LlamaError.modelLoadFailed(let path):
                        message = "Failed to load the model at \(path). The file may be corrupt or incompatible."
                    case LlamaError.contextInitFailed:
                        message = "Unable to initialize the llama.cpp context. Try a smaller context size."
                    case LlamaError.tokenizationFailed:
                        message = "Tokenization failed for this prompt."
                    case LlamaError.decodeFailed:
                        message = "Inference failed. The context may be full — start a new chat."
                    default:
                        message = "Generation error: \(error.localizedDescription)"
                    }
                    continuation.yield(.text(message))
                    continuation.yield(.done)
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func generate(
        prompt: String,
        req: GenerateRequest,
        using handle: inout LlamaModelHandle
    ) async throws -> AsyncThrowingStream<String, any Error> {
        let _ = prompt
        let _ = req
        let _ = handle
        // TODO: Stream tokens from a llama.cpp session backed by a reusable KV-cache.
        return AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    // MARK: - Prompt building

    private func buildPrompt(req: GenerateRequest) -> String {
        let budget = PromptBudget.make(
            contextSize: 4096,
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

        var messages: [(String, String)] = [("system", assembly.systemPrompt)]
        for h in assembly.history {
            let role: String
            switch h.role {
            case .user: role = "user"
            case .assistant: role = "assistant"
            case .system: continue
            case .tool: role = "tool"
            }
            messages.append((role, h.content))
        }
        messages.append(("user", assembly.userMessage))

        // TODO: Replace this fallback with llama.cpp-native prompt/session handling when bridge is integrated.
        var out = ""
        for (role, content) in messages {
            out += "<|im_start|>\(role)\n\(content)<|im_end|>\n"
        }
        out += "<|im_start|>assistant\n"
        return out
    }

    // MARK: - Embeddings

    func embed(text: String, dimensions: Int = 256) async -> [Double] {
        guard let handle = embedHandle else {
            return hashEmbed(text: text, dimensions: dimensions)
        }

        do {
            var copy = handle
            let stream = try await generate(
                prompt: "Embed this text as a compact semantic representation:\n\n\(text)",
                req: GenerateRequest(
                    systemPrompt: "",
                    history: [],
                    userMessage: text,
                    temperature: 0,
                    topP: 1,
                    repetitionPenalty: 1,
                    maxTokens: max(32, dimensions),
                    modelName: "embed",
                    relevantMemories: []
                ),
                using: &copy
            )
            embedHandle = copy

            var materialized = ""
            for try await token in stream {
                materialized.append(token)
                if materialized.count > 2048 { break }
            }
            return hashEmbed(text: materialized.isEmpty ? text : materialized, dimensions: dimensions)
        } catch {
            return hashEmbed(text: text, dimensions: dimensions)
        }
    }

    private func hashEmbed(text: String, dimensions: Int) -> [Double] {
        var v = [Double](repeating: 0, count: dimensions)
        let tokens = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        for token in tokens {
            var hash: UInt64 = 5381
            for ch in token.unicodeScalars { hash = (hash &* 33) &+ UInt64(ch.value) }
            let idx = Int(hash % UInt64(dimensions))
            v[idx] += 1.0
        }
        let norm = sqrt(v.reduce(0.0) { $0 + $1 * $1 })
        if norm > 0 { for i in 0..<v.count { v[i] /= norm } }
        return v
    }

    private func makeHandle(path: String, contextSize: Int) async throws -> LlamaModelHandle {
        // TODO: Create and initialize a llama.cpp model/session wrapper here.
        LlamaModelHandle(modelPath: path, contextSize: contextSize)
    }

    private func mapModelLoadError(_ error: Error, modelPath: String) -> LlamaError {
        let _ = error
        return .modelLoadFailed(modelPath)
    }
}

