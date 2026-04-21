import Foundation
import SwiftData

nonisolated struct AgentRequest: Sendable {
    let systemPrompt: String
    let history: [(role: MessageRole, content: String)]
    let userMessage: String
    let temperature: Double
    let topP: Double
    let repetitionPenalty: Double
    let maxTokens: Int
    let maxSteps: Int
    let availableTools: [ToolDefinition]
    let relevantMemories: [String]
    let attachments: [ChatAttachment]

    init(
        systemPrompt: String,
        history: [(role: MessageRole, content: String)],
        userMessage: String,
        temperature: Double,
        topP: Double,
        repetitionPenalty: Double,
        maxTokens: Int,
        maxSteps: Int,
        availableTools: [ToolDefinition],
        relevantMemories: [String],
        attachments: [ChatAttachment] = []
    ) {
        self.systemPrompt = systemPrompt
        self.history = history
        self.userMessage = userMessage
        self.temperature = temperature
        self.topP = topP
        self.repetitionPenalty = repetitionPenalty
        self.maxTokens = maxTokens
        self.maxSteps = maxSteps
        self.availableTools = availableTools
        self.relevantMemories = relevantMemories
        self.attachments = attachments
    }
}

nonisolated enum AgentEvent: Sendable {
    case step(AgentStep)
    case stepDelta(id: UUID, text: String)
    case finalDelta(String)
    case done(finalText: String, steps: [AgentStep])
    case error(String)
}

// MARK: - Structured turn model

nonisolated struct AgentAction: Sendable, Hashable {
    let tool: String
    let args: [String: String]

    var dedupeKey: String {
        let argsStr = args.keys.sorted()
            .map { "\($0)=\(args[$0] ?? "")" }
            .joined(separator: "&")
        return tool + "|" + argsStr
    }

    var displayContent: String {
        if args.isEmpty { return "\(tool)()" }
        let argsStr = args.keys.sorted()
            .map { "\($0)=\(args[$0] ?? "")" }
            .joined(separator: ", ")
        return "\(tool)(\(argsStr))"
    }
}

nonisolated struct AgentTurn: Sendable {
    let thought: String?
    let action: AgentAction?
    let final: String?
    /// When structured parsing fails, the best-effort plaintext that should be shown as the final answer.
    let rawFallback: String?

    var isStructured: Bool { action != nil || (final?.isEmpty == false) }
}

