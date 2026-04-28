import Foundation

@MainActor
final class SlotAgentService {
    static let shared = SlotAgentService()

    private init() {}

    func run(_ req: AgentRequest) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                var steps: [AgentStep] = []
                var observations: [String] = []
                var finalText = ""

                let routing = IntentRouter.classify(req.userMessage)
                let scopedTools = req.availableTools.filter { IntentRouter.isToolAllowed($0.id, for: routing) }

                if routing.requiresClarification {
                    let clarification = routing.clarificationPrompt ?? "Could you clarify what you want me to do?"
                    yieldFinal(clarification, steps: steps, continuation: continuation)
                    return
                }

                if IntentRouter.intentRequiresTool(routing) && scopedTools.isEmpty {
                    let unavailable = IntentRouter.unavailableMessage(for: routing)
                    yieldFinal(unavailable, steps: steps, continuation: continuation)
                    return
                }

                let maxSteps = max(1, req.maxSteps)
                for stepIndex in 0..<maxSteps {
                    let slot: LumenModelSlot = stepIndex == 0 ? .cortex : .executor
                    let turnPrompt = makeStructuredTurnPrompt(req: req, observations: observations, stepIndex: stepIndex, scopedTools: scopedTools)
                    let turnOutput = await generateText(
                        slot: slot,
                        req: req,
                        userMessage: turnPrompt,
                        temperature: stepIndex == 0 ? 0.15 : 0.0,
                        topP: stepIndex == 0 ? 0.85 : 0.1,
                        maxTokens: min(req.maxTokens, stepIndex == 0 ? 320 : 220),
                        modelName: stepIndex == 0 ? "cortex-json" : "executor-json"
                    )

                    let parsed = AgentTurnParser.parse(turnOutput)
                    if let error = parsed.parseError {
                        recordTrace(slot: slot, stage: "structured-turn", stepIndex: stepIndex, error: error.rawValue, raw: turnOutput, prompt: req.userMessage)
                    }

                    if let thought = parsed.thought, !thought.isEmpty {
                        let thoughtStep = AgentStep(kind: .thought, content: thought, toolID: nil, toolArgs: nil)
                        steps.append(thoughtStep)
                        continuation.yield(.step(thoughtStep))
                    }

                    if let final = parsed.final, !final.isEmpty {
                        finalText = await generateFinal(req: req, routing: routing, observations: observations, draft: final)
                        yieldFinal(finalText, steps: steps, continuation: continuation)
                        return
                    }

                    guard let action = parsed.action else {
                        let repairStep = AgentStep(
                            kind: .reflection,
                            content: "Structured turn failed: \(parsed.parseError?.rawValue ?? "unknown"). Falling back to Mouth.",
                            toolID: nil,
                            toolArgs: nil
                        )
                        steps.append(repairStep)
                        continuation.yield(.step(repairStep))
                        finalText = await generateFinal(req: req, routing: routing, observations: observations, draft: turnOutput)
                        yieldFinal(finalText, steps: steps, continuation: continuation)
                        return
                    }

                    let actionStep = AgentStep(kind: .action, content: action.displayContent, toolID: action.tool, toolArgs: action.args.stringCoerced)
                    steps.append(actionStep)
                    continuation.yield(.step(actionStep))

                    guard SlotAgentService.isActionAllowed(action.tool, routing: routing) else {
                        recordTrace(slot: slot, stage: "tool-execution", stepIndex: stepIndex, error: "tool_not_allowed_for_intent", raw: action.displayContent, prompt: req.userMessage)
                        finalText = IntentRouter.blockedToolMessage(for: routing)
                        yieldFinal(finalText, steps: steps, continuation: continuation)
                        return
                    }

                    let observation = await ToolExecutor.shared.execute(action.tool, arguments: action.args)
                    observations.append("\(action.tool): \(observation)")
                    let observationStep = AgentStep(kind: .observation, content: observation, toolID: action.tool, toolArgs: action.args.stringCoerced)
                    steps.append(observationStep)
                    continuation.yield(.step(observationStep))
                }

