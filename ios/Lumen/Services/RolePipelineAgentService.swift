import Foundation
import OSLog

@MainActor
final class RolePipelineAgentService {
    static let shared = RolePipelineAgentService()

    private let logger = Logger(subsystem: "ai.lumen.app", category: "role-pipeline")

    private init() {}

    func run(_ req: AgentRequest) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                var steps: [AgentStep] = []
                var observations: [String] = []
                var executedActionFingerprints: Set<String> = []

                let resolution = ReferenceResolver.resolve(
                    prompt: req.userMessage,
                    history: req.history,
                    relevantMemories: req.relevantMemories,
                    currentTurnLedger: ToolLedger.shared.currentTurnEntries(conversationID: req.conversationID, turnID: req.turnID)
                )
                let executionPrompt = resolution.rewrittenPrompt
                let routing = IntentRouter.classify(executionPrompt)
                let scopedTools = req.availableTools.filter { IntentRouter.isToolAllowed($0.id, for: routing) }
                let availableToolIDs = Set(scopedTools.map { ToolRouteGuard.canonicalToolID($0.id) })

                if routing.requiresClarification {
                    let clarification = routing.clarificationPrompt ?? "Could you clarify what you want me to do?"
                    yieldStep(kind: .reflection, content: clarification, steps: &steps, continuation: continuation)
                    await finish(clarification, req: req, steps: steps, continuation: continuation, remContext: .init(observations: observations, routingIntent: routing.intent.rawValue))
                    return
                }

                let requiresTool = IntentRouter.intentRequiresTool(routing)
                if requiresTool && scopedTools.isEmpty {
                    let unavailable = IntentRouter.unavailableMessage(for: routing)
                    await finish(unavailable, req: req, steps: steps, continuation: continuation, remContext: .init(observations: observations, routingIntent: routing.intent.rawValue))
                    return
                }

                if !requiresTool {
                    let mouth = await mouthFinal(req: req, resolution: resolution, routing: routing, observations: [], draft: nil)
                    let styled = await mimicryFinal(req: req, draft: mouth)
                    await finish(styled, req: req, steps: steps, continuation: continuation, remContext: .init(observations: observations, routingIntent: routing.intent.rawValue))
                    return
                }

                let maxSteps = max(1, min(req.maxSteps, maxLoopSteps(for: routing.intent)))
                for stepIndex in 0..<maxSteps {
                    let mode: CortexTurnMode = observations.isEmpty ? .mustAct : .actOrFinalize
                    let cortexPrompt = makeCortexPrompt(
                        req: req,
                        resolution: resolution,
                        observations: observations,
                        scopedTools: scopedTools,
                        stepIndex: stepIndex,
                        mode: mode
                    )
                    let cortexRaw = await generateText(
                        slot: .cortex,
                        req: req,
                        userMessage: cortexPrompt,
                        temperature: observations.isEmpty ? 0.0 : min(req.temperature, 0.25),
                        topP: observations.isEmpty ? 0.05 : min(req.topP, 0.75),
                        maxTokens: mode == .mustAct ? 192 : 256,
                        modelName: "cortex-route-plan-loop"
                    )
                    let cortexTurn = AgentTurnParser.parse(cortexRaw)
                    yieldThoughtIfNeeded(cortexTurn.thought, steps: &steps, continuation: continuation)

                    if let action = cortexTurn.action {
                        let executorTurn = await executorValidateAction(
                            rawCortexOutput: cortexRaw,
                            proposedAction: action,
                            req: req,
                            routing: routing,
                            observations: observations,
                            scopedTools: scopedTools,
                            availableToolIDs: availableToolIDs
                        )
                        yieldThoughtIfNeeded(executorTurn.thought, steps: &steps, continuation: continuation)
                        guard let validatedAction = executorTurn.action else {
                            let finalDraft = executorTurn.final ?? "I need one more detail before I can continue."
                            let mouth = await mouthFinal(req: req, resolution: resolution, routing: routing, observations: observations, draft: finalDraft)
                            let styled = await mimicryFinal(req: req, draft: mouth)
                            await finish(styled, req: req, steps: steps, continuation: continuation, remContext: .init(observations: observations, routingIntent: routing.intent.rawValue))
                            return
                        }

                        let outcome = await executeValidatedAction(
                            validatedAction,
                            req: req,
                            routing: routing,
                            availableToolIDs: availableToolIDs,
                            steps: &steps,
                            observations: &observations,
                            executedActionFingerprints: &executedActionFingerprints,
                            continuation: continuation
                        )

                        switch outcome {
                        case .continueToCortex:
                            continue
                        case .blocked(let text):
                            await finish(text, req: req, steps: steps, continuation: continuation, remContext: .init(observations: observations, routingIntent: routing.intent.rawValue))
                            return
                        }
                    }

                    if let cortexFinal = cortexTurn.final, !cortexFinal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        guard !observations.isEmpty else {
                            let clarification = clarificationPromptForMissingContext(routing: routing, request: executionPrompt)
                            yieldStep(kind: .reflection, content: clarification, steps: &steps, continuation: continuation)
                            await finish(clarification, req: req, steps: steps, continuation: continuation, remContext: .init(observations: observations, routingIntent: routing.intent.rawValue))
                            return
                        }
                        let mouth = await mouthFinal(req: req, resolution: resolution, routing: routing, observations: observations, draft: cortexFinal)
                        let styled = await mimicryFinal(req: req, draft: mouth)
                        await finish(styled, req: req, steps: steps, continuation: continuation, remContext: .init(observations: observations, routingIntent: routing.intent.rawValue))
                        return
                    }