nonisolated enum AgentTurnParser {
    static func parse(_ raw: String) -> AgentTurn {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return AgentTurn(thought: nil, action: nil, final: nil, rawFallback: nil)
        }
        if let obj = extractJSONObject(from: trimmed) {
            return buildTurn(from: obj, raw: trimmed)
        }
        return AgentTurn(thought: nil, action: nil, final: nil, rawFallback: trimmed)
    }

    private static func buildTurn(from obj: [String: Any], raw: String) -> AgentTurn {
        let thoughtRaw = (obj["thought"] as? String) ?? (obj["reasoning"] as? String)
        let thought = thoughtRaw?.trimmingCharacters(in: .whitespacesAndNewlines)

        var action: AgentAction?
        if let act = obj["action"] as? [String: Any] {
            let name = (act["tool"] as? String) ?? (act["name"] as? String) ?? (act["id"] as? String) ?? ""
            var args: [String: String] = [:]
            let rawArgs = (act["args"] as? [String: Any]) ?? (act["arguments"] as? [String: Any]) ?? (act["input"] as? [String: Any]) ?? [:]
            for (k, v) in rawArgs { args[k] = stringify(v) }
            if !name.isEmpty {
                action = AgentAction(tool: name.trimmingCharacters(in: .whitespaces), args: args)
            }
        } else if let toolName = obj["tool"] as? String {
            // Tolerate flat shape: {"tool": "...", "args": {...}}
            var args: [String: String] = [:]
            let rawArgs = (obj["args"] as? [String: Any]) ?? (obj["arguments"] as? [String: Any]) ?? [:]
            for (k, v) in rawArgs { args[k] = stringify(v) }
            if !toolName.isEmpty {
                action = AgentAction(tool: toolName.trimmingCharacters(in: .whitespaces), args: args)
            }
        }

        let finalRaw = (obj["final"] as? String)
            ?? (obj["final_answer"] as? String)
            ?? (obj["answer"] as? String)
        let finalTrimmed = finalRaw?.trimmingCharacters(in: .whitespacesAndNewlines)

        let hasFinal = !(finalTrimmed?.isEmpty ?? true)
        let hasAction = action != nil
        let cleanThought = (thought?.isEmpty ?? true) ? nil : thought

        if !hasAction && !hasFinal {
            // Degenerate — treat thought (or raw) as final.
            let fallback = cleanThought ?? raw
            return AgentTurn(thought: cleanThought, action: nil, final: nil, rawFallback: fallback)
        }

        return AgentTurn(
            thought: cleanThought,
            action: action,
            final: hasFinal ? finalTrimmed : nil,
            rawFallback: nil
        )
    }

    private static func extractJSONObject(from text: String) -> [String: Any]? {
        if let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        // Locate the first balanced top-level JSON object in the text.
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i] == "{" {
                if let end = findMatchingBrace(chars: chars, start: i) {
                    let jsonStr = String(chars[i...end])
                    if let data = jsonStr.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        return obj
                    }
                }
            }
            i += 1
        }
        return nil
    }

    private static func findMatchingBrace(chars: [Character], start: Int) -> Int? {
        var depth = 0
        var inString = false
        var escape = false
        var i = start
        while i < chars.count {
            let ch = chars[i]
            if escape { escape = false; i += 1; continue }
            if inString {
                if ch == "\\" { escape = true }
                else if ch == "\"" { inString = false }
            } else {
                if ch == "\"" { inString = true }
                else if ch == "{" { depth += 1 }
                else if ch == "}" {
                    depth -= 1
                    if depth == 0 { return i }
                }
            }
            i += 1
        }
        return nil
    }

    static func stringify(_ v: Any) -> String {
        if let s = v as? String { return s }
        if let b = v as? Bool { return b ? "true" : "false" }
        if let n = v as? NSNumber { return n.stringValue }
        if v is NSNull { return "" }
        if let data = try? JSONSerialization.data(withJSONObject: v, options: []),
           let s = String(data: data, encoding: .utf8) { return s }
        return String(describing: v)
    }
}

// MARK: - Streaming JSON string extractor

/// Extracts the (possibly partial) string value of specific JSON keys from a growing buffer.
/// Safe on truncated input — returns what has been decoded so far and whether the string is closed.
final class StreamingJSONScanner {
    private var buffer = ""
    private(set) var thought: String = ""
    private(set) var final: String = ""
    private var thoughtDone = false
    private var finalDone = false

    enum Event {
        case thoughtDelta(String)
        case finalDelta(String)
    }

    func feed(_ chunk: String) -> [Event] {
        buffer += chunk
        var events: [Event] = []

        if !thoughtDone, let (value, done) = extractString(key: "thought") {
            if value.count > thought.count {
                let delta = String(value.suffix(value.count - thought.count))
                events.append(.thoughtDelta(delta))
                thought = value
            }
            thoughtDone = done
        }
        if !finalDone, let (value, done) = extractString(key: "final") {
            if value.count > final.count {
                let delta = String(value.suffix(value.count - final.count))
                events.append(.finalDelta(delta))
                final = value
            }
            finalDone = done
        }
        return events
    }

