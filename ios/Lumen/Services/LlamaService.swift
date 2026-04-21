import Foundation
import LlamaSwift

nonisolated struct GenerateRequest: Sendable {
    let systemPrompt: String
    let history: [(role: MessageRole, content: String)]
    let userMessage: String
    let temperature: Double
    let topP: Double
    let repetitionPenalty: Double
    let maxTokens: Int
    let modelName: String
    let availableTools: [ToolDefinition]
    let relevantMemories: [String]
}

nonisolated enum GenerationToken: Sendable {
    case text(String)
    case toolCall(name: String, arguments: [String: String])
    case done
}

nonisolated enum LlamaError: Error, Sendable {
    case noModelLoaded
    case modelLoadFailed(String)
    case contextInitFailed
    case tokenizationFailed
    case decodeFailed
}

actor LlamaService {
    static let shared = LlamaService()

    private var backendReady = false

    private var chatModel: OpaquePointer?
    private var chatContext: OpaquePointer?
    private var chatVocab: OpaquePointer?
    private var chatModelPath: String?

    private var embedModel: OpaquePointer?
    private var embedContext: OpaquePointer?
    private var embedVocab: OpaquePointer?
    private var embedModelPath: String?

    // MARK: - Backend lifecycle

    private func ensureBackend() {
        guard !backendReady else { return }
        llama_backend_init()
        backendReady = true
    }

    // MARK: - Model loading

    func loadChatModel(path: String, contextSize: Int = 4096) throws {
        ensureBackend()
        if chatModelPath == path, chatModel != nil { return }
        unloadChat()

        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = 99
        guard let model = llama_model_load_from_file(path, mparams) else {
            throw LlamaError.modelLoadFailed(path)
        }

        var cparams = llama_context_default_params()
        cparams.n_ctx = UInt32(max(512, contextSize))
        cparams.n_batch = 512
        cparams.n_threads = Int32(max(2, ProcessInfo.processInfo.activeProcessorCount - 1))
        cparams.n_threads_batch = cparams.n_threads

        guard let ctx = llama_init_from_model(model, cparams) else {
            llama_model_free(model)
            throw LlamaError.contextInitFailed
        }

        chatModel = model
        chatContext = ctx
        chatVocab = llama_model_get_vocab(model)
        chatModelPath = path
    }

    func loadEmbeddingModel(path: String) throws {
        ensureBackend()
        if embedModelPath == path, embedModel != nil { return }
        unloadEmbed()

        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = 99
        guard let model = llama_model_load_from_file(path, mparams) else {
            throw LlamaError.modelLoadFailed(path)
        }

        var cparams = llama_context_default_params()
        cparams.n_ctx = 2048
        cparams.n_batch = 512
        cparams.embeddings = true
        cparams.n_threads = Int32(max(2, ProcessInfo.processInfo.activeProcessorCount - 1))
        cparams.n_threads_batch = cparams.n_threads

        guard let ctx = llama_init_from_model(model, cparams) else {
            llama_model_free(model)
            throw LlamaError.contextInitFailed
        }

        embedModel = model
        embedContext = ctx
        embedVocab = llama_model_get_vocab(model)
        embedModelPath = path
    }

    func unloadChat() {
        if let c = chatContext { llama_free(c) }
        if let m = chatModel { llama_model_free(m) }
        chatContext = nil
        chatModel = nil
        chatVocab = nil
        chatModelPath = nil
    }

    func unloadEmbed() {
        if let c = embedContext { llama_free(c) }
        if let m = embedModel { llama_model_free(m) }
        embedContext = nil
        embedModel = nil
        embedVocab = nil
        embedModelPath = nil
    }

    var isChatLoaded: Bool { chatModel != nil }
    var isEmbedLoaded: Bool { embedModel != nil }
    var loadedChatPath: String? { chatModelPath }
    var loadedEmbedPath: String? { embedModelPath }

    func reloadChat(contextSize: Int = 4096) throws {
        guard let path = chatModelPath else { throw LlamaError.noModelLoaded }
        unloadChat()
        try loadChatModel(path: path, contextSize: contextSize)
    }

    func reloadEmbed() throws {
        guard let path = embedModelPath else { throw LlamaError.noModelLoaded }
        unloadEmbed()
        try loadEmbeddingModel(path: path)
    }

    // MARK: - Streaming generation

    func stream(_ req: GenerateRequest) -> AsyncStream<GenerationToken> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    guard let model = chatModel,
                          let context = chatContext,
                          let vocab = chatVocab else {
                        throw LlamaError.noModelLoaded
                    }

                    let prompt = buildPrompt(req: req, model: model)
                    try await generate(
                        prompt: prompt,
                        context: context,
                        vocab: vocab,
                        req: req,
                        continuation: continuation
                    )
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
        context: OpaquePointer,
        vocab: OpaquePointer,
        req: GenerateRequest,
        continuation: AsyncStream<GenerationToken>.Continuation
    ) async throws {
        // Reset KV cache for fresh generation
        if let mem = llama_get_memory(context) {
            llama_memory_clear(mem, true)
        }

        // Tokenize prompt
        let utf8Count = prompt.utf8.count
        let maxTokens = utf8Count + 64
        var tokenBuf = [llama_token](repeating: 0, count: maxTokens)
        let tokenCount = prompt.withCString { cStr in
            llama_tokenize(vocab, cStr, Int32(utf8Count), &tokenBuf, Int32(maxTokens), true, true)
        }
        guard tokenCount > 0 else { throw LlamaError.tokenizationFailed }
        let promptTokens = Array(tokenBuf.prefix(Int(tokenCount)))

        // Prepare initial batch
        let nBatch = Int32(512)
        var batch = llama_batch_init(nBatch, 0, 1)
        defer { llama_batch_free(batch) }

        // Feed prompt in chunks
        var pos: Int32 = 0
        var idx = 0
        while idx < promptTokens.count {
            let chunkSize = min(Int(nBatch), promptTokens.count - idx)
            batch.n_tokens = Int32(chunkSize)
            for i in 0..<chunkSize {
                batch.token[i] = promptTokens[idx + i]
                batch.pos[i] = pos
                batch.n_seq_id[i] = 1
                if let seqIds = batch.seq_id, let seqId = seqIds[i] { seqId[0] = 0 }
                batch.logits[i] = 0
                pos += 1
            }
            let isLast = (idx + chunkSize) >= promptTokens.count
            if isLast {
                batch.logits[chunkSize - 1] = 1
            }
            if llama_decode(context, batch) != 0 { throw LlamaError.decodeFailed }
            idx += chunkSize
        }

        // Build sampler chain
        var sparams = llama_sampler_chain_default_params()
        guard let sampler = llama_sampler_chain_init(sparams) else { throw LlamaError.decodeFailed }
        defer { llama_sampler_free(sampler) }

        if req.repetitionPenalty > 1.0 {
            llama_sampler_chain_add(sampler, llama_sampler_init_penalties(64, Float(req.repetitionPenalty), 0.0, 0.0))
        }
        llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(Float(req.topP), 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(Float(req.temperature)))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 1...UInt32.max)))

        // Generate
        var generated = ""
        var outputTokens: [llama_token] = []
        var pieceBuf = [CChar](repeating: 0, count: 256)

        for _ in 0..<max(1, req.maxTokens) {
            if Task.isCancelled { break }

            let newToken = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, newToken) { break }

            let pieceLen = llama_token_to_piece(vocab, newToken, &pieceBuf, Int32(pieceBuf.count), 0, true)
            if pieceLen > 0 {
                let data = Data(bytes: pieceBuf, count: Int(pieceLen))
                if let piece = String(data: data, encoding: .utf8), !piece.isEmpty {
                    generated += piece
                    continuation.yield(.text(piece))
                }
            }
            outputTokens.append(newToken)

            // Feed the new token back
            batch.n_tokens = 1
            batch.token[0] = newToken
            batch.pos[0] = pos
            batch.n_seq_id[0] = 1
            if let seqIds = batch.seq_id, let seqId = seqIds[0] { seqId[0] = 0 }
            batch.logits[0] = 1
            pos += 1

            if llama_decode(context, batch) != 0 { throw LlamaError.decodeFailed }

            await Task.yield()
        }

        // Detect tool calls in the generated output
        if let call = parseToolCall(from: generated) {
            continuation.yield(.toolCall(name: call.name, arguments: call.args))
        }
    }

    // MARK: - Prompt building

    private func buildPrompt(req: GenerateRequest, model: OpaquePointer) -> String {
        var systemContent = req.systemPrompt

        if !req.availableTools.isEmpty {
            let toolLines = req.availableTools.map { "- \($0.id): \($0.description)" }.joined(separator: "\n")
            systemContent += "\n\nYou can call tools by emitting a line in this exact format on its own line:\n<tool_call>{\"name\":\"tool.id\",\"args\":{\"key\":\"value\"}}</tool_call>\n\nAvailable tools:\n\(toolLines)"
        }
        if !req.relevantMemories.isEmpty {
            let mem = req.relevantMemories.prefix(5).map { "• \($0)" }.joined(separator: "\n")
            systemContent += "\n\nRelevant memory from previous conversations:\n\(mem)"
        }

        var messages: [(String, String)] = [("system", systemContent)]
        for h in req.history {
            let role: String
            switch h.role {
            case .user: role = "user"
            case .assistant: role = "assistant"
            case .system: continue
            case .tool: role = "tool"
            }
            messages.append((role, h.content))
        }
        messages.append(("user", req.userMessage))

        // Try the model's built-in chat template
        if let templated = applyChatTemplate(model: model, messages: messages) {
            return templated
        }

        // Fallback: ChatML-style template
        var out = ""
        for (role, content) in messages {
            out += "<|im_start|>\(role)\n\(content)<|im_end|>\n"
        }
        out += "<|im_start|>assistant\n"
        return out
    }

    private func applyChatTemplate(model: OpaquePointer, messages: [(String, String)]) -> String? {
        // Convert to llama_chat_message array with stable C strings
        var roleStrings: [ContiguousArray<CChar>] = []
        var contentStrings: [ContiguousArray<CChar>] = []
        for (r, c) in messages {
            roleStrings.append(ContiguousArray(r.utf8CString))
            contentStrings.append(ContiguousArray(c.utf8CString))
        }

        let tmpl = llama_model_chat_template(model, nil)

        var result: String?
        roleStrings.withUnsafeBufferPointer { _ in
            contentStrings.withUnsafeBufferPointer { _ in
                var chatMsgs: [llama_chat_message] = []
                for i in 0..<messages.count {
                    let rolePtr = roleStrings[i].withUnsafeBufferPointer { $0.baseAddress }
                    let contentPtr = contentStrings[i].withUnsafeBufferPointer { $0.baseAddress }
                    chatMsgs.append(llama_chat_message(role: rolePtr, content: contentPtr))
                }

                var bufSize = 2048
                for _ in 0..<3 {
                    var buf = [CChar](repeating: 0, count: bufSize)
                    let written = chatMsgs.withUnsafeBufferPointer { msgsPtr -> Int32 in
                        llama_chat_apply_template(tmpl, msgsPtr.baseAddress, messages.count, true, &buf, Int32(bufSize))
                    }
                    if written < 0 { return }
                    if Int(written) <= bufSize {
                        let data = Data(bytes: buf, count: Int(written))
                        result = String(data: data, encoding: .utf8)
                        return
                    }
                    bufSize = Int(written) + 64
                }
            }
        }
        return result
    }

    // MARK: - Tool call parsing

    private func parseToolCall(from text: String) -> (name: String, args: [String: String])? {
        guard let startRange = text.range(of: "<tool_call>"),
              let endRange = text.range(of: "</tool_call>", range: startRange.upperBound..<text.endIndex) else {
            return nil
        }
        let jsonString = String(text[startRange.upperBound..<endRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["name"] as? String else {
            return nil
        }
        var args: [String: String] = [:]
        if let rawArgs = obj["args"] as? [String: Any] {
            for (k, v) in rawArgs { args[k] = stringifyArg(v) }
        } else if let rawArgs = obj["arguments"] as? [String: Any] {
            for (k, v) in rawArgs { args[k] = stringifyArg(v) }
        }
        return (name, args)
    }

    private func stringifyArg(_ v: Any) -> String {
        if let s = v as? String { return s }
        if let b = v as? Bool { return b ? "true" : "false" }
        if let n = v as? NSNumber { return n.stringValue }
        if v is NSNull { return "" }
        if let data = try? JSONSerialization.data(withJSONObject: v, options: []),
           let s = String(data: data, encoding: .utf8) { return s }
        return String(describing: v)
    }

    // MARK: - Embeddings

    func embed(text: String, dimensions: Int = 256) async -> [Double] {
        if let realVec = try? embedWithModel(text: text) {
            return realVec
        }
        return hashEmbed(text: text, dimensions: dimensions)
    }

    private func embedWithModel(text: String) throws -> [Double] {
        guard let context = embedContext, let vocab = embedVocab else {
            throw LlamaError.noModelLoaded
        }
        if let mem = llama_get_memory(context) {
            llama_memory_clear(mem, true)
        }

        let utf8Count = text.utf8.count
        let maxTok = utf8Count + 8
        var tokens = [llama_token](repeating: 0, count: maxTok)
        let n = text.withCString { cStr in
            llama_tokenize(vocab, cStr, Int32(utf8Count), &tokens, Int32(maxTok), true, true)
        }
        guard n > 0 else { throw LlamaError.tokenizationFailed }
        let inputTokens = Array(tokens.prefix(Int(n)))

        var batch = llama_batch_init(Int32(inputTokens.count), 0, 1)
        defer { llama_batch_free(batch) }
        batch.n_tokens = Int32(inputTokens.count)
        for i in 0..<inputTokens.count {
            batch.token[i] = inputTokens[i]
            batch.pos[i] = Int32(i)
            batch.n_seq_id[i] = 1
            if let seqIds = batch.seq_id, let seqId = seqIds[i] { seqId[0] = 0 }
            batch.logits[i] = 1
        }
        if llama_decode(context, batch) != 0 { throw LlamaError.decodeFailed }

        let nEmbd = Int(llama_model_n_embd(embedModel!))
        guard nEmbd > 0 else { throw LlamaError.decodeFailed }

        var embPtr = llama_get_embeddings_seq(context, 0)
        if embPtr == nil {
            embPtr = llama_get_embeddings(context)
        }
        guard let ptr = embPtr else { throw LlamaError.decodeFailed }

        var vec = [Double](repeating: 0, count: nEmbd)
        for i in 0..<nEmbd { vec[i] = Double(ptr[i]) }
        let norm = sqrt(vec.reduce(0.0) { $0 + $1 * $1 })
        if norm > 0 { for i in 0..<nEmbd { vec[i] /= norm } }
        return vec
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
}
