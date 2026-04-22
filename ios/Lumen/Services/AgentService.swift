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
    let parseError: AgentTurnParseError?

    var isStructured: Bool { action != nil || (final?.isEmpty == false) }
}

nonisolated enum AgentTurnParseError: String, Error, Sendable {
    case empty
    case noJSONObject
    case multipleJSONObjects
    case noisyOutput
    case malformedEscapeSequence
    case incompleteJSON
    case invalidJSONObject
    case invalidThoughtType
    case invalidFinalType
    case mixedTurn
    case mixedActionShapes
    case missingActionOrFinal
    case missingActionTool
    case invalidActionType
    case invalidActionArgsType
}

nonisolated enum AgentTurnParser {
    static func parse(_ raw: String) -> AgentTurn {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return AgentTurn(thought: nil, action: nil, final: nil, parseError: .empty)
        }

        switch extractSingleJSONObject(from: trimmed) {
        case .success(let obj):
            return buildTurn(from: obj)
        case .failure(let error):
            return AgentTurn(thought: nil, action: nil, final: nil, parseError: error)
        }
    }

    private static func buildTurn(from obj: [String: Any]) -> AgentTurn {
        if let value = obj["thought"], !(value is String) { return invalid(.invalidThoughtType) }
        if let value = obj["reasoning"], !(value is String) { return invalid(.invalidThoughtType) }
        if let value = obj["final"], !(value is String) { return invalid(.invalidFinalType) }
        if let value = obj["final_answer"], !(value is String) { return invalid(.invalidFinalType) }
        if let value = obj["answer"], !(value is String) { return invalid(.invalidFinalType) }

        let thoughtRaw = (obj["thought"] as? String) ?? (obj["reasoning"] as? String)
        let thought = thoughtRaw?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanThought = (thought?.isEmpty ?? true) ? nil : thought

        var action: AgentAction?
        let hasNestedAction = obj["action"] != nil
        let hasFlatAction = obj["tool"] != nil || obj["args"] != nil || obj["arguments"] != nil || obj["input"] != nil
        if hasNestedAction && hasFlatAction {
            return invalid(.mixedActionShapes)
        }

        if hasNestedAction {
            guard let act = obj["action"] as? [String: Any] else { return invalid(.invalidActionType) }
            switch parseAction(from: act) {
            case .success(let parsedAction):
                action = parsedAction
            case .failure(let error):
                return invalid(error)
            }
        } else if hasFlatAction {
            switch parseFlatAction(from: obj) {
            case .success(let parsedAction):
                action = parsedAction
            case .failure(let error):
                return invalid(error)
            }
        }

        let finalRaw = (obj["final"] as? String)
            ?? (obj["final_answer"] as? String)
            ?? (obj["answer"] as? String)
        let finalTrimmed = finalRaw?.trimmingCharacters(in: .whitespacesAndNewlines)

        let hasFinal = !(finalTrimmed?.isEmpty ?? true)
        let hasAction = action != nil
        if hasAction && hasFinal { return invalid(.mixedTurn) }
        if !hasAction && !hasFinal { return invalid(.missingActionOrFinal) }

        return AgentTurn(
            thought: cleanThought,
            action: action,
            final: hasFinal ? finalTrimmed : nil,
            parseError: nil
        )
    }

    private static func parseAction(from act: [String: Any]) -> Result<AgentAction, AgentTurnParseError> {
        let name = (act["tool"] as? String) ?? (act["name"] as? String) ?? (act["id"] as? String) ?? ""
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.missingActionTool) }
        guard let args = parseArgs(from: act) else { return .failure(.invalidActionArgsType) }
        return .success(AgentAction(tool: trimmed, args: args))
    }

    private static func parseFlatAction(from obj: [String: Any]) -> Result<AgentAction, AgentTurnParseError> {
        guard let toolName = obj["tool"] as? String else { return .failure(.missingActionTool) }
        let trimmed = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.missingActionTool) }
        guard let args = parseArgs(from: obj) else { return .failure(.invalidActionArgsType) }
        return .success(AgentAction(tool: trimmed, args: args))
    }

    private static func parseArgs(from obj: [String: Any]) -> [String: String]? {
        let argsValue = obj["args"] ?? obj["arguments"] ?? obj["input"]
        guard let argsValue else { return [:] }
        guard let rawArgs = argsValue as? [String: Any] else { return nil }
        var args: [String: String] = [:]
        for (k, v) in rawArgs {
            guard let s = v as? String else { return nil }
            args[k] = s
        }
        return args
    }

    private static func extractSingleJSONObject(from text: String) -> Result<[String: Any], AgentTurnParseError> {
        let chars = Array(text)
        var ranges: [(Int, Int)] = []
        var depth = 0
        var start: Int?
        var inString = false
        var escape = false
        var i = 0

        while i < chars.count {
            let ch = chars[i]
            if inString {
                if escape {
                    if !isValidEscape(at: i, in: chars) {
                        return .failure(.malformedEscapeSequence)
                    }
                    if ch == "u" { i += 4 }
                    escape = false
                } else if ch == "\\" {
                    escape = true
                } else if ch == "\"" {
                    inString = false
                }
                i += 1
                continue
            }

            if ch == "\"" {
                inString = true
            } else if ch == "{" {
                if depth == 0 { start = i }
                depth += 1
            } else if ch == "}" {
                guard depth > 0 else { return .failure(.invalidJSONObject) }
                depth -= 1
                if depth == 0, let s = start {
                    ranges.append((s, i))
                    start = nil
                }
            }
            i += 1
        }

        if inString || depth != 0 { return .failure(.incompleteJSON) }
        guard !ranges.isEmpty else { return .failure(.noJSONObject) }
        guard ranges.count == 1 else { return .failure(.multipleJSONObjects) }

        let onlyRange = ranges[0]
        let leading = String(chars[0..<onlyRange.0]).trimmingCharacters(in: .whitespacesAndNewlines)
        let trailing = String(chars[(onlyRange.1 + 1)..<chars.count]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !leading.isEmpty || !trailing.isEmpty { return .failure(.noisyOutput) }

        let jsonStr = String(chars[onlyRange.0...onlyRange.1])
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.invalidJSONObject)
        }
        return .success(obj)
    }

    private static func isValidEscape(at index: Int, in chars: [Character]) -> Bool {
        let esc = chars[index]
        switch esc {
        case "\"", "\\", "/", "b", "f", "n", "r", "t":
            return true
        case "u":
            guard index + 4 < chars.count else { return false }
            for j in (index + 1)...(index + 4) {
                if chars[j].hexDigitValue == nil { return false }
            }
            return true
        default:
            return false
        }
    }

    private static func invalid(_ error: AgentTurnParseError) -> AgentTurn {
        AgentTurn(thought: nil, action: nil, final: nil, parseError: error)
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
            if let parseError = turn.parseError {
                let reflection = AgentStep(kind: .reflection, content: "Model produced invalid structured output (\(parseError.rawValue)); synthesizing a safe final answer.")
                steps.append(reflection)
                continuation.yield(.step(reflection))

                if !observations.isEmpty {
                    finalAnswer = await synthesizeFallback(req: req, observations: observations, reason: .malformed)
                } else {
                    finalAnswer = "I couldn't parse a valid structured turn. Please try again."
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
