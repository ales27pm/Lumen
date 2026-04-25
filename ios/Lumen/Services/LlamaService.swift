import Foundation
import llama   // exposes the C API via `llama.h`

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
    case notInitialized
    case noModelLoaded
    case couldNotLoadModel
    case couldNotInitContext
    case tokenizationFailed
    case decodeFailed
}

final actor LlamaService {
    static let shared = LlamaService()

    private var backendInitialized = false

    private var model: UnsafeMutablePointer<llama_model>? = nil
    private var context: UnsafeMutablePointer<llama_context>? = nil
    private var sampler: UnsafeMutablePointer<llama_sampler>? = nil

    private var modelPath: String?
    private var contextSize: Int = 4096
    private var activeSessionID: String?
    private var cachedPrompt: String = ""
    private var nPast: Int32 = 0

    private init() {}

    deinit {
        if let sampler {
            llama_sampler_free(sampler)
        }
        if let context {
            llama_free(context)
        }
        if let model {
            llama_model_free(model)
        }
        if backendInitialized {
            llama_backend_free()
        }
    }

    // MARK: - Compatibility API

    var isChatLoaded: Bool { model != nil && context != nil }
    var isEmbedLoaded: Bool { false }
    var loadedChatPath: String? { modelPath }
    var loadedEmbedPath: String? { nil }

    func loadChatModel(path: String, contextSize: Int = 4096) async throws {
        try loadModel(from: URL(fileURLWithPath: path), contextSize: contextSize)
    }

    func loadEmbeddingModel(path: String) async throws {
        let _ = path
    }

    func unloadChat() async {
        freeResources()
    }

    func unloadEmbed() async {}

    func reloadChat(contextSize: Int = 4096) async throws {
        guard let modelPath else { throw LlamaError.noModelLoaded }
        try loadModel(from: URL(fileURLWithPath: modelPath), contextSize: contextSize)
    }

    func reloadEmbed() async throws {}

    func stream(_ req: GenerateRequest) -> AsyncStream<GenerationToken> {
        let prompt = buildPrompt(req: req)
        let sessionID = req.sessionID ?? "model:\(req.modelName)"

        return AsyncStream { continuation in
            Task.detached { [weak self] in
                guard let self else {
                    continuation.yield(.done)
                    continuation.finish()
                    return
                }

                do {
                    let generated = try await self.generate(
                        prompt: prompt,
                        maxTokens: req.maxTokens,
                        sessionID: sessionID
                    )
                    for await chunk in generated {
                        continuation.yield(.text(chunk))
                    }
                } catch {
                    continuation.yield(.text("Generation error: \(error.localizedDescription)"))
                }

                continuation.yield(.done)
                continuation.finish()
            }
        }
    }

    func embed(text: String, dimensions: Int = 256) async -> [Double] {
        hashEmbed(text: text, dimensions: dimensions)
    }

    // MARK: - Native llama.cpp API

    func loadModel(from url: URL, contextSize: Int) throws {
        freeResources()

        if !backendInitialized {
            llama_backend_init()
            backendInitialized = true
        }

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 0

        let loadedModel = url.path.withCString { pathPtr in
            llama_model_load_from_file(pathPtr, modelParams)
        }
        guard let loadedModel else {
            throw LlamaError.couldNotLoadModel
        }

        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = UInt32(max(1, contextSize))

        guard let loadedContext = llama_init_from_model(loadedModel, ctxParams) else {
            llama_model_free(loadedModel)
            throw LlamaError.couldNotInitContext
        }

        var chainParams = llama_sampler_chain_default_params()
        guard let loadedSampler = llama_sampler_chain_init(chainParams) else {
            llama_free(loadedContext)
            llama_model_free(loadedModel)
            throw LlamaError.notInitialized
        }

        llama_sampler_chain_add(loadedSampler, llama_sampler_init_greedy())

        model = loadedModel
        context = loadedContext
        sampler = loadedSampler
        modelPath = url.path
        self.contextSize = contextSize
        activeSessionID = nil
        cachedPrompt = ""
        nPast = 0
    }

    func generate(prompt: String, maxTokens: Int, sessionID: String) async throws -> AsyncStream<String> {
        guard let model, let context, let sampler else {
            throw LlamaError.notInitialized
        }

        let vocab = llama_model_get_vocab(model)
        if activeSessionID != sessionID {
            resetKVCache()
            activeSessionID = sessionID
        }

        var promptToEval = prompt
        if !cachedPrompt.isEmpty, prompt.hasPrefix(cachedPrompt) {
            promptToEval = String(prompt.dropFirst(cachedPrompt.count))
        } else if !cachedPrompt.isEmpty {
            resetKVCache()
        }

        if !promptToEval.isEmpty {
            let promptTokens = try tokenize(promptToEval, vocab: vocab, addSpecial: nPast == 0)
            try decodeTokens(promptTokens, context: context)
            cachedPrompt = prompt
        }

        let evalLimit = Int(llama_n_ctx(context))

        return AsyncStream { continuation in
            Task {
                for _ in 0..<maxTokens {
                    if Int(self.nPast) >= evalLimit - 1 {
                        break
                    }

                    let token = llama_sampler_sample(sampler, context, -1)
                    if llama_vocab_is_eog(vocab, token) {
                        break
                    }

                    do {
                        try self.decodeTokens([token], context: context)
                    } catch {
                        break
                    }

                    var piece = [CChar](repeating: 0, count: 256)
                    let length = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, true)
                    if length > 0 {
                        continuation.yield(String(cString: piece))
                    }
                }

                continuation.finish()
            }
        }
    }

    func freeResources() {
        if let sampler {
            llama_sampler_free(sampler)
            self.sampler = nil
        }
        if let context {
            llama_free(context)
            self.context = nil
        }
        if let model {
            llama_model_free(model)
            self.model = nil
        }
        modelPath = nil
        activeSessionID = nil
        cachedPrompt = ""
        nPast = 0
    }

    // MARK: - Prompt building

    private func buildPrompt(req: GenerateRequest) -> String {
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

        var out = ""
        for (role, content) in messages {
            out += "<|im_start|>\(role)\n\(content)<|im_end|>\n"
        }
        out += "<|im_start|>assistant\n"
        return out
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

    private func tokenize(
        _ text: String,
        vocab: UnsafePointer<llama_vocab>,
        addSpecial: Bool
    ) throws -> [llama_token] {
        var tokens = [llama_token](repeating: 0, count: max(256, text.utf8.count + 8))
        var nTokens = text.withCString { promptPtr in
            llama_tokenize(
                vocab,
                promptPtr,
                Int32(text.utf8.count),
                &tokens,
                Int32(tokens.count),
                addSpecial,
                false
            )
        }

        if nTokens < 0 {
            let required = Int(-nTokens)
            tokens = [llama_token](repeating: 0, count: required)
            nTokens = text.withCString { promptPtr in
                llama_tokenize(
                    vocab,
                    promptPtr,
                    Int32(text.utf8.count),
                    &tokens,
                    Int32(tokens.count),
                    addSpecial,
                    false
                )
            }
        }

        guard nTokens > 0 else {
            throw LlamaError.tokenizationFailed
        }

        return Array(tokens.prefix(Int(nTokens)))
    }

    private func decodeTokens(
        _ tokens: [llama_token],
        context: UnsafeMutablePointer<llama_context>
    ) throws {
        guard !tokens.isEmpty else { return }

        var batch = llama_batch_init(Int32(tokens.count), 0, 1)
        defer { llama_batch_free(batch) }

        for (index, token) in tokens.enumerated() {
            batch.token[index] = token
            batch.pos[index] = nPast + Int32(index)
            batch.n_seq_id[index] = 1
            batch.seq_id[index]![0] = 0
            batch.logits[index] = index == tokens.count - 1 ? 1 : 0
        }
        batch.n_tokens = Int32(tokens.count)

        if llama_decode(context, batch) != 0 {
            throw LlamaError.decodeFailed
        }

        nPast += Int32(tokens.count)
    }

    private func resetKVCache() {
        guard let context else { return }
        llama_memory_clear(llama_get_memory(context), true)
        if let sampler {
            llama_sampler_reset(sampler)
        }
        cachedPrompt = ""
        nPast = 0
    }
}