                finalText = await generateFinal(req: req, routing: routing, observations: observations, draft: nil)
                yieldFinal(finalText, steps: steps, continuation: continuation)
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private func generateFinal(req: AgentRequest, routing: IntentRoutingDecision, observations: [String], draft: String?) async -> String {
        let prompt = makeMouthPrompt(req: req, observations: observations, draft: draft)
        let text = await generateText(
            slot: .mouth,
            req: req,
            userMessage: prompt,
            temperature: req.temperature,
            topP: req.topP,
            maxTokens: req.maxTokens,
            modelName: "mouth-final"
        )

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String
        if trimmed.isEmpty, let draft, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidate = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            candidate = trimmed
        }
        return FinalIntentValidator.validate(candidate, routing: routing, fallback: observations.last ?? draft)
    }

    private func generateText(
        slot: LumenModelSlot,
        req: AgentRequest,
        userMessage: String,
        temperature: Double,
        topP: Double,
        maxTokens: Int,
        modelName: String
    ) async -> String {
        await AppLlamaService.shared.resetKVCache(for: slot)

        let generation = GenerateRequest(
            systemPrompt: req.systemPrompt,
            history: [],
            userMessage: userMessage,
            temperature: temperature,
            topP: topP,
            repetitionPenalty: req.repetitionPenalty,
            maxTokens: max(1, maxTokens),
            modelName: modelName,
            relevantMemories: req.relevantMemories,
            attachments: req.attachments
        )

        var output = ""
        let stream = await AppLlamaService.shared.stream(generation, slot: slot)
        for await token in stream {
            switch token {
            case .text(let text):
                output += text
            case .done:
                break
            }
        }
        if output.lowercased().contains("generation error:") {
            recordTrace(slot: slot, stage: modelName, stepIndex: -1, error: "generation_error", raw: output, prompt: userMessage)
        }
        return output
    }

    private func makeStructuredTurnPrompt(req: AgentRequest, observations: [String], stepIndex: Int, scopedTools: [ToolDefinition]) -> String {
        let tools = scopedTools.map { tool in "- \(tool.id): \(tool.description)" }.joined(separator: "\n")
        let observationBlock = observations.isEmpty ? "none" : observations.joined(separator: "\n")

        return """
        You are running Lumen v1 step \(stepIndex + 1). Return exactly one JSON object and no markdown.

        User request:
        \(req.userMessage)

        Previous observations for this request only:
        \(observationBlock)

        Available tools:
        \(tools)

        Output schema for using a tool:
        {"thought":"short private routing note","action":{"tool":"tool.id","args":{"key":"value"}}}

        Output schema for final answer:
        {"thought":"short private routing note","final":"answer shown to the user"}

        Rules:
        - Use only information from this prompt and this request's observations.
        - Never reuse a previous request's tool result.
        - Use a tool only when live device data or an action is needed.
        - If enough information is available, return final.
        - You may only call one of the listed tools. If no listed tool fits, return final asking for clarification or explaining the limitation.
        - Do not include prose outside JSON.
        """
    }

    private func makeMouthPrompt(req: AgentRequest, observations: [String], draft: String?) -> String {
        let observationBlock = observations.isEmpty ? "none" : observations.joined(separator: "\n")
        let draftBlock = draft?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? draft! : "none"
        return """
        Write the final user-facing answer for the current user request only. Do not output JSON.

        Current user request:
        \(req.userMessage)

        Current request tool observations:
        \(observationBlock)

        Draft final from the current request:
        \(draftBlock)

        Rules:
        - Never reuse a result from a previous user request.
        - Do not mention calendar, events, reminders, weather, email, or web search unless it belongs to this current request.
        - Keep it concise, accurate, and do not claim actions that did not happen.
        """
    }

    nonisolated static func isActionAllowed(_ toolID: String, routing: IntentRoutingDecision) -> Bool {
        IntentRouter.isToolAllowed(toolID, for: routing)
    }

    private func yieldFinal(_ text: String, steps: [AgentStep], continuation: AsyncStream<AgentEvent>.Continuation) {
        for chunk in chunk(text) {
            continuation.yield(.finalDelta(chunk))
        }
        continuation.yield(.done(finalText: text, steps: steps))
        continuation.finish()
    }

    private func recordTrace(slot: LumenModelSlot, stage: String, stepIndex: Int, error: String, raw: String, prompt: String) {
        SlotAgentDiagnosticsRecorder.record(
            SlotAgentTrace(
                id: UUID(),
                createdAt: Date(),
                slot: slot.rawValue,
                stage: stage,
                stepIndex: stepIndex,
                error: error,
                rawOutputPrefix: String(raw.prefix(2_000)),
                userPromptPrefix: String(prompt.prefix(2_000))
            )
        )
    }

    private func chunk(_ text: String, size: Int = 48) -> [String] {
        guard !text.isEmpty else { return [] }
        var chunks: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[index..<next]))
            index = next
        }
        return chunks
    }
}

nonisolated struct SlotAgentTrace: Codable, Sendable {
    let id: UUID
    let createdAt: Date
    let slot: String
    let stage: String
    let stepIndex: Int
    let error: String
    let rawOutputPrefix: String
    let userPromptPrefix: String
}

nonisolated enum SlotAgentDiagnosticsRecorder {
    static func record(_ trace: SlotAgentTrace) {
        do {
            let directory = try diagnosticsDirectory()
            let url = directory.appendingPathComponent("slot-agent-traces.jsonl", isDirectory: false)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(trace)
            var line = data
            line.append(0x0A)

            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: url, options: [.atomic])
            }
        } catch {
            // Diagnostics must never break generation.
        }
    }

    static func diagnosticsDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("Diagnostics", isDirectory: true).appendingPathComponent("SlotAgent", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
