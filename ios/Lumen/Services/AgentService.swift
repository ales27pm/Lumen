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
}

nonisolated enum AgentEvent: Sendable {
    case step(AgentStep)
    case stepDelta(id: UUID, text: String)
    case finalDelta(String)
    case done(finalText: String, steps: [AgentStep])
    case error(String)
}

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
        var scratchpad = ""
        var finalAnswer = ""
        var observations: [(tool: String, result: String)] = []

        let sys = buildSystemPrompt(req: req)
        var history = req.history

        for stepIndex in 0..<max(1, req.maxSteps) {
            if Task.isCancelled { break }

            let userTurn: String
            if stepIndex == 0 {
                userTurn = req.userMessage
            } else {
                userTurn = req.userMessage + "\n\n" + scratchpad + "\n\nContinue. Either think/act further or give Final Answer."
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
                relevantMemories: []
            )

            var raw = ""
            var stopEmitted = false
            var currentStepID: UUID?
            var currentStepKind: AgentStep.Kind?
            var currentStepBuffer = ""
            var inFinal = false
            var finalBuffer = ""

            for await token in await LlamaService.shared.stream(genReq) {
                if Task.isCancelled { break }
                switch token {
                case .text(let s):
                    raw += s
                    // Incremental parse: look for line-oriented markers
                    let handled = processIncremental(
                        raw: &raw,
                        currentStepID: &currentStepID,
                        currentStepKind: &currentStepKind,
                        currentStepBuffer: &currentStepBuffer,
                        inFinal: &inFinal,
                        finalBuffer: &finalBuffer,
                        continuation: continuation,
                        stopEmitted: &stopEmitted
                    )
                    if handled == .shouldStop { break }
                case .toolCall:
                    continue
                case .done:
                    break
                }
                if stopEmitted { break }
            }

            // Flush any open step from buffer
            if let id = currentStepID, let kind = currentStepKind, !currentStepBuffer.isEmpty, kind != .action {
                let step = AgentStep(id: id, kind: kind, content: currentStepBuffer.trimmingCharacters(in: .whitespacesAndNewlines))
                if !steps.contains(where: { $0.id == step.id }) { steps.append(step) }
            }

            // Parse full output to determine next action
            let parsed = parseReActOutput(raw)
            for s in parsed.steps where !steps.contains(where: { $0.id == s.id || ($0.kind == s.kind && $0.content == s.content) }) {
                steps.append(s)
                continuation.yield(.step(s))
            }
            scratchpad += "\n" + raw

            if let action = parsed.action {
                // Emit the action step if not already
                let actionStep = AgentStep(kind: .action, content: "\(action.tool)(\(formatArgs(action.args)))", toolID: action.tool, toolArgs: action.args)
                steps.append(actionStep)
                continuation.yield(.step(actionStep))

                // Execute tool
                let tool = ToolRegistry.find(id: action.tool)
                let isEnabled = req.availableTools.contains { $0.id == action.tool }
                let result: String
                if tool == nil {
                    result = "Unknown tool: \(action.tool)"
                } else if !isEnabled {
                    result = "Tool \(action.tool) is disabled. Enable it in Tools."
                } else {
                    result = await ToolExecutor.shared.execute(action.tool, arguments: action.args)
                }
                let obs = AgentStep(kind: .observation, content: result, toolID: action.tool)
                steps.append(obs)
                continuation.yield(.step(obs))

                scratchpad += "\nObservation: \(result)\n"
                observations.append((action.tool, result))
                if stepIndex == req.maxSteps - 1 {
                    finalAnswer = await synthesizeFallback(req: req, userMessage: req.userMessage, observations: observations)
                    continuation.yield(.finalDelta(finalAnswer))
                }
                continue
            }

            if let final = parsed.finalAnswer {
                finalAnswer = final
                if !inFinal { continuation.yield(.finalDelta(final)) }
                break
            }

            // Neither action nor final answer — treat raw output as final
            finalAnswer = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if finalAnswer.isEmpty { finalAnswer = "(no response)" }
            if !inFinal { continuation.yield(.finalDelta(finalAnswer)) }
            break
        }

        continuation.yield(.done(finalText: finalAnswer, steps: steps))
        continuation.finish()
    }

    // MARK: - Incremental streaming parser

    private enum IncResult { case ok, shouldStop }

    private func processIncremental(
        raw: inout String,
        currentStepID: inout UUID?,
        currentStepKind: inout AgentStep.Kind?,
        currentStepBuffer: inout String,
        inFinal: inout Bool,
        finalBuffer: inout String,
        continuation: AsyncStream<AgentEvent>.Continuation,
        stopEmitted: inout Bool
    ) -> IncResult {
        // Walk new lines
        while let newlineIdx = raw.firstIndex(of: "\n") {
            let line = String(raw[..<newlineIdx])
            raw.removeSubrange(...newlineIdx)
            handleLine(line,
                       currentStepID: &currentStepID,
                       currentStepKind: &currentStepKind,
                       currentStepBuffer: &currentStepBuffer,
                       inFinal: &inFinal,
                       finalBuffer: &finalBuffer,
                       continuation: continuation,
                       stopEmitted: &stopEmitted)
            if stopEmitted { return .shouldStop }
        }
        return .ok
    }

    private func handleLine(
        _ line: String,
        currentStepID: inout UUID?,
        currentStepKind: inout AgentStep.Kind?,
        currentStepBuffer: inout String,
        inFinal: inout Bool,
        finalBuffer: inout String,
        continuation: AsyncStream<AgentEvent>.Continuation,
        stopEmitted: inout Bool
    ) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if inFinal {
            finalBuffer += line + "\n"
            continuation.yield(.finalDelta(line + "\n"))
            return
        }
        if let range = trimmed.range(of: "Final Answer:", options: .caseInsensitive), range.lowerBound == trimmed.startIndex {
            inFinal = true
            let after = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !after.isEmpty {
                finalBuffer = after + "\n"
                continuation.yield(.finalDelta(after + "\n"))
            }
            return
        }
        if matchesPrefix(trimmed, "Thought:") {
            flushStep(currentStepID: &currentStepID, currentStepKind: &currentStepKind, currentStepBuffer: &currentStepBuffer, continuation: continuation)
            let content = afterPrefix(trimmed, "Thought:")
            let step = AgentStep(kind: .thought, content: content)
            currentStepID = step.id
            currentStepKind = .thought
            currentStepBuffer = content
            continuation.yield(.step(step))
            return
        }
        if matchesPrefix(trimmed, "Action:") {
            flushStep(currentStepID: &currentStepID, currentStepKind: &currentStepKind, currentStepBuffer: &currentStepBuffer, continuation: continuation)
            // Don't stream action detail — it'll be emitted as a single step after full parse
            currentStepID = nil
            currentStepKind = .action
            currentStepBuffer = afterPrefix(trimmed, "Action:")
            stopEmitted = true
            return
        }
        if matchesPrefix(trimmed, "Reflection:") {
            flushStep(currentStepID: &currentStepID, currentStepKind: &currentStepKind, currentStepBuffer: &currentStepBuffer, continuation: continuation)
            let content = afterPrefix(trimmed, "Reflection:")
            let step = AgentStep(kind: .reflection, content: content)
            currentStepID = step.id
            currentStepKind = .reflection
            currentStepBuffer = content
            continuation.yield(.step(step))
            return
        }
        // Continuation of current step
        if let id = currentStepID, currentStepKind != nil, currentStepKind != .action {
            currentStepBuffer += " " + trimmed
            continuation.yield(.stepDelta(id: id, text: currentStepBuffer))
        }
    }

    private func flushStep(
        currentStepID: inout UUID?,
        currentStepKind: inout AgentStep.Kind?,
        currentStepBuffer: inout String,
        continuation: AsyncStream<AgentEvent>.Continuation
    ) {
        currentStepID = nil
        currentStepKind = nil
        currentStepBuffer = ""
    }

    private func matchesPrefix(_ s: String, _ p: String) -> Bool {
        s.range(of: p, options: [.caseInsensitive, .anchored]) != nil
    }

    private func afterPrefix(_ s: String, _ p: String) -> String {
        guard let r = s.range(of: p, options: [.caseInsensitive, .anchored]) else { return s }
        return String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Full parse

    private struct ParsedOutput {
        var steps: [AgentStep]
        var action: (tool: String, args: [String: String])?
        var finalAnswer: String?
    }

    private func parseReActOutput(_ text: String) -> ParsedOutput {
        var out = ParsedOutput(steps: [], action: nil, finalAnswer: nil)
        let lines = text.components(separatedBy: .newlines)
        var currentKind: AgentStep.Kind?
        var buffer: [String] = []
        var finalBuffer: [String] = []
        var collectingFinal = false
        var actionLine: String?

        func flush() {
            guard let kind = currentKind, !buffer.isEmpty else { return }
            let content = buffer.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty && kind != .action {
                out.steps.append(AgentStep(kind: kind, content: content))
            }
            buffer = []
        }

        for raw in lines {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if collectingFinal { finalBuffer.append(t); continue }
            if let r = t.range(of: "Final Answer:", options: .caseInsensitive), r.lowerBound == t.startIndex {
                flush()
                collectingFinal = true
                let rest = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { finalBuffer.append(rest) }
                continue
            }
            if matchesPrefix(t, "Thought:") { flush(); currentKind = .thought; buffer = [afterPrefix(t, "Thought:")]; continue }
            if matchesPrefix(t, "Reflection:") { flush(); currentKind = .reflection; buffer = [afterPrefix(t, "Reflection:")]; continue }
            if matchesPrefix(t, "Action:") {
                flush()
                currentKind = .action
                actionLine = afterPrefix(t, "Action:")
                continue
            }
            if matchesPrefix(t, "Observation:") { flush(); currentKind = nil; continue }
            if currentKind != nil { buffer.append(t) }
        }
        flush()

        if let a = actionLine { out.action = parseAction(a) }
        if !finalBuffer.isEmpty {
            out.finalAnswer = finalBuffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return out
    }

    private func parseAction(_ line: String) -> (tool: String, args: [String: String])? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // JSON form: {"tool":"...","args":{...}}
        if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start < end {
            let json = String(trimmed[start...end])
            if let data = json.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let name = (obj["tool"] as? String) ?? (obj["name"] as? String) ?? ""
                var args: [String: String] = [:]
                if let a = obj["args"] as? [String: Any] {
                    for (k, v) in a { args[k] = stringify(v) }
                } else if let a = obj["arguments"] as? [String: Any] {
                    for (k, v) in a { args[k] = stringify(v) }
                }
                if !name.isEmpty { return (name, args) }
            }
        }
        // Function-call form: tool.id(key="value", key2="value2")
        if let paren = trimmed.firstIndex(of: "("), let close = trimmed.lastIndex(of: ")"), paren < close {
            let name = String(trimmed[..<paren]).trimmingCharacters(in: .whitespaces)
            let argsStr = String(trimmed[trimmed.index(after: paren)..<close])
            let args = parseSimpleArgs(argsStr)
            if !name.isEmpty { return (name, args) }
        }
        // Bare tool id
        if !trimmed.isEmpty && trimmed.contains(".") && !trimmed.contains(" ") {
            return (trimmed, [:])
        }
        return nil
    }

    private func parseSimpleArgs(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        // naive split on commas not inside quotes
        var parts: [String] = []
        var buf = ""
        var inQuote = false
        for ch in s {
            if ch == "\"" { inQuote.toggle(); buf.append(ch); continue }
            if ch == "," && !inQuote { parts.append(buf); buf = ""; continue }
            buf.append(ch)
        }
        if !buf.isEmpty { parts.append(buf) }
        for p in parts {
            let kv = p.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2 {
                var v = kv[1]
                if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 {
                    v = String(v.dropFirst().dropLast())
                }
                out[kv[0]] = v
            }
        }
        return out
    }

    private func stringify(_ v: Any) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return String(describing: v)
    }

    private func formatArgs(_ args: [String: String]) -> String {
        args.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
    }

    // MARK: - System prompt

    private func buildSystemPrompt(req: AgentRequest) -> String {
        var sys = req.systemPrompt
        sys += "\n\nYou are an autonomous agent. Answer using the ReAct pattern. Emit EXACTLY one of:\n"
        sys += "- A block starting with `Thought:` followed by your reasoning, then on a new line `Action:` with a tool call.\n"
        sys += "- Or `Final Answer:` followed by your reply to the user.\n\n"
        sys += "Action format (JSON on one line):\nAction: {\"tool\":\"tool.id\",\"args\":{\"key\":\"value\"}}\n\n"
        sys += "After each Action, you'll receive an `Observation:` — then think again or produce Final Answer. Never invent observations.\n\n"

        if !req.availableTools.isEmpty {
            sys += "Available tools:\n"
            for t in req.availableTools {
                sys += "- \(t.id): \(t.description)\n"
            }
            sys += "\n"
        } else {
            sys += "No tools available. Answer directly with Final Answer.\n\n"
        }

        if !req.relevantMemories.isEmpty {
            sys += "Relevant memories about this user:\n"
            for m in req.relevantMemories.prefix(6) { sys += "- \(m)\n" }
            sys += "\n"
        }

        sys += "Guidelines:\n"
        sys += "- If the user asks about something \"nearest\", \"near me\", or \"closest\", call `location.current` FIRST, then `maps.search` ONCE with the user's location, then give Final Answer.\n"
        sys += "- Do NOT repeat the same tool call with the same arguments. Don't loop.\n"
        sys += "- As soon as you have enough information to answer, stop and produce Final Answer. Do not call extra tools for confirmation.\n"
        sys += "- If a tool returns results that partially answer the question, summarize them in Final Answer rather than searching again.\n"
        sys += "- If the user's message doesn't need a tool, skip straight to Final Answer.\n"
        sys += "Be concise."
        return sys
    }

    private func synthesizeFallback(req: AgentRequest, userMessage: String, observations: [(tool: String, result: String)]) async -> String {
        guard !observations.isEmpty else {
            return "I couldn't find a confident answer to that. Try rephrasing the question."
        }
        var prompt = "The user asked: \"\(userMessage)\"\n\nYou gathered these tool observations:\n"
        for (i, obs) in observations.enumerated() {
            prompt += "\n[\(i + 1)] \(obs.tool):\n\(obs.result)\n"
        }
        prompt += "\nWrite ONE short, direct, helpful answer to the user in plain language based only on these observations. No preamble, no 'Final Answer:' prefix, no apology about limits. If observations conflict, prefer the most recent one."

        let genReq = GenerateRequest(
            systemPrompt: "You summarize tool results into a concise user-facing answer.",
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
            if case .text(let s) = token { out += s }
            if case .done = token { break }
        }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let last = observations.last!.result
            return last
        }
        return trimmed
    }
}
