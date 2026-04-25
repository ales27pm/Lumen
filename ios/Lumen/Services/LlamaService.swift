import Foundation
import llama   // exposes the C API via `llama.h`
import Darwin

private typealias LlamaModelRef = OpaquePointer
private typealias LlamaContextRef = OpaquePointer
private typealias LlamaSamplerRef = OpaquePointer
private typealias LlamaVocabRef = OpaquePointer
private typealias LlamaToken = Int32

private nonisolated enum LlamaSymbolCompat {
    private typealias BackendInitFn = @convention(c) () -> Void
    private typealias BackendFreeFn = @convention(c) () -> Void
    private typealias ModelDefaultParamsFn = @convention(c) () -> llama_model_params
    private typealias ContextDefaultParamsFn = @convention(c) () -> llama_context_params
    private typealias ModelLoadFromFileFn = @convention(c) (UnsafePointer<CChar>, llama_model_params) -> OpaquePointer?
    private typealias ModelFreeFn = @convention(c) (OpaquePointer?) -> Void
    private typealias ContextFreeFn = @convention(c) (OpaquePointer?) -> Void
    private typealias SamplerFreeFn = @convention(c) (OpaquePointer?) -> Void
    private typealias TokenToPieceFn = @convention(c) (
        OpaquePointer?,
        Int32,
        UnsafeMutablePointer<CChar>?,
        Int32,
        Int32,
        Bool
    ) -> Int32

    private static func resolve<T>(_ symbol: String, as type: T.Type) -> T? {
        guard let ptr = dlsym(nil, symbol) else { return nil }
        return unsafeBitCast(ptr, to: type)
    }

    static func backendInit() {
        resolve("llama_backend_init", as: BackendInitFn.self)?()
    }

    static func backendFree() {
        resolve("llama_backend_free", as: BackendFreeFn.self)?()
    }

    static func modelDefaultParams() -> llama_model_params? {
        resolve("llama_model_default_params", as: ModelDefaultParamsFn.self)?()
    }

    static func contextDefaultParams() -> llama_context_params? {
        resolve("llama_context_default_params", as: ContextDefaultParamsFn.self)?()
    }

    static func modelLoadFromFile(_ path: UnsafePointer<CChar>, _ params: llama_model_params) -> OpaquePointer? {
        resolve("llama_model_load_from_file", as: ModelLoadFromFileFn.self)?(path, params)
    }

    static func modelFree(_ model: OpaquePointer?) {
        resolve("llama_model_free", as: ModelFreeFn.self)?(model)
    }

    static func contextFree(_ context: OpaquePointer?) {
        resolve("llama_free", as: ContextFreeFn.self)?(context)
    }

    static func samplerFree(_ sampler: OpaquePointer?) {
        resolve("llama_sampler_free", as: SamplerFreeFn.self)?(sampler)
    }

    static func tokenToPiece(
        _ vocab: OpaquePointer?,
        _ token: Int32,
        _ piece: UnsafeMutablePointer<CChar>?,
        _ length: Int32,
        _ special: Int32,
        _ parseSpecial: Bool
    ) -> Int32? {
        resolve("llama_token_to_piece", as: TokenToPieceFn.self)?(
            vocab,
            token,
            piece,
            length,
            special,
            parseSpecial
        )
    }
}

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
    case nativeBindingsUnavailable
    case tokenizationFailed
    case decodeFailed
}

extension LlamaError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "Model runtime is not initialized."
        case .noModelLoaded:
            return "No model is currently loaded."
        case .couldNotLoadModel:
            return "Failed to load the model file."
        case .couldNotInitContext:
            return "Failed to initialize model context. Try lowering context size."
        case .nativeBindingsUnavailable:
            return "Native llama runtime bindings are unavailable."
        case .tokenizationFailed:
            return "Prompt tokenization failed."
        case .decodeFailed:
            return "Model decode failed."
        }
    }
}