    private func extractString(key: String) -> (String, Bool)? {
        let pattern = "\"\(key)\""
        guard let keyRange = buffer.range(of: pattern) else { return nil }
        var i = keyRange.upperBound
        while i < buffer.endIndex, buffer[i].isWhitespace { i = buffer.index(after: i) }
        guard i < buffer.endIndex, buffer[i] == ":" else { return nil }
        i = buffer.index(after: i)
        while i < buffer.endIndex, buffer[i].isWhitespace { i = buffer.index(after: i) }
        guard i < buffer.endIndex, buffer[i] == "\"" else { return nil }
        i = buffer.index(after: i)

        var result = ""
        var done = false
        while i < buffer.endIndex {
            let ch = buffer[i]
            if ch == "\\" {
                let next = buffer.index(after: i)
                guard next < buffer.endIndex else { break }
                let escCh = buffer[next]
                switch escCh {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "/": result.append("/")
                case "b": result.append("\u{08}")
                case "f": result.append("\u{0C}")
                case "u":
                    let h1 = buffer.index(after: next)
                    guard let h4 = buffer.index(h1, offsetBy: 4, limitedBy: buffer.endIndex) else { return (result, false) }
                    let hex = String(buffer[h1..<h4])
                    if let scalar = UInt32(hex, radix: 16), let u = Unicode.Scalar(scalar) {
                        result.append(Character(u))
                    }
                    i = h4
                    continue
                default:
                    result.append(escCh)
                }
                i = buffer.index(after: next)
            } else if ch == "\"" {
                done = true
                break
            } else {
                result.append(ch)
                i = buffer.index(after: i)
            }
        }
        return (result, done)
    }
}

// MARK: - AgentService

@MainActor
final class AgentService {
    static let shared = AgentService()