                    if let error = cortexTurn.parseError {
                        logger.error("cortex_parse_error step=\(stepIndex, privacy: .public) error=\(error.rawValue, privacy: .public)")
                    }

                    if let deterministic = DeterministicToolPlanner.plan(routing: routing, prompt: executionPrompt, availableToolIDs: availableToolIDs) {
                        let executorTurn = await executorValidateAction(
                            rawCortexOutput: deterministic.displayContent,
                            proposedAction: deterministic,
                            req: req,
                            routing: routing,
                            observations: observations,
                            scopedTools: scopedTools,
                            availableToolIDs: availableToolIDs
                        )
                        if let validated = executorTurn.action {
                            let outcome = await executeValidatedAction(
                                validated,
                                req: req,
                                routing: routing,
                                availableToolIDs: availableToolIDs,
                                steps: &steps,
                                observations: &observations,
                                executedActionFingerprints: &executedActionFingerprints,
                                continuation: continuation
                            )
                            if case .continueToCortex = outcome { continue }
                        }
                    }

                    let clarification = clarificationPromptForMissingContext(routing: routing, request: executionPrompt)
                    yieldStep(kind: .reflection, content: clarification, steps: &steps, continuation: continuation)
                    await finish(clarification, req: req, steps: steps, continuation: continuation, remContext: .init(observations: observations, routingIntent: routing.intent.rawValue))
                    return
                }

                let mouth = await mouthFinal(req: req, resolution: resolution, routing: routing, observations: observations, draft: observations.last)
                let styled = await mimicryFinal(req: req, draft: mouth)
                await finish(styled, req: req, steps: steps, continuation: continuation, remContext: .init(observations: observations, routingIntent: routing.intent.rawValue))
            }

            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private enum CortexTurnMode { case mustAct, actOrFinalize }
    private enum ToolOutcome { case continueToCortex, blocked(String) }
    private struct REMContext { let observations: [String]; let routingIntent: String }

    private func executeValidatedAction(
        _ action: AgentAction,
        req: AgentRequest,
        routing: IntentRoutingDecision,
        availableToolIDs: Set<String>,
        steps: inout [AgentStep],
        observations: inout [String],
        executedActionFingerprints: inout Set<String>,
        continuation: AsyncStream<AgentEvent>.Continuation
    ) async -> ToolOutcome {
        let canonicalTool = ToolRouteGuard.canonicalToolID(action.tool)
        let normalizedArgs = ToolRouteGuard.normalizedArguments(for: canonicalTool, rawToolID: action.tool, arguments: action.args.stringCoerced)
        let fingerprint = actionFingerprint(toolID: canonicalTool, arguments: normalizedArgs)

        guard availableToolIDs.contains(canonicalTool), isActionAllowed(canonicalTool, routing: routing) else {
            return .blocked(IntentRouter.blockedToolMessage(for: routing))
        }

        guard !executedActionFingerprints.contains(fingerprint) else {
            return .blocked("I stopped because the planner attempted to repeat the same tool call without adding new information.")
        }

        executedActionFingerprints.insert(fingerprint)
        yieldStep(kind: .action, content: action.displayContent, toolID: canonicalTool, toolArgs: normalizedArgs, steps: &steps, continuation: continuation)

        let observation = await ToolExecutor.shared.execute(
            canonicalTool,
            arguments: normalizedArgs,
            approval: approvalForExplicitUserIntent(toolID: canonicalTool, routing: routing)
        )
        let scopedObservation = "\(canonicalTool): \(observation)"
        observations.append(scopedObservation)
        ToolLedger.shared.record(
            conversationID: req.conversationID,
            turnID: req.turnID,
            intent: routing.intent,
            toolID: canonicalTool,
            query: action.displayContent,
            result: observation
        )
        yieldStep(kind: .observation, content: observation, toolID: canonicalTool, toolArgs: normalizedArgs, steps: &steps, continuation: continuation)

        return .continueToCortex
    }

    private func executorValidateAction(
        rawCortexOutput: String,
        proposedAction: AgentAction,
        req: AgentRequest,
        routing: IntentRoutingDecision,
        observations: [String],
        scopedTools: [ToolDefinition],
        availableToolIDs: Set<String>
    ) async -> AgentTurn {
        let tools = scopedTools.map { "- \($0.id): \($0.description)" }.joined(separator: "\n")
        let observationBlock = observations.isEmpty ? "none" : observations.joined(separator: "\n")
        let prompt = """
        You are Lumen Executor. Validate and repair Cortex's proposed tool action before native execution.

        Return exactly one JSON object and no markdown.

        Allowed schema:
        {"thought":"short validation note","action":{"tool":"tool.id","args":{"key":"value"}}}
        or, only when execution cannot safely continue:
        {"thought":"short reason","final":"one concise clarification or blocked-action explanation"}

        Hard rules:
        - Use exactly one tool from Available tools if returning action.
        - Canonicalize the tool id.
        - Preserve Cortex intent when safe.
        - Normalize argument value types to strings, numbers, booleans, arrays, or objects.
        - Do not invent unavailable tools.
        - Do not execute. Validation only.

        Intent: \(routing.intent.rawValue)
        Available tools:
        \(tools)

        Prior current-turn observations:
        \(observationBlock)

        Raw Cortex output:
        \(rawCortexOutput)

        Parsed proposed action:
        \(proposedAction.displayContent)
        """
        let raw = await generateText(
            slot: .executor,
            req: req,
            userMessage: prompt,
            temperature: 0.0,
            topP: 0.05,
            maxTokens: 192,
            modelName: "executor-action-validator"
        )
        let repaired = AgentTurnParser.parse(raw)
        if let action = repaired.action {
            let canonical = ToolRouteGuard.canonicalToolID(action.tool)
            if availableToolIDs.contains(canonical), isActionAllowed(canonical, routing: routing) {
                return repaired
            }
        }
        let proposedCanonical = ToolRouteGuard.canonicalToolID(proposedAction.tool)
        if availableToolIDs.contains(proposedCanonical), isActionAllowed(proposedCanonical, routing: routing) {
            return AgentTurn(thought: repaired.thought ?? "Executor kept Cortex action after validation fallback.", action: proposedAction, final: nil, parseError: nil, hadNoise: repaired.hadNoise)
        }
        return repaired
    }

    private func mouthFinal(
        req: AgentRequest,
        resolution: ReferenceResolution,
        routing: IntentRoutingDecision,
        observations: [String],
        draft: String?
    ) async -> String {
        let observationBlock = observations.isEmpty ? "none" : observations.map(WebRichContentPayload.removingMarkers).joined(separator: "\n")
        let draftBlock = draft.map(WebRichContentPayload.removingMarkers) ?? "none"
        let prompt = """
        You are Lumen Mouth. Write the final user-facing answer for the current request only. Do not output JSON.

        Original user request:
        \(resolution.originalPrompt)

        Rewritten execution request:
        \(resolution.rewrittenPrompt)

        Current-turn tool observations:
        \(observationBlock)

        Cortex final draft if any:
        \(draftBlock)

        Rules:
        - Current-turn observations are the source of truth.
        - Do not claim actions that did not happen.
        - If a required detail is missing, ask one concise clarification question.
        - Keep it concise and directly useful.
        """
        let raw = await generateText(
            slot: .mouth,
            req: req,
            userMessage: prompt,
            temperature: min(req.temperature, 0.35),
            topP: min(req.topP, 0.8),
            maxTokens: min(req.maxTokens, 384),
            modelName: "mouth-final-user-answer"
        )
        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (draft ?? "I’m here.") : raw
        let validated = FinalIntentValidator.validate(candidate, routing: routing, fallback: observations.last ?? draft)
        return appendRichPayloadMarkersIfNeeded(to: validated, from: observations + [draft ?? ""])
    }

    private func mimicryFinal(req: AgentRequest, draft: String) async -> String {
        guard req.userMessage.localizedCaseInsensitiveContains("rewrite in my style")
            || req.userMessage.localizedCaseInsensitiveContains("use my tone")
            || req.userMessage.localizedCaseInsensitiveContains("mimicry")
        else { return draft }
        let clean = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.lowercased().contains("generation error:") else { return draft }
        let prompt = """
        You are Lumen Mimicry. Rewrite the final answer for delivery while preserving meaning exactly.

        Rules:
        - Do not add facts.
        - Do not remove warnings, failures, uncertainty, or missing-permission notes.
        - Do not claim an action happened unless the draft says it happened.
        - Keep it concise and conversational.
        - Output final user-facing text only.

        User request:
        \(req.userMessage)

        Mouth draft:
        \(clean)
        """
        let styled = await generateText(
            slot: .mimicry,
            req: req,
            userMessage: prompt,
            temperature: min(req.temperature, 0.25),
            topP: min(req.topP, 0.8),
            maxTokens: min(max(96, req.maxTokens), 256),
            modelName: "mimicry-user-facing-style"
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        if styled.isEmpty || styled.lowercased().contains("generation error:") { return draft }
        return styled
    }

    private func finish(
        _ finalText: String,
        req: AgentRequest,
        steps: [AgentStep],
        continuation: AsyncStream<AgentEvent>.Continuation,
        remContext: REMContext
    ) async {
        let final = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        continuation.yield(.finalDelta(final))
        continuation.yield(.done(finalText: final, steps: steps))
        continuation.finish()
        scheduleREMAudit(req: req, finalText: final, context: remContext)
    }

    private func scheduleREMAudit(req: AgentRequest, finalText: String, context: REMContext) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await runREMAudit(req: req, finalText: finalText, context: context)
        }
    }

    private func runREMAudit(req: AgentRequest, finalText: String, context: REMContext) async {
        let observationBlock = context.observations.isEmpty ? "none" : context.observations.joined(separator: "\n")
        let prompt = """
        You are Lumen REM. Produce a compact post-turn audit record for the improvement loop.
        Return JSON only with keys: role, quality, pipeline, trainingSignal.

        User request:
        \(req.userMessage)

        Intent:
        \(context.routingIntent)

        Observations:
        \(observationBlock)

        Final user answer:
        \(finalText)
        """
        let audit = await generateText(
            slot: .rem,
            req: req,
            userMessage: prompt,
            temperature: 0.2,
            topP: 0.8,
            maxTokens: 240,
            modelName: "rem-post-turn-audit"
        )
        persistREMAudit(req: req, finalText: finalText, audit: audit)
    }

    private func persistREMAudit(req: AgentRequest, finalText: String, audit: String) {
        do {
            let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
            let directory = base.appendingPathComponent("Diagnostics", isDirectory: true).appendingPathComponent("REM", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("rem-post-turn-audits.jsonl")
            let payload: [String: Any] = [
                "id": UUID().uuidString,
                "createdAt": ISO8601DateFormatter().string(from: Date()),
                "userMessagePrefix": String(req.userMessage.prefix(800)),
                "finalTextPrefix": String(finalText.prefix(1200)),
                "auditPrefix": String(audit.prefix(2000))
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            var line = data
            line.append(0x0A)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: url, options: [.atomic])
            }
        } catch {
            logger.error("rem_audit_persist_failed error=\(String(describing: error), privacy: .public)")
        }
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
            case .text(let text): output += text
            case .done: break
            }
        }
        return output
    }

    private func makeCortexPrompt(
        req: AgentRequest,
        resolution: ReferenceResolution,
        observations: [String],
        scopedTools: [ToolDefinition],
        stepIndex: Int,
        mode: CortexTurnMode
    ) -> String {
        let tools = scopedTools.map { "- \($0.id): \($0.description)" }.joined(separator: "\n")
        let observationBlock = observations.isEmpty ? "none" : observations.map(WebRichContentPayload.removingMarkers).joined(separator: "\n")
        let outputSchema = mode == .mustAct
            ? "{\"thought\":\"short routing note\",\"action\":{\"tool\":\"tool.id\",\"args\":{\"key\":\"value\"}}}"
            : "{\"thought\":\"short routing note\",\"action\":{\"tool\":\"tool.id\",\"args\":{\"key\":\"value\"}}}\n{\"thought\":\"short completion note\",\"final\":\"final answer draft grounded in observations\"}"
        return """
        You are Lumen Cortex, the decision authority for this turn. Return exactly one JSON object and no markdown.

        Step: \(stepIndex + 1)
        Original user request:
        \(resolution.originalPrompt)

        Rewritten execution request:
        \(resolution.rewrittenPrompt)

        Current-turn observations:
        \(observationBlock)

        Available tools:
        \(tools)

        Allowed output schema:
        \(outputSchema)

        Rules:
        - Decide whether more input/tool evidence is required.
        - If no observations exist, output an action.
        - If observations are sufficient, output final.
        - If observations are insufficient, output another action.
        - Never call the same tool with identical arguments twice.
        - Use only available tools.
        """
    }

    private func yieldThoughtIfNeeded(_ thought: String?, steps: inout [AgentStep], continuation: AsyncStream<AgentEvent>.Continuation) {
        guard let thought, !thought.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        yieldStep(kind: .thought, content: thought, steps: &steps, continuation: continuation)
    }

    private func yieldStep(kind: AgentStep.Kind, content: String, toolID: String? = nil, toolArgs: [String: String]? = nil, steps: inout [AgentStep], continuation: AsyncStream<AgentEvent>.Continuation) {
        let step = AgentStep(kind: kind, content: content, toolID: toolID, toolArgs: toolArgs)
        steps.append(step)
        continuation.yield(.step(step))
    }

    private func actionFingerprint(toolID: String, arguments: [String: String]) -> String {
        let args = arguments.keys.sorted().map { "\($0)=\(arguments[$0] ?? "")" }.joined(separator: "&")
        return "\(toolID)|\(args)"
    }

    private func isActionAllowed(_ toolID: String, routing: IntentRoutingDecision) -> Bool {
        IntentRouter.isToolAllowed(toolID, for: routing)
    }

    private func approvalForExplicitUserIntent(toolID: String, routing: IntentRoutingDecision) -> ToolExecutionApproval {
        switch (routing.intent, toolID) {
        case (.phoneCall, "phone.call"), (.messageDraft, "messages.draft"), (.emailDraft, "mail.draft"):
            return .userApproved
        case (.outlook, "outlook.draft.create"), (.outlook, "outlook.mail.send"), (.outlook, "outlook.message.mark_read"), (.outlook, "outlook.message.mark_unread"), (.outlook, "outlook.message.move"), (.outlook, "outlook.message.archive"), (.outlook, "outlook.message.delete"), (.outlook, "outlook.message.reply"), (.outlook, "outlook.message.reply_all"), (.outlook, "outlook.message.forward"):
            return .userApproved
        default:
            return .autonomous
        }
    }

    private func maxLoopSteps(for intent: UserIntent) -> Int {
        switch intent {
        case .weather, .webSearch, .maps, .photos, .camera, .health, .motion, .files, .memory, .rag, .contactSearch:
            return 3
        case .emailDraft, .messageDraft, .phoneCall, .calendar, .reminder, .trigger, .alarm, .note, .outlook:
            return 5
        case .chat, .unknown:
            return 1
        }
    }

    private func clarificationPromptForMissingContext(routing: IntentRoutingDecision, request: String) -> String {
        let hint: String
        switch routing.intent {
        case .weather: hint = "location or timeframe"
        case .webSearch, .rag, .files: hint = "topic scope or source"
        case .maps: hint = "destination or travel context"
        case .phoneCall, .messageDraft, .emailDraft, .outlook: hint = "recipient or intended action"
        case .calendar, .reminder, .trigger, .alarm: hint = "time or completion criteria"
        default: hint = "missing detail"
        }
        return "I need one more detail: the \(hint) for this request."
    }

    private func appendRichPayloadMarkersIfNeeded(to text: String, from sources: [String]) -> String {
        let existingKeys = Set(WebRichContentPayload.decodeAll(from: text).map(payloadKey))
        let payloads = sources.flatMap { WebRichContentPayload.decodeAll(from: $0) }
        guard !payloads.isEmpty else { return text }
        var seen = existingKeys
        var markers: [String] = []
        for payload in payloads {
            let key = payloadKey(payload)
            guard seen.insert(key).inserted else { continue }
            markers.append(payload.encodedMarker())
        }
        guard !markers.isEmpty else { return text }
        return text + markers.joined()
    }

    private func payloadKey(_ payload: WebRichContentPayload) -> String {
        switch payload.kind {
        case .searchResults:
            return "search:\(payload.query ?? ""):\(payload.results.map { $0.url ?? $0.title }.joined(separator: "|"))"
        case .fetchedPage:
            return "page:\(payload.page?.url ?? "")"
        }
    }
}