final actor LlamaService {
    static let shared = LlamaService()

    private var backendInitialized = false

    private var model: LlamaModelRef? = nil
    private var context: LlamaContextRef? = nil
    private var sampler: LlamaSamplerRef? = nil

    private var modelPath: String?
    private var embedModelPath: String?
    private var contextSize: Int = 4096
    private var activeSessionID: String?
    private var cachedPrompt: String = ""
    private var nPast: Int32 = 0

    private init() {}

    deinit {
        if let sampler {
            LlamaSymbolCompat.samplerFree(sampler)
        }
        if let context {
            LlamaSymbolCompat.contextFree(context)
        }
        if let model {
            LlamaSymbolCompat.modelFree(model)
        }
        if backendInitialized {
            LlamaSymbolCompat.backendFree()
        }
    }

    // MARK: - Compatibility API

    var isChatLoaded: Bool { model != nil && context != nil }
    var isEmbedLoaded: Bool { embedModelPath != nil }
    var loadedChatPath: String? { modelPath }
    var loadedEmbedPath: String? { embedModelPath }

    func loadChatModel(path: String, contextSize: Int = 4096) async throws {
        try loadModel(from: URL(fileURLWithPath: path), contextSize: contextSize)
    }

    func loadEmbeddingModel(path: String) async throws {
        guard !path.isEmpty else { throw LlamaError.noModelLoaded }
        embedModelPath = path
    }

    func unloadChat() async {
        freeResources()
    }

    func unloadEmbed() async {
        embedModelPath = nil
    }

    func reloadChat(contextSize: Int = 4096) async throws {
        guard let modelPath else { throw LlamaError.noModelLoaded }
        try loadModel(from: URL(fileURLWithPath: modelPath), contextSize: contextSize)
    }

    func reloadEmbed() async throws {
        guard let embedModelPath else { throw LlamaError.noModelLoaded }
        try await loadEmbeddingModel(path: embedModelPath)
    }

    func stream(_ req: GenerateRequest) -> AsyncStream<GenerationToken> {
        let prompt = buildPrompt(req: req)
        let sessionID = req.sessionID ?? "model:\(req.modelName)"

        return AsyncStream { continuation in
            let generationTask = Task { [weak self] in
                guard let self else {
                    continuation.yield(.done)
                    continuation.finish()
                    return
                }

                do {
                    try await self.generate(
                        prompt: prompt,
                        maxTokens: req.maxTokens,
                        sessionID: sessionID
                    ) { chunk in
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

    // MARK: - Native llama.cpp API

    func loadModel(from url: URL, contextSize: Int) throws {
        freeResources()
        guard let modelParamsDefault = LlamaSymbolCompat.modelDefaultParams(),
              let contextParamsDefault = LlamaSymbolCompat.contextDefaultParams() else {
            throw LlamaError.nativeBindingsUnavailable
        }

        if !backendInitialized {
            LlamaSymbolCompat.backendInit()
            backendInitialized = true
        }

        var modelParams = modelParamsDefault
        modelParams.n_gpu_layers = 0

        let loadedModel = url.path.withCString { pathPtr in
            LlamaSymbolCompat.modelLoadFromFile(pathPtr, modelParams)
        }
        guard let loadedModel else {
            throw LlamaError.couldNotLoadModel
        }

        var ctxParams = contextParamsDefault
        ctxParams.n_ctx = UInt32(max(1, contextSize))

        guard let loadedContext = llama_init_from_model(loadedModel, ctxParams) else {
            LlamaSymbolCompat.modelFree(loadedModel)
            throw LlamaError.couldNotInitContext
        }

        var chainParams = llama_sampler_chain_default_params()
        guard let loadedSampler = llama_sampler_chain_init(chainParams) else {
            LlamaSymbolCompat.contextFree(loadedContext)
            LlamaSymbolCompat.modelFree(loadedModel)
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

    func generate(
        prompt: String,
        maxTokens: Int,
        sessionID: String,
        onChunk: @Sendable (String) -> Void
    ) throws {
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
            if promptToEval == prompt && nPast > 0 {
                resetKVCache()
            }
            let promptTokens = try tokenize(promptToEval, vocab: vocab, addSpecial: nPast == 0)
            try decodeTokens(promptTokens, context: context)
            cachedPrompt = prompt
        }

        let evalLimit = Int(llama_n_ctx(context))

        for _ in 0..<maxTokens {
            if Task.isCancelled { break }
            if Int(self.nPast) >= evalLimit - 1 { break }

            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }

            try self.decodeTokens([token], context: context)
            if let piece = self.tokenPieceString(vocab: vocab, token: token) {
                onChunk(piece)
            }
        }
    }

    func freeResources() {
        if let sampler {
            LlamaSymbolCompat.samplerFree(sampler)
            self.sampler = nil
        }
        if let context {
            LlamaSymbolCompat.contextFree(context)
            self.context = nil
        }
        if let model {
            LlamaSymbolCompat.modelFree(model)
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
        vocab: LlamaVocabRef,
        addSpecial: Bool
    ) throws -> [LlamaToken] {
        var tokens = [LlamaToken](repeating: 0, count: max(256, text.utf8.count + 8))
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
            tokens = [LlamaToken](repeating: 0, count: required)
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
        _ tokens: [LlamaToken],
        context: LlamaContextRef
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

    private func tokenPieceString(
        vocab: LlamaVocabRef,
        token: LlamaToken
    ) -> String? {
        var piece = [CChar](repeating: 0, count: 256)

        while true {
            guard let length = LlamaSymbolCompat.tokenToPiece(
                vocab,
                token,
                &piece,
                Int32(piece.count),
                0,
                true
            ) else {
                return nil
            }
            if length < 0 {
                let required = max(Int(-length), piece.count * 2)
                piece = [CChar](repeating: 0, count: required)
                continue
            }
            if length == 0 {
                return nil
            }
            if Int(length) >= piece.count {
                piece = [CChar](repeating: 0, count: piece.count * 2)
                continue
            }

            return piece.withUnsafeBufferPointer { buffer in
                let bytes = UnsafeRawBufferPointer(start: buffer.baseAddress, count: Int(length))
                return String(bytes: bytes, encoding: .utf8)
            }
        }
    }
}