    func run(_ req: AgentRequest) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            let task = Task { await self.runLoop(req, continuation: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runLoop(_ req: AgentRequest, continuation: AsyncStream<AgentEvent>.Continuation) async {
        var steps: [AgentStep] = []
        var observations: [(tool: String, result: String)] = []
        var executedActionKeys: Set<String> = []
        var scratchpad = ""
        var finalAnswer = ""

        let sys = buildSystemPrompt(req: req)
        let history = req.history
        let maxSteps = max(1, req.maxSteps)

        stepsLoop: for stepIndex in 0..<maxSteps {
            if Task.isCancelled { break }

            let userTurn: String
            if stepIndex == 0 {
                userTurn = req.userMessage
            } else {
                userTurn = req.userMessage
                    + "\n\nPrior turns:\n" + scratchpad
                    + "\n\nEmit the next JSON turn now. Either an action or a final."
            }

            let genReq = GenerateRequest(
                systemPrompt: sys,
                history: history,
                userMessage: userTurn,
                temperature: req.temperature,
                topP: req.topP,
                repetitionPenalty: req.repetitionPenalty,
                maxTokens: req.maxTokens,
                modelName: "agent",
                availableTools: [],
                relevantMemories: [],
                attachments: stepIndex == 0 ? req.attachments : []
            )

            let scanner = StreamingJSONScanner()
            var raw = ""
            let thoughtStepID = UUID()
            var thoughtStepYielded = false
            var streamedFinalLen = 0

            for await token in await LlamaService.shared.stream(genReq) {
                if Task.isCancelled { break }
                switch token {
                case .text(let s):
                    raw += s
                    for event in scanner.feed(s) {
                        switch event {
                        case .thoughtDelta:
                            let current = scanner.thought
                            if !thoughtStepYielded {
                                continuation.yield(.step(AgentStep(id: thoughtStepID, kind: .thought, content: current)))
                                thoughtStepYielded = true
                            } else {
                                continuation.yield(.stepDelta(id: thoughtStepID, text: current))
                            }
                        case .finalDelta(let delta):
                            streamedFinalLen += delta.count
                            continuation.yield(.finalDelta(delta))
                        }
                    }
                case .toolCall:
                    continue
                case .done:
                    break
                }
            }

            if Task.isCancelled { break }

            let turn = AgentTurnParser.parse(raw)

            // Commit thought step with the fully-parsed value (in case streaming extracted less).
            if let thought = turn.thought, !thought.isEmpty {
                let step = AgentStep(id: thoughtStepID, kind: .thought, content: thought)
                if let idx = steps.firstIndex(where: { $0.id == thoughtStepID }) {
                    steps[idx] = step
                } else {
                    steps.append(step)
                }
                if thoughtStepYielded {
                    continuation.yield(.stepDelta(id: thoughtStepID, text: thought))
                } else {
                    continuation.yield(.step(step))
                }
                scratchpad += "\nThought: \(thought)"
            } else if thoughtStepYielded, !scanner.thought.isEmpty {
                // Parser lost the thought but we streamed one — keep what we streamed.
                let partial = scanner.thought
                let step = AgentStep(id: thoughtStepID, kind: .thought, content: partial)
                steps.append(step)
                scratchpad += "\nThought: \(partial)"
            }

            // Action path
            if let action = turn.action {
                guard let _ = ToolRegistry.find(id: action.tool) else {
                    let obs = AgentStep(kind: .observation, content: "Unknown tool: \(action.tool). Emit a final turn instead.", toolID: action.tool)
                    steps.append(obs)
                    continuation.yield(.step(obs))
                    observations.append((action.tool, obs.content))
                    scratchpad += "\nAction: \(action.displayContent)\nObservation: \(obs.content)"
                    continue
                }
                if executedActionKeys.contains(action.dedupeKey) {
                    let reflection = AgentStep(kind: .reflection, content: "Duplicate tool call blocked: \(action.displayContent). Synthesizing answer from observations.")
                    steps.append(reflection)
                    continuation.yield(.step(reflection))
                    finalAnswer = await synthesizeFallback(req: req, observations: observations, reason: .duplicate)
                    continuation.yield(.finalDelta(finalAnswer))
                    break stepsLoop
                }
                executedActionKeys.insert(action.dedupeKey)

                let actionStep = AgentStep(kind: .action, content: action.displayContent, toolID: action.tool, toolArgs: action.args)
                steps.append(actionStep)
                continuation.yield(.step(actionStep))

                let isEnabled = req.availableTools.contains { $0.id == action.tool }
                let result: String
                if !isEnabled {
                    result = "Tool \(action.tool) is disabled. Enable it in Tools."
                } else {
                    result = await ToolExecutor.shared.execute(action.tool, arguments: action.args)
                }

                let obs = AgentStep(kind: .observation, content: result, toolID: action.tool)
                steps.append(obs)
                continuation.yield(.step(obs))
                observations.append((action.tool, result))
                scratchpad += "\nAction: \(action.displayContent)\nObservation: \(result)"

                if stepIndex == maxSteps - 1 {
                    finalAnswer = await synthesizeFallback(req: req, observations: observations, reason: .maxSteps)
                    continuation.yield(.finalDelta(finalAnswer))
                    break stepsLoop
                }
                continue
            }

            // Final path
            if let final = turn.final, !final.isEmpty {
                finalAnswer = final
                if streamedFinalLen == 0 {
                    continuation.yield(.finalDelta(final))
                } else if streamedFinalLen < final.count {
                    // Catch up any characters the streaming scanner missed (e.g. after escape).
                    let tail = String(final.suffix(final.count - streamedFinalLen))
                    if !tail.isEmpty { continuation.yield(.finalDelta(tail)) }
                }
                break stepsLoop
            }

            // Malformed / empty output — safe degrade.
            if let fallback = turn.rawFallback, !fallback.isEmpty {
                let reflection = AgentStep(kind: .reflection, content: "Model produced unstructured output; using it as the answer.")
                steps.append(reflection)
                continuation.yield(.step(reflection))

                if !observations.isEmpty {
                    finalAnswer = await synthesizeFallback(req: req, observations: observations, reason: .malformed)
                } else {
                    finalAnswer = fallback
                }
                if streamedFinalLen == 0 {
                    continuation.yield(.finalDelta(finalAnswer))
                }
                break stepsLoop
            }

            // Nothing at all.
            finalAnswer = observations.isEmpty
                ? "I couldn't produce a response. Try rephrasing."
                : await synthesizeFallback(req: req, observations: observations, reason: .empty)
            continuation.yield(.finalDelta(finalAnswer))
            break
        }

        if Task.isCancelled {
            continuation.finish()
            return
        }

        continuation.yield(.done(finalText: finalAnswer, steps: steps))
        continuation.finish()
    }

    // MARK: - System prompt

    private func buildSystemPrompt(req: AgentRequest) -> String {
        var sys = req.systemPrompt
        sys += "\n\nYou are a structured-output agent. Each turn you MUST emit exactly one JSON object and nothing else — no prose, no markdown, no code fences, no commentary before or after.\n\n"
        sys += "Schema (choose exactly one of `action` or `final` per turn):\n"
        sys += "  {\"thought\":\"short reasoning\",\"action\":{\"tool\":\"tool.id\",\"args\":{\"key\":\"value\"}}}\n"
        sys += "  {\"thought\":\"short reasoning\",\"final\":\"your answer to the user\"}\n\n"
        sys += "Hard rules:\n"
        sys += "- Emit one valid JSON object per turn. No text outside the JSON.\n"
        sys += "- `args` values must be strings. Use {} if the tool takes no arguments.\n"
        sys += "- Never repeat an action with the same arguments. Never invent observations.\n"
        sys += "- After each `action`, you receive an Observation. Then emit the next JSON turn.\n"
        sys += "- As soon as you can answer, emit `final` and stop.\n"
        sys += "- If the user's message needs no tool, emit `final` immediately.\n\n"
        if !req.availableTools.isEmpty {
            sys += "Available tools:\n"
            for t in req.availableTools { sys += "- \(t.id): \(t.description)\n" }
            sys += "\n"
        } else {
            sys += "No tools available. You must emit a `final` turn.\n\n"
        }
        if !req.attachments.isEmpty {
            sys += "The user has attached \(req.attachments.count) file(s) to this message. Their contents are appended below as authoritative context. Do NOT call files.read for them — they are already visible. Answer directly from the attached content when possible.\n\n"
        }
        if !req.relevantMemories.isEmpty {
            sys += "Relevant memories about this user:\n"
            for m in req.relevantMemories.prefix(6) { sys += "- \(m)\n" }
            sys += "\n"
        }
        sys += "Guidelines:\n"
        sys += "- For \"nearest\"/\"near me\"/\"closest\" questions, call `location.current` first, then `maps.search` once, then emit `final`.\n"
        sys += "- If a tool result partially answers the question, summarize it in `final` rather than calling more tools.\n"
        sys += "- Keep `thought` and `final` concise and in plain language."
        return sys
    }

    // MARK: - Fallback synthesis

    private enum FallbackReason {
        case duplicate, maxSteps, malformed, empty

        var hint: String {
            switch self {
            case .duplicate: return "You already called that tool with these arguments — summarize the existing observations."
            case .maxSteps: return "You've reached the maximum number of reasoning steps — give the best answer now."
            case .malformed: return "Prior output was not valid structured JSON — summarize the observations cleanly."
            case .empty: return "Summarize the observations into a direct answer."
            }
        }
    }

    private func synthesizeFallback(req: AgentRequest, observations: [(tool: String, result: String)], reason: FallbackReason) async -> String {
        guard !observations.isEmpty else {
            return "I couldn't find a confident answer. Try rephrasing the question."
        }
        var prompt = "The user asked: \"\(req.userMessage)\"\n\nYou gathered these tool observations:\n"
        for (i, obs) in observations.enumerated() {
            prompt += "\n[\(i + 1)] \(obs.tool):\n\(obs.result)\n"
        }
        prompt += "\n\(reason.hint)\n"
        prompt += "Write ONE short, direct, helpful answer in plain language based only on these observations. No preamble, no JSON, no prefixes, no apology. If observations conflict, prefer the most recent."

        let genReq = GenerateRequest(
            systemPrompt: "You summarize tool results into a concise user-facing answer. Output plain text only.",
            history: [],
            userMessage: prompt,
            temperature: 0.3,
            topP: req.topP,
            repetitionPenalty: req.repetitionPenalty,
            maxTokens: 256,
            modelName: "agent",
            availableTools: [],
            relevantMemories: []
        )
        var out = ""
        for await token in await LlamaService.shared.stream(genReq) {
            if Task.isCancelled { break }
            if case .text(let s) = token { out += s }
            if case .done = token { break }
        }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return observations.last?.result ?? "I couldn't produce a confident answer."
        }
        return trimmed
    }
}
