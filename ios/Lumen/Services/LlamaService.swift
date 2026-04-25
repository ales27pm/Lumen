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
    private typealias ModelFreeFn = @convention(c) (OpaquePointer?) -> Void
    private typealias ContextFreeFn = @convention(c) (OpaquePointer?) -> Void
    private typealias SamplerFreeFn = @convention(c) (OpaquePointer?) -> Void

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

    static func modelFree(_ model: OpaquePointer?) {
        resolve("llama_model_free", as: ModelFreeFn.self)?(model)
    }

    static func contextFree(_ context: OpaquePointer?) {
        resolve("llama_free", as: ContextFreeFn.self)?(context)
    }

    static func samplerFree(_ sampler: OpaquePointer?) {
        resolve("llama_sampler_free", as: SamplerFreeFn.self)?(sampler)
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
        modelPath = url.path
        self.contextSize = contextSize

        // The Swift package for llama.cpp can expose different symbol sets
        // across versions/platforms. If required native generation bindings are
        // unavailable at compile time, keep the app functional and surface a
        // clear runtime error from generation APIs.
        throw LlamaError.nativeBindingsUnavailable
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
        _ = (model, context, sampler, maxTokens, prompt, sessionID, onChunk)
        throw LlamaError.nativeBindingsUnavailable
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
        _ = (text, vocab, addSpecial)
        throw LlamaError.nativeBindingsUnavailable
    }

    private func decodeTokens(
        _ tokens: [LlamaToken],
        context: LlamaContextRef
    ) throws {
        _ = (tokens, context)
        throw LlamaError.nativeBindingsUnavailable
    }

    private func resetKVCache() {
        guard context != nil else { return }
        cachedPrompt = ""
        nPast = 0
    }

    private func tokenPieceString(
        vocab: LlamaVocabRef,
        token: LlamaToken
    ) -> String? {
        var piece = [CChar](repeating: 0, count: 256)

        while true {
            let length = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, true)
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
