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
                    for chunk in chunk(clarification) {
                        continuation.yield(.finalDelta(chunk))
                    }
                    continuation.yield(.done(finalText: clarification, steps: steps))
                    continuation.finish()
                    return
                }

                if IntentRouter.intentRequiresTool(routing) && scopedTools.isEmpty {
                    let unavailable = IntentRouter.unavailableMessage(for: routing)
                    for chunk in chunk(unavailable) {
                        continuation.yield(.finalDelta(chunk))
                    }
                    continuation.yield(.done(finalText: unavailable, steps: steps))
                    continuation.finish()
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
                        SlotAgentDiagnosticsRecorder.record(
                            SlotAgentTrace(
                                id: UUID(),
                                createdAt: Date(),
                                slot: slot.rawValue,
                                stage: "structured-turn",
                                stepIndex: stepIndex,
                                error: error.rawValue,
                                rawOutputPrefix: String(turnOutput.prefix(2_000)),
                                userPromptPrefix: String(req.userMessage.prefix(2_000))
                            )
                        )
                    }

                    if let thought = parsed.thought, !thought.isEmpty {
                        let thoughtStep = AgentStep(kind: .thought, content: thought, toolID: nil, toolArgs: nil)
                        steps.append(thoughtStep)
                        continuation.yield(.step(thoughtStep))
                    }

                    if let final = parsed.final, !final.isEmpty {
                        finalText = await generateFinal(req: req, observations: observations, draft: final)
                        for chunk in chunk(finalText) {
                            continuation.yield(.finalDelta(chunk))
                        }
                        continuation.yield(.done(finalText: finalText, steps: steps))
                        continuation.finish()
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
                        finalText = await generateFinal(req: req, observations: observations, draft: turnOutput)
                        for chunk in chunk(finalText) {
                            continuation.yield(.finalDelta(chunk))
                        }
                        continuation.yield(.done(finalText: finalText, steps: steps))
                        continuation.finish()
                        return
                    }

                    let actionStep = AgentStep(
                        kind: .action,
                        content: action.displayContent,
                        toolID: action.tool,
                        toolArgs: action.args.stringCoerced
                    )
                    steps.append(actionStep)
                    continuation.yield(.step(actionStep))

                    guard SlotAgentService.isActionAllowed(action.tool, routing: routing) else {
                        SlotAgentDiagnosticsRecorder.record(
                            SlotAgentTrace(
                                id: UUID(),
                                createdAt: Date(),
                                slot: slot.rawValue,
                                stage: "tool-execution",
                                stepIndex: stepIndex,
                                error: "tool_not_allowed_for_intent",
                                rawOutputPrefix: String(action.displayContent.prefix(2_000)),
                                userPromptPrefix: String(req.userMessage.prefix(2_000))
                            )
                        )
                        finalText = IntentRouter.blockedToolMessage(for: routing)
                        for chunk in chunk(finalText) {
                            continuation.yield(.finalDelta(chunk))
                        }
                        continuation.yield(.done(finalText: finalText, steps: steps))
                        continuation.finish()
                        return
                    }

                    let observation = await ToolExecutor.shared.execute(action.tool, arguments: action.args)
                    observations.append("\(action.tool): \(observation)")
                    let observationStep = AgentStep(kind: .observation, content: observation, toolID: action.tool, toolArgs: action.args.stringCoerced)
                    steps.append(observationStep)
                    continuation.yield(.step(observationStep))
                }

                finalText = await generateFinal(req: req, observations: observations, draft: nil)
                for chunk in chunk(finalText) {
                    continuation.yield(.finalDelta(chunk))
                }
                continuation.yield(.done(finalText: finalText, steps: steps))
                continuation.finish()
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private func generateFinal(req: AgentRequest, observations: [String], draft: String?) async -> String {
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
        if trimmed.isEmpty, let draft, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return draft.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
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
        let generation = GenerateRequest(
            systemPrompt: req.systemPrompt,
            history: req.history,
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
            SlotAgentDiagnosticsRecorder.record(
                SlotAgentTrace(
                    id: UUID(),
                    createdAt: Date(),
                    slot: slot.rawValue,
                    stage: modelName,
                    stepIndex: -1,
                    error: "generation_error",
                    rawOutputPrefix: String(output.prefix(2_000)),
                    userPromptPrefix: String(userMessage.prefix(2_000))
                )
            )
        }
        return output
    }

    private func makeStructuredTurnPrompt(req: AgentRequest, observations: [String], stepIndex: Int, scopedTools: [ToolDefinition]) -> String {
        let tools = scopedTools.map { tool in
            "- \(tool.id): \(tool.description)"
        }.joined(separator: "\n")
        let observationBlock = observations.isEmpty ? "none" : observations.joined(separator: "\n")

        return """
        You are running Lumen v1 step \(stepIndex + 1). Return exactly one JSON object and no markdown.

        User request:
        \(req.userMessage)

        Previous observations:
        \(observationBlock)

        Available tools:
        \(tools)

        Output schema for using a tool:
        {"thought":"short private routing note","action":{"tool":"tool.id","args":{"key":"value"}}}

        Output schema for final answer:
        {"thought":"short private routing note","final":"answer shown to the user"}

        Rules:
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
        Write the final user-facing answer. Do not output JSON.

        User request:
        \(req.userMessage)

        Tool observations:
        \(observationBlock)

        Draft final from Cortex/Executor:
        \(draftBlock)

        Keep it concise, accurate, and do not claim actions that did not happen.
        """
    }


    nonisolated static func isActionAllowed(_ toolID: String, routing: IntentRoutingDecision) -> Bool {
        IntentRouter.isToolAllowed(toolID, for: routing)
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
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("SlotAgent", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
