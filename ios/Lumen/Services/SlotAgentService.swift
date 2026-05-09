import Foundation

@MainActor
final class SlotAgentService {
    static let shared = SlotAgentService()
    nonisolated static let mouthPromptHygieneRule = "Output only the final user-visible answer. Never output hidden reasoning, <think> blocks, JSON, debug text, tool payloads, or internal analysis. If prior context contains hidden reasoning, ignore it and do not imitate it."

    private enum GenerationStage: String {
        case mouthDirect = "mouth-direct"
        case mouthFinal = "mouth-final"
    }

    private enum StageTokenBudget {
        static let directLow = 200
        static let directHigh = 320
        static let finalLow = 260
        static let finalHigh = 420
        static let retryBump = 80
        static let retryCeiling = 640
    }

    private enum RetryHeuristic {
        static let minWordCount = 28
        static let intentsNeedingDepth: Set<UserIntent> = [.chat, .webSearch, .rag, .files, .outlook, .unknown]
    }

    private static func cappedMaxTokens(_ requested: Int, stageCap: Int) -> Int {
        // Enforce a minimum allocation so very low caller caps still allow a coherent response.
        max(64, min(requested, stageCap))
    }

    private static func adaptiveTokenCap(for intent: UserIntent, stage: GenerationStage) -> Int {
        switch (intent, stage) {
        case (.chat, .mouthDirect), (.unknown, .mouthDirect):
            return StageTokenBudget.directHigh
        case (.chat, .mouthFinal), (.unknown, .mouthFinal):
            return StageTokenBudget.finalHigh
        case (.webSearch, .mouthFinal), (.rag, .mouthFinal), (.files, .mouthFinal), (.outlook, .mouthFinal):
            return StageTokenBudget.finalHigh
        case (.emailDraft, _), (.messageDraft, _), (.phoneCall, _), (.calendar, _), (.reminder, _), (.trigger, _), (.alarm, _), (.camera, _):
            return stage == .mouthFinal ? StageTokenBudget.finalLow : StageTokenBudget.directLow
        default:
            return stage == .mouthFinal ? 340 : 260
        }
    }

    private init() {}

    func run(_ req: AgentRequest) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                var steps: [AgentStep] = []
                var observations: [String] = []
                var finalText = ""
                var executedActionFingerprints: Set<String> = []

                let resolution = ReferenceResolver.resolve(
                    prompt: req.userMessage,
                    history: req.history,
                    relevantMemories: req.relevantMemories,
                    currentTurnLedger: ToolLedger.shared.currentTurnEntries(conversationID: req.conversationID, turnID: req.turnID)
                )
                let executionPrompt = resolution.rewrittenPrompt
                let routing = await IntentClassifierService.shared.route(executionPrompt)
                let scopedTools = req.availableTools.filter { IntentRouter.isToolAllowed($0.id, for: routing) }
                let requiresTool = IntentRouter.intentRequiresTool(routing)

                if routing.requiresClarification {
                    let clarification = routing.clarificationPrompt ?? "Could you clarify what you want me to do?"
                    let clarificationStep = AgentStep(kind: .reflection, content: clarification, toolID: nil, toolArgs: nil)
                    steps.append(clarificationStep)
                    continuation.yield(.step(clarificationStep))
                    yieldFinal(clarification, steps: steps, continuation: continuation)
                    return
                }

                if requiresTool && scopedTools.isEmpty {
                    let unavailable = IntentRouter.unavailableMessage(for: routing)
                    yieldFinal(unavailable, steps: steps, continuation: continuation)
                    return
                }

                if !requiresTool {
                    let final = await generateDirectFinal(req: req, resolution: resolution, routing: routing)
                    yieldFinal(final, steps: steps, continuation: continuation)
                    return
                }

                let availableToolIDs = Set(scopedTools.map { ToolRouteGuard.canonicalToolID($0.id) })
                let missingRequiredTools = Self.requiredTools(for: routing.intent).subtracting(availableToolIDs)
                if !missingRequiredTools.isEmpty {
                    recordPolicyDiagnostics(selectedTool: nil, allowedForIntent: routing.allowedToolIDs, policyViolation: false, replanned: true, prompt: executionPrompt)
                    let replanStep = AgentStep(kind: .reflection, content: "I need to replan because required tools are unavailable for this intent: \(missingRequiredTools.sorted().joined(separator: ", ")).", toolID: nil, toolArgs: nil)
                    steps.append(replanStep)
                    continuation.yield(.step(replanStep))
                    let final = IntentRouter.unavailableMessage(for: routing)
                    yieldFinal(final, steps: steps, continuation: continuation)
                    return
                }
                let requiredFallbackTool = Self.resolveRequiredToolFallback(
                    intent: routing.intent,
                    prompt: executionPrompt,
                    allowedToolIDs: Array(availableToolIDs)
                )
                let maxSteps = boundedMaxSteps(for: routing, requested: req.maxSteps)
                var loopStartIndex = 0
                if maxSteps > 0,
                   let deterministicPrimaryAction = Self.deterministicPrimaryAction(
                    routing: routing,
                    prompt: executionPrompt,
                    scopedTools: scopedTools,
                    availableToolIDs: availableToolIDs
                ) {
                    recordTrace(
                        slot: .executor,
                        stage: "deterministic-primary-plan",
                        stepIndex: 0,
                        error: "intent=\(routing.intent.rawValue);selected_tool=\(ToolRouteGuard.canonicalToolID(deterministicPrimaryAction.tool));cortex_bypassed=true",
                        raw: deterministicPrimaryAction.displayContent,
                        prompt: executionPrompt
                    )
                    let result = await executeAction(
                        deterministicPrimaryAction,
                        req: req,
                        routing: routing,
                        steps: &steps,
                        observations: &observations,
                        executedActionFingerprints: &executedActionFingerprints,
                        continuation: continuation,
                        stepIndex: 0
                    )

                    switch result {
                    case .continueLoop:
                        loopStartIndex = 1
                    case .finalizeImmediate(let text):
                        finalText = text
                        yieldFinal(finalText, steps: steps, continuation: continuation)
                        return
                    case .finalizeNow(let draft):
                        finalText = await generateFinal(req: req, resolution: resolution, routing: routing, observations: observations, draft: draft)
                        yieldFinal(finalText, steps: steps, continuation: continuation)
                        return
                    case .blocked(let text):
                        yieldFinal(text, steps: steps, continuation: continuation)
                        return
                    }
                }

                for stepIndex in loopStartIndex..<maxSteps {
                    let structuredMode: StructuredTurnMode = observations.isEmpty ? .actionOnly : .actionOrFinal
                    let slot: LumenModelSlot = .cortex
                    let turnPrompt = makeStructuredTurnPrompt(
                        req: req,
                        resolution: resolution,
                        observations: observations,
                        stepIndex: stepIndex,
                        scopedTools: scopedTools,
                        mode: structuredMode
                    )
                    let turnOutput = await generateText(
                        slot: slot,
                        req: req,
                        userMessage: turnPrompt,
                        temperature: observations.isEmpty ? 0.0 : min(req.temperature, 0.35),
                        topP: observations.isEmpty ? 0.05 : min(req.topP, 0.8),
                        maxTokens: min(req.maxTokens, structuredMode == .actionOnly ? 180 : 260),
                        modelName: "cortex-orchestrator-json"
                    )

                    let parsed = AgentTurnParser.parse(turnOutput)
                    if let error = parsed.parseError {
                        recordTrace(slot: slot, stage: "structured-turn-\(structuredMode.rawValue)", stepIndex: stepIndex, error: error.rawValue, raw: turnOutput, prompt: executionPrompt)
                    }

                    if let thought = parsed.thought, !thought.isEmpty {
                        let thoughtStep = AgentStep(kind: .thought, content: thought, toolID: nil, toolArgs: nil)
                        steps.append(thoughtStep)
                        continuation.yield(.step(thoughtStep))
                    }

                    if let final = parsed.final, !final.isEmpty {
                        if observations.isEmpty,
                           let fallbackTool = requiredFallbackTool,
                           let fallbackAction = DeterministicToolPlanner.planForSpecificTool(
                               toolID: fallbackTool,
                               prompt: executionPrompt,
                               availableToolIDs: availableToolIDs
                           ) {
                            let fallbackResult = await executeAction(
                                fallbackAction,
                                req: req,
                                routing: routing,
                                steps: &steps,
                                observations: &observations,
                                executedActionFingerprints: &executedActionFingerprints,
                                continuation: continuation,
                                stepIndex: stepIndex
                            )
                            switch fallbackResult {
                            case .continueLoop:
                                continue
                            case .finalizeImmediate(let text):
                                finalText = text
                                yieldFinal(finalText, steps: steps, continuation: continuation)
                                return
                            case .finalizeNow(let draft):
                                finalText = await generateFinal(req: req, resolution: resolution, routing: routing, observations: observations, draft: draft)
                                yieldFinal(finalText, steps: steps, continuation: continuation)
                                return
                            case .blocked(let text):
                                yieldFinal(text, steps: steps, continuation: continuation)
                                return
                            }
                        }
                        if observations.isEmpty {
                            let clarification = clarificationPromptForMissingContext(routing: routing, resolution: resolution)
                            let clarificationStep = AgentStep(kind: .reflection, content: clarification, toolID: nil, toolArgs: nil)
                            steps.append(clarificationStep)
                            continuation.yield(.step(clarificationStep))
                            yieldFinal(clarification, steps: steps, continuation: continuation)
                            return
                        }
                        finalText = FinalIntentValidator.validate(final, routing: routing, fallback: observations.last)
                        finalText = enforceIntentSpecificFinalQuality(
                            finalText,
                            routing: routing,
                            resolution: resolution,
                            observations: observations
                        )
                        finalText = appendRichPayloadMarkersIfNeeded(to: finalText, from: observations)
                        yieldFinal(finalText, steps: steps, continuation: continuation)
                        return
                    }

                    guard let action = parsed.action else {
                        if structuredMode == .actionOnly,
                           let fallbackAction = DeterministicToolPlanner.plan(
                               routing: routing,
                               prompt: executionPrompt,
                               availableToolIDs: availableToolIDs
                           ) {
                            let canonicalFallbackTool = ToolRouteGuard.canonicalToolID(fallbackAction.tool)
                            let isFallbackToolAvailable = scopedTools.contains { ToolRouteGuard.canonicalToolID($0.id) == canonicalFallbackTool }
                            let isFallbackToolAllowed = SlotAgentService.isActionAllowed(canonicalFallbackTool, routing: routing)
                            guard isFallbackToolAvailable && isFallbackToolAllowed else {
                                let skipStep = AgentStep(
                                    kind: .reflection,
                                    content: "Structured action turn failed: \(parsed.parseError?.rawValue ?? "unknown"). Deterministic fallback skipped because \(canonicalFallbackTool) is not available for this turn.",
                                    toolID: nil,
                                    toolArgs: nil
                                )
                                steps.append(skipStep)
                                continuation.yield(.step(skipStep))
                                finalText = await generateFinal(req: req, resolution: resolution, routing: routing, observations: observations, draft: nil)
                                yieldFinal(finalText, steps: steps, continuation: continuation)
                                return
                            }

                            let result = await executeAction(
                                fallbackAction,
                                req: req,
                                routing: routing,
                                steps: &steps,
                                observations: &observations,
                                executedActionFingerprints: &executedActionFingerprints,
                                continuation: continuation,
                                stepIndex: stepIndex
                            )
                            switch result {
                            case .continueLoop:
                                continue
                            case .finalizeImmediate(let text):
                                finalText = text
                                yieldFinal(finalText, steps: steps, continuation: continuation)
                                return
                            case .finalizeNow(let draft):
                                finalText = await generateFinal(req: req, resolution: resolution, routing: routing, observations: observations, draft: draft)
                                yieldFinal(finalText, steps: steps, continuation: continuation)
                                return
                            case .blocked(let text):
                                yieldFinal(text, steps: steps, continuation: continuation)
                                return
                            }
                        }
                        if let fallbackTool = requiredFallbackTool,
                           let fallbackAction = DeterministicToolPlanner.planForSpecificTool(
                               toolID: fallbackTool,
                               prompt: executionPrompt,
                               availableToolIDs: availableToolIDs
                           ) {
                            let result = await executeAction(
                                fallbackAction,
                                req: req,
                                routing: routing,
                                steps: &steps,
                                observations: &observations,
                                executedActionFingerprints: &executedActionFingerprints,
                                continuation: continuation,
                                stepIndex: stepIndex
                            )
                            switch result {
                            case .continueLoop:
                                continue
                            case .finalizeImmediate(let text):
                                finalText = text
                                yieldFinal(finalText, steps: steps, continuation: continuation)
                                return
                            case .finalizeNow(let draft):
                                finalText = await generateFinal(req: req, resolution: resolution, routing: routing, observations: observations, draft: draft)
                                yieldFinal(finalText, steps: steps, continuation: continuation)
                                return
                            case .blocked(let text):
                                yieldFinal(text, steps: steps, continuation: continuation)
                                return
                            }
                        }

                        finalText = await generateFinal(req: req, resolution: resolution, routing: routing, observations: observations, draft: nil)
                        yieldFinal(finalText, steps: steps, continuation: continuation)
                        return
                    }

                    let result = await executeAction(
                        action,
                        req: req,
                        routing: routing,
                        steps: &steps,
                        observations: &observations,
                        executedActionFingerprints: &executedActionFingerprints,
                        continuation: continuation,
                        stepIndex: stepIndex
                    )

                    switch result {
                    case .continueLoop:
                        continue
                    case .finalizeImmediate(let text):
                        finalText = text
                        yieldFinal(finalText, steps: steps, continuation: continuation)
                        return
                    case .finalizeNow(let draft):
                        finalText = await generateFinal(req: req, resolution: resolution, routing: routing, observations: observations, draft: draft)
                        yieldFinal(finalText, steps: steps, continuation: continuation)
                        return
                    case .blocked(let text):
                        yieldFinal(text, steps: steps, continuation: continuation)
                        return
                    }
                }

                finalText = await generateFinal(req: req, resolution: resolution, routing: routing, observations: observations, draft: observations.last)
                yieldFinal(finalText, steps: steps, continuation: continuation)
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private enum ActionExecutionResult {
        case continueLoop
        case finalizeNow(String?)
        case finalizeImmediate(String)
        case blocked(String)
    }

    private func executeAction(
        _ action: AgentAction,
        req: AgentRequest,
        routing: IntentRoutingDecision,
        steps: inout [AgentStep],
        observations: inout [String],
        executedActionFingerprints: inout Set<String>,
        continuation: AsyncStream<AgentEvent>.Continuation,
        stepIndex: Int
    ) async -> ActionExecutionResult {
        let canonicalTool = ToolRouteGuard.canonicalToolID(action.tool)
        let normalizedArgs = ToolRouteGuard.normalizedArguments(for: canonicalTool, rawToolID: action.tool, arguments: action.args.stringCoerced)
        let fingerprint = actionFingerprint(toolID: canonicalTool, arguments: normalizedArgs)

        if executedActionFingerprints.contains(fingerprint) {
            recordTrace(slot: .executor, stage: "tool-loop", stepIndex: stepIndex, error: "duplicate_tool_action", raw: action.displayContent, prompt: req.userMessage)
            return .finalizeNow(observations.last)
        }

        let isAllowed = SlotAgentService.isActionAllowed(canonicalTool, routing: routing)
        recordPolicyDiagnostics(selectedTool: canonicalTool, allowedForIntent: routing.allowedToolIDs, policyViolation: !isAllowed, replanned: false, prompt: req.userMessage)
        guard isAllowed else {
            recordTrace(slot: .executor, stage: "tool-execution", stepIndex: stepIndex, error: "tool_not_allowed_for_intent", raw: action.displayContent, prompt: req.userMessage)
            return .blocked(IntentRouter.blockedToolMessage(for: routing))
        }



        if let tool = ToolRegistry.find(id: canonicalTool), tool.requiresApproval {
            let pending = ToolApprovalQueue.shared.enqueue(toolID: canonicalTool, toolName: tool.name, arguments: normalizedArgs)
            let approvalMessage = ApprovalBoundaryFormatter.approvalMessage(for: pending)
            var boundaryArgs = normalizedArgs
            boundaryArgs["pendingActionID"] = pending.pendingActionID.uuidString
            let approvalStep = AgentStep(kind: .approvalBoundary, content: approvalMessage, toolID: canonicalTool, toolArgs: boundaryArgs)
            steps.append(approvalStep)
            continuation.yield(.step(approvalStep))
            return .finalizeImmediate(approvalMessage)
        }
        let actionStep = AgentStep(kind: .action, content: action.displayContent, toolID: canonicalTool, toolArgs: normalizedArgs)
        steps.append(actionStep)
        continuation.yield(.step(actionStep))

        executedActionFingerprints.insert(fingerprint)
        let observation = await ToolExecutor.shared.execute(
            canonicalTool,
            arguments: normalizedArgs,
            approval: .autonomous
        )
        observations.append("\(canonicalTool): \(observation)")
        ToolLedger.shared.record(
            conversationID: req.conversationID,
            turnID: req.turnID,
            intent: routing.intent,
            toolID: canonicalTool,
            query: action.displayContent,
            result: observation
        )
        let observationStep = AgentStep(kind: .observation, content: observation, toolID: canonicalTool, toolArgs: normalizedArgs)
        steps.append(observationStep)
        continuation.yield(.step(observationStep))

        if let chained = deterministicFollowUpAction(after: canonicalTool, observation: observation, req: req, routing: routing) {
            return await executeAction(
                chained,
                req: req,
                routing: routing,
                steps: &steps,
                observations: &observations,
                executedActionFingerprints: &executedActionFingerprints,
                continuation: continuation,
                stepIndex: stepIndex + 1
            )
        }
        if let immediate = ToolObservationFinalizer.immediateFinalIfSafe(
            intent: routing.intent,
            toolID: canonicalTool,
            observation: observation,
            originalPrompt: req.userMessage
        ) {
            recordTrace(
                slot: .executor,
                stage: "deterministic-immediate-final",
                stepIndex: stepIndex,
                error: "skippedMouthFinal=true;intent=\(routing.intent.rawValue);toolID=\(canonicalTool)",
                raw: immediate,
                prompt: req.userMessage
            )
            return .finalizeImmediate(immediate)
        }

        if shouldFinalizeAfterObservation(observation, routing: routing, toolID: canonicalTool) {
            return .finalizeNow(observation)
        }
        return .continueLoop
    }

    private func deterministicFollowUpAction(after toolID: String, observation: String, req: AgentRequest, routing: IntentRoutingDecision) -> AgentAction? {
        guard toolID == "contacts.search" else { return nil }
        guard let phone = firstPhoneNumber(in: observation) else { return nil }

        switch routing.intent {
        case .phoneCall:
            return AgentAction(tool: "phone.call", args: ["number": .string(phone)])
        case .messageDraft:
            return AgentAction(tool: "messages.draft", args: ["number": .string(phone), "body": .string(extractCommunicationBody(from: req.userMessage))])
        default:
            return nil
        }
    }

    

    


    private func generateFinal(req: AgentRequest, resolution: ReferenceResolution, routing: IntentRoutingDecision, observations: [String], draft: String?) async -> String {
        let prompt = makeMouthPrompt(req: req, resolution: resolution, observations: observations, draft: draft)
        let adaptiveCap = Self.adaptiveTokenCap(for: routing.intent, stage: .mouthFinal)
        let text = await generateText(
            slot: .mouth,
            req: req,
            userMessage: prompt,
            temperature: min(req.temperature, 0.35),
            topP: min(req.topP, 0.8),
            maxTokens: Self.cappedMaxTokens(req.maxTokens, stageCap: adaptiveCap),
            modelName: "mouth-final"
        )

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String
        if trimmed.isEmpty, let draft, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidate = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            candidate = trimmed
        }
        let maybeRetried = await retryIfOutputLooksThin(
            candidate: candidate,
            slot: .mouth,
            req: req,
            prompt: prompt,
            routing: routing,
            stage: .mouthFinal,
            baseCap: adaptiveCap
        )
        let validated = FinalIntentValidator.validate(maybeRetried, routing: routing, fallback: observations.last ?? draft)
        let enforced = enforceIntentSpecificFinalQuality(
            validated,
            routing: routing,
            resolution: resolution,
            observations: observations
        )
        return appendRichPayloadMarkersIfNeeded(to: enforced, from: observations + [draft ?? ""])
    }

    private func generateDirectFinal(req: AgentRequest, resolution: ReferenceResolution, routing: IntentRoutingDecision) async -> String {
        let contextBlock = compactPromptText(shortTermContextBlock(req.history), maxChars: PromptCharBudget.context)
        let ragGroundingRules: String = {
            let lower = resolution.rewrittenPrompt.lowercased()
            let isRAGLike = lower.contains("search my files") || lower.contains("architecture") || lower.contains("local files") || lower.contains("notes") || lower.contains("pdf")
            guard isRAGLike else { return "" }
            return """
        - For local file/RAG answers, explicitly cite retrieved evidence with markers like [1] tied to current observations.
        - If asked to summarize architecture/modules, include a short "Key modules" section grounded in retrieved snippets.
        - If no relevant observations were retrieved, state that clearly instead of restating the prompt.
        """
        }()
        let prompt = """
        You are Lumen. Answer naturally and helpfully. Do not output JSON.
        \(Self.mouthPromptHygieneRule)

        Recent safe conversation context for pronoun/reference resolution only:
        \(contextBlock)

        Original user request:
        \(resolution.originalPrompt)

        Interpreted request to answer:
        \(resolution.rewrittenPrompt)

        Additional grounding rules:
        \(ragGroundingRules)
        """
        let adaptiveCap = Self.adaptiveTokenCap(for: routing.intent, stage: .mouthDirect)
        let text = await generateText(slot: .mouth, req: req, userMessage: prompt, temperature: min(req.temperature, 0.35), topP: min(req.topP, 0.8), maxTokens: Self.cappedMaxTokens(req.maxTokens, stageCap: adaptiveCap), modelName: GenerationStage.mouthDirect.rawValue)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? "I’m here." : trimmed
        let maybeRetried = await retryIfOutputLooksThin(
            candidate: candidate,
            slot: .mouth,
            req: req,
            prompt: prompt,
            routing: routing,
            stage: .mouthDirect,
            baseCap: adaptiveCap
        )
        let validated = FinalIntentValidator.validate(maybeRetried, routing: routing, fallback: nil)
        return enforceIntentSpecificFinalQuality(
            validated,
            routing: routing,
            resolution: resolution,
            observations: []
        )
    }

    private func retryIfOutputLooksThin(
        candidate: String,
        slot: LumenModelSlot,
        req: AgentRequest,
        prompt: String,
        routing: IntentRoutingDecision,
        stage: GenerationStage,
        baseCap: Int
    ) async -> String {
        let text = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        let wordCount = text.split(whereSeparator: \.isWhitespace).count
        let needsMoreDepth = wordCount < RetryHeuristic.minWordCount && RetryHeuristic.intentsNeedingDepth.contains(routing.intent)
        let looksInvalid = text.isEmpty || lower == "none" || lower == "null" || lower == "undefined" || lower == "i’m here." || lower == "i'm here."
        guard looksInvalid || needsMoreDepth else { return candidate }
        let retryTargetCap = max(baseCap, baseCap + StageTokenBudget.retryBump)
        let retryCap = Self.cappedMaxTokens(retryTargetCap, stageCap: StageTokenBudget.retryCeiling)
        let retried = await generateText(
            slot: slot,
            req: req,
            userMessage: prompt,
            temperature: min(req.temperature, 0.35),
            topP: min(req.topP, 0.8),
            maxTokens: retryCap,
            modelName: "\(stage.rawValue)-retry"
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return retried.isEmpty ? candidate : retried
    }

    private func enforceIntentSpecificFinalQuality(
        _ text: String,
        routing: IntentRoutingDecision,
        resolution: ReferenceResolution,
        observations: [String]
    ) -> String {
        var output = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let promptLower = resolution.rewrittenPrompt.lowercased()

        switch routing.intent {
        case .emailDraft:
            let asksForClarifyingQuestion = promptLower.contains("clarifying question")
                || promptLower.contains("ask one question")
                || promptLower.contains("ask a question")
            let isIntentTokenOnly = output.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("emailDraft") == .orderedSame
            if isIntentTokenOnly {
                output = "I can draft it. Who should receive the email, and what key update should I include?"
            }
            if asksForClarifyingQuestion && !output.lowercased().contains("question") {
                if !output.isEmpty {
                    output += "\n\n"
                }
                output += "One clarifying question: what specific deadline, priority, or next step should I align this update with?"
            }
        case .memory:
            let asksForRecall = promptLower.contains("what you remembered")
                || promptLower.contains("what do you remember")
                || promptLower.contains("tell me what you remembered")
            if asksForRecall && !output.lowercased().contains("remember") {
                let remembered = rememberedPreferenceSnippet(from: observations, originalPrompt: resolution.originalPrompt)
                if !output.isEmpty {
                    output += "\n\n"
                }
                output += remembered.isEmpty ? "I remember your preference." : "I remember: \(remembered)"
            }
        default:
            break
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func rememberedPreferenceSnippet(from observations: [String], originalPrompt: String) -> String {
        for raw in observations.reversed() {
            let clean = WebRichContentPayload.removingMarkers(from: raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty { continue }
            if clean.lowercased().hasPrefix("saved:") {
                return String(clean.dropFirst("saved:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let lower = originalPrompt.lowercased()
        if let range = lower.range(of: "remember that ") {
            let start = originalPrompt.index(range.lowerBound, offsetBy: "remember that ".count)
            let remainder = String(originalPrompt[start...])
            if let end = remainder.lowercased().range(of: ", then")?.lowerBound {
                return String(remainder[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return ""
    }

    private func appendRichPayloadMarkersIfNeeded(to text: String, from sources: [String]) -> String {
        let existingKeys = Set(WebRichContentPayload.decodeAll(from: text).map(payloadKey))
        let payloads = sources.flatMap { WebRichContentPayload.decodeAll(from: $0) }
        guard !payloads.isEmpty else { return text }

        var seen = existingKeys
        var missingMarkers: [String] = []

        for payload in payloads {
            let key = payloadKey(payload)
            guard seen.insert(key).inserted else { continue }
            missingMarkers.append(payload.encodedMarker())
        }

        guard !missingMarkers.isEmpty else { return text }
        return text + missingMarkers.joined()
    }

    private func payloadKey(_ payload: WebRichContentPayload) -> String {
        switch payload.kind {
        case .searchResults:
            return "search:\(payload.query ?? ""):\(payload.results.map { $0.url ?? $0.title }.joined(separator: "|"))"
        case .fetchedPage:
            return "page:\(payload.page?.url ?? "")"
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

    private func makeStructuredTurnPrompt(req: AgentRequest, resolution: ReferenceResolution, observations: [String], stepIndex: Int, scopedTools: [ToolDefinition], mode: StructuredTurnMode) -> String {
        let tools = scopedTools.map { tool in "- \(tool.id): \(tool.description)" }.joined(separator: "\n")
        let observationRaw = prioritizedObservationBlock(from: observations, maxItems: 3)
        let observationBlock = compactPromptText(observationRaw, maxChars: PromptCharBudget.observations)
        let contextBlock = compactPromptText(shortTermContextBlock(req.history), maxChars: PromptCharBudget.context)
        let ragGroundingRules: String = {
            let lower = resolution.rewrittenPrompt.lowercased()
            let isRAGLike = lower.contains("search my files") || lower.contains("architecture") || lower.contains("local files") || lower.contains("notes") || lower.contains("pdf")
            guard isRAGLike else { return "" }
            return """
        - For local file/RAG answers, explicitly cite retrieved evidence with markers like [1] tied to current observations.
        - If asked to summarize architecture/modules, include a short "Key modules" section grounded in retrieved snippets.
        - If no relevant observations were retrieved, state that clearly instead of restating the prompt.
        """
        }()

        switch mode {
        case .actionOnly:
            return """
            You are Lumen Cortex orchestrator step \(stepIndex + 1). Return exactly one JSON object and no markdown.

            Recent safe conversation context for pronoun/reference resolution only:
            \(contextBlock)

            Original user request:
            \(resolution.originalPrompt)

            Rewritten execution request (source of truth):
            \(resolution.rewrittenPrompt)

            Previous observations for this current request only:
            \(observationBlock)

            Available tools:
            \(tools)

            Required output schema:
            {"thought":"short routing note","action":{"tool":"tool.id","args":{"key":"value"}}}

            Hard rules:
            - You are the planner/orchestrator for this request.
            - Output an action object only.
            - Use exactly one tool from Available tools.
            - Use recent context only to resolve words like he, she, her, him, it, that, them, previous, last.
            - Never reuse previous tool observations as current results.
            - Never call the same tool with the same arguments twice.
            - For phone calls to a person by name or pronoun, use contacts.search first unless a phone number is already explicit.
            - For Outlook/Hotmail inbox checks, prefer outlook.messages.list with unreadOnly=true when user asks unread.
            - For "read latest email", use outlook.message.read with {"message":"latest"}.
            - If the tool needs the user's current place, use location="current location".
            \(ragGroundingRules)
            """
        case .actionOrFinal:
            return """
            You are Lumen Cortex orchestrator step \(stepIndex + 1). Return exactly one JSON object and no markdown.

            Recent safe conversation context for pronoun/reference resolution only:
            \(contextBlock)

            Original user request:
            \(resolution.originalPrompt)

            Rewritten execution request (source of truth):
            \(resolution.rewrittenPrompt)

            Previous observations for this current request only:
            \(observationBlock)

            Available tools:
            \(tools)

            Required output schema (choose one):
            {"thought":"short routing note","action":{"tool":"tool.id","args":{"key":"value"}}}
            {"thought":"short completion note","final":"final answer draft grounded in observations"}

            Hard rules:
            - You are the planner/orchestrator for this request.
            - If there are no observations yet, output an action object only.
            - If observations exist, either output another action or output a grounded final draft for user delivery.
            - If you output action, use exactly one tool from Available tools.
            - If you output final, it must be grounded in Previous observations for this current request only.
            - Gather enough context before finalizing: prefer querying memory/rag/web context tools when relevant, and ask a clarification question if core details are missing.
            - For factual/current-events questions, prefer web search evidence before final.
            - For user-preference or prior-personal-context questions, prefer memory lookup before final.
            - For local knowledge/doc questions, prefer file/RAG tools before final.
            - Use recent context only to resolve words like he, she, her, him, it, that, them, previous, last.
            - Never reuse previous tool observations as current results.
            - Never call the same tool with the same arguments twice.
            - For phone calls to a person by name or pronoun, use contacts.search first unless a phone number is already explicit.
            - For Outlook/Hotmail inbox checks, prefer outlook.messages.list with unreadOnly=true when user asks unread.
            - For "read latest email", use outlook.message.read with {"message":"latest"}.
            - If the tool needs the user's current place, use location="current location".
            \(ragGroundingRules)
            """
        }
    }

    private func clarificationPromptForMissingContext(routing: IntentRoutingDecision, resolution: ReferenceResolution) -> String {
        let intentHint: String
        switch routing.intent {
        case .weather: intentHint = "location and timeframe"
        case .webSearch, .rag, .files: intentHint = "topic scope and preferred sources"
        case .maps: intentHint = "destination and travel context"
        case .phoneCall, .messageDraft, .emailDraft, .outlook: intentHint = "recipient and the intended action"
        case .calendar, .reminder, .trigger, .alarm: intentHint = "time and completion criteria"
        case .memory, .note: intentHint = "which memory or note context to use"
        default: intentHint = "the key missing detail needed to proceed"
        }
        let scopedRequest = resolution.rewrittenPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestSnippet = scopedRequest.isEmpty ? "" : " for this request (\(scopedRequest.prefix(80)))"
        return "Before I finalize, could you clarify the \(intentHint)\(requestSnippet)?"
    }


    private enum PromptCharBudget {
        static let context = 420
        static let observations = 1400
        static let draft = 500
    }

    private func compactPromptText(_ text: String, maxChars: Int) -> String {
        let flattened = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > maxChars else { return flattened }
        let prefix = flattened.prefix(max(0, maxChars - 14))
        return "\(prefix)… [truncated]"
    }

    private func prioritizedObservationBlock(from observations: [String], maxItems: Int) -> String {
        guard !observations.isEmpty else { return "none" }
        let normalized = observations
            .map(WebRichContentPayload.removingMarkers)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalized.isEmpty else { return "none" }
        let indexed = normalized.enumerated().map { (index: $0.offset, text: $0.element) }
        let sorted = indexed.sorted {
            let leftPriority = observationPriority($0.text)
            let rightPriority = observationPriority($1.text)
            if leftPriority != rightPriority { return leftPriority > rightPriority }
            return $0.index > $1.index
        }
        let selected = sorted.prefix(maxItems).map(\.text)
        return selected.joined(separator: "\n")
    }

    private func observationPriority(_ text: String) -> Int {
        let lower = text.lowercased()
        if lower.contains("error") || lower.contains("denied") || lower.contains("unavailable") { return 4 }
        if lower.contains("search results") || lower.contains("result") || lower.contains("http") { return 3 }
        if lower.contains("saved") || lower.contains("remember") || lower.contains("contact") { return 2 }
        return 1
    }

    private func makeMouthPrompt(req: AgentRequest, resolution: ReferenceResolution, observations: [String], draft: String?) -> String {
        let observationRaw = prioritizedObservationBlock(from: observations, maxItems: 4)
        let observationBlock = compactPromptText(observationRaw, maxChars: PromptCharBudget.observations)
        let draftBlockRaw = draft?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? draft! : "none"
        let draftBlock = compactPromptText(WebRichContentPayload.removingMarkers(from: draftBlockRaw), maxChars: PromptCharBudget.draft)
        let contextBlock = compactPromptText(shortTermContextBlock(req.history), maxChars: PromptCharBudget.context)
        let ragGroundingRules: String = {
            let lower = resolution.rewrittenPrompt.lowercased()
            let isRAGLike = lower.contains("search my files") || lower.contains("architecture") || lower.contains("local files") || lower.contains("notes") || lower.contains("pdf")
            guard isRAGLike else { return "" }
            return """
        - For local file/RAG answers, explicitly cite retrieved evidence with markers like [1] tied to current observations.
        - If asked to summarize architecture/modules, include a short "Key modules" section grounded in retrieved snippets.
        - If no relevant observations were retrieved, state that clearly instead of restating the prompt.
        """
        }()
        return """
        Write the final user-facing answer for the current user request only. Do not output JSON.
        \(Self.mouthPromptHygieneRule)

        Recent safe conversation context for pronoun/reference resolution only:
        \(contextBlock)

        Original user request:
        \(resolution.originalPrompt)

        Rewritten execution request (source of truth):
        \(resolution.rewrittenPrompt)

        Reference resolution diagnostics:
        confidence=\(String(format: "%.2f", resolution.confidence)); map=\(resolution.resolvedReferences); notes=\(resolution.diagnostics)

        Current request tool observations:
        \(observationBlock)

        Draft final from the current request:
        \(draftBlock)

        Rules:
        - Current request observations are the source of truth.
        - Use recent context only to resolve references like her/him/it/that.
        - Never reuse a result from a previous user request as a current tool result.
        - Do not mention calendar, events, reminders, weather, email, or web search unless it belongs to this current request.
        - Keep it concise, accurate, and do not claim actions that did not happen.
        \(ragGroundingRules)
        """
    }

    private enum StructuredTurnMode: String {
        case actionOnly
        case actionOrFinal
    }

    private func boundedMaxSteps(for routing: IntentRoutingDecision, requested: Int) -> Int {
        let hardCap: Int
        switch routing.intent {
        case .weather, .webSearch, .maps, .photos, .camera, .health, .motion, .files, .memory, .rag, .contactSearch:
            hardCap = 2
        case .emailDraft, .messageDraft, .phoneCall, .calendar, .reminder, .trigger, .alarm, .note, .outlook:
            hardCap = 4
        case .chat, .unknown:
            hardCap = 1
        }
        return max(1, min(requested, hardCap))
    }

    private func shouldFinalizeAfterObservation(_ observation: String, routing: IntentRoutingDecision, toolID: String) -> Bool {
        let text = WebRichContentPayload.removingMarkers(from: observation).trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        guard !text.isEmpty else { return false }

        if lower.contains("requires explicit user approval") { return true }
        if lower.contains("unavailable") || lower.contains("not available") || lower.contains("denied") { return true }
        if lower.contains("no direct answer") || lower.contains("try a different phrasing") { return true }

        switch routing.intent {
        case .weather:
            return lower.contains("weather") || lower.contains("temperature") || lower.contains("humidity") || lower.contains("feels like") || lower.contains("°c")
        case .webSearch:
            return lower.contains("http") || lower.contains("result") || lower.contains("source") || lower.contains("search results") || lower.contains("no direct answer")
        case .maps:
            return lower.contains("map") || lower.contains("direction") || lower.contains("near") || lower.contains("location") || lower.contains("opening maps")
        case .photos:
            return lower.contains("photo") || lower.contains("image") || lower.contains("library")
        case .camera:
            return lower.contains("camera") || lower.contains("captured") || lower.contains("photo")
        case .health:
            return lower.contains("health") || lower.contains("steps") || lower.contains("sleep") || lower.contains("heart")
        case .motion:
            return lower.contains("motion") || lower.contains("activity") || lower.contains("walking") || lower.contains("running")
        case .files:
            return lower.contains("file") || lower.contains("document") || lower.contains("read")
        case .memory, .note:
            return lower.contains("memory") || lower.contains("remember") || lower.contains("saved") || lower.contains("recall")
        case .rag:
            return lower.contains("search") || lower.contains("index") || lower.contains("file") || lower.contains("photo")
        case .contactSearch:
            return lower.contains("contact") || lower.contains("phone") || lower.contains("email") || lower.contains("found")
        case .phoneCall:
            return toolID == "phone.call"
        case .messageDraft:
            return toolID == "messages.draft"
        case .emailDraft:
            return toolID == "mail.draft"
        case .outlook:
            return toolID.hasPrefix("outlook.")
        case .calendar, .reminder, .trigger, .alarm:
            return true
        case .chat, .unknown:
            return false
        }
    }

    private func firstPhoneNumber(in text: String) -> String? {
        let pattern = #"\+?[0-9][0-9\s\-\(\)]{6,}[0-9]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return ns.substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractCommunicationBody(from text: String) -> String {
        let lower = text.lowercased()
        for marker in [" saying ", " that says ", " message "] {
            if let range = lower.range(of: marker) {
                return String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return ""
    }

    nonisolated static func shared_extractWebQuery(_ text: String) -> String {
        var query = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let leadingMarkers = [
            "search web for", "search the web for", "search on web for", "search for",
            "look up", "find online", "research", "fetch information on", "fetch info on",
            "fetch information about", "fetch info about", "find information on", "find info on"
        ]

        let politePrefixes = ["please ", "can you ", "could you ", "would you ", "kindly "]
        var anchoredQuery = query
        var didStripPrefix = true
        while didStripPrefix {
            didStripPrefix = false
            let lowerAnchored = anchoredQuery.lowercased()
            for prefix in politePrefixes where lowerAnchored.hasPrefix(prefix) {
                anchoredQuery = String(anchoredQuery.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                didStripPrefix = true
                break
            }
        }

        for marker in leadingMarkers where anchoredQuery.lowercased().hasPrefix(marker) {
            anchoredQuery = String(anchoredQuery.dropFirst(marker.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            query = anchoredQuery
            break
        }
        query = anchoredQuery

        let trailingPhrases = [" on web", " on the web", " from the web", " on internet", " on the internet", " online"]
        query = query.trimmingCharacters(in: CharacterSet(charactersIn: "\"' .,!?"))
        for phrase in trailingPhrases where query.lowercased().hasSuffix(phrase) {
            query = String(query.dropLast(phrase.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        query = query.replacingOccurrences(of: #"^about\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
        return query.trimmingCharacters(in: CharacterSet(charactersIn: "\"' .,!?"))
    }

    nonisolated static func shared_extractOutlookSearchQuery(_ text: String) -> String {
        var query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "search outlook for", "search hotmail for", "search email for", "search emails for", "search mail for",
            "find outlook", "find email", "find emails", "look for email", "look for emails", "email about", "mail about"
        ]
        let lower = query.lowercased()
        for prefix in prefixes where lower.contains(prefix) {
            if let range = lower.range(of: prefix) {
                query = String(query[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        query = query.replacingOccurrences(of: "outlook", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "hotmail", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: #"(?i)\bemails?\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bmails?\b"#, with: "", options: .regularExpression)
        return query.trimmingCharacters(in: CharacterSet(charactersIn: "\"' .,!?"))
    }

    nonisolated static func shared_extractOutlookMessageReference(_ text: String) -> String? {
        let refs = ["latest", "last", "first", "second", "third", "fourth", "fifth", "this", "that", "selected", "current"]
        for ref in refs where text.contains(ref) { return ref }
        let pattern = #"#?\b([1-9]|10)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return ns.substring(with: match.range).replacingOccurrences(of: "#", with: "")
    }

    private func extractOutlookDestinationFolder(from text: String) -> String? {
        if text.contains("junk") || text.contains("spam") { return "junkemail" }
        if text.contains("trash") || text.contains("deleted") { return "deleteditems" }
        if text.contains("archive") { return "archive" }
        if text.contains("inbox") { return "inbox" }
        if text.contains("sent") { return "sentitems" }
        if text.contains("draft") { return "drafts" }
        return nil
    }

    private func extractOutlookSubject(from text: String) -> String {
        let lower = text.lowercased()
        for marker in [" subject ", " subject:"] {
            if let range = lower.range(of: marker) {
                let remainder = String(text[range.upperBound...])
                if let bodyRange = remainder.lowercased().range(of: " body ") {
                    return String(remainder[..<bodyRange.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: "\"' :.,!?"))
                }
                return remainder.trimmingCharacters(in: CharacterSet(charactersIn: "\"' :.,!?"))
            }
        }
        return ""
    }

    nonisolated static func shared_extractOutlookBody(_ text: String) -> String {
        let lower = text.lowercased()
        for marker in [" saying ", " that says ", " body ", " body:", " message ", " comment ", " reply "] {
            if let range = lower.range(of: marker) {
                return String(text[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\"' :.,!?"))
            }
        }
        return ""
    }

    private func extractEmailAddress(from text: String) -> String? {
        let pattern = #"[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return ns.substring(with: match.range)
    }

    nonisolated static func shared_firstURL(_ text: String) -> String? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = detector.firstMatch(in: text, options: [], range: range),
              let url = match.url else { return nil }
        return url.absoluteString
    }

    nonisolated static func sanitizeHistoryEntryForPromptContext(role: MessageRole, content: String, maxChars: Int = 500) -> String? {
        let sanitized = FinalOutputSanitizer.sanitizeUserVisibleText(content)
        var clean = sanitized.text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !clean.isEmpty else { return nil }
        if role == .assistant && sanitized.removedArtifacts.contains(.emptyAfterSanitization) {
            return nil
        }

        let lower = clean.lowercased()
        let blockedMarkers = [
            "<think",
            "</think>",
            "<lumen_web_payload",
            "searchresults",
            "emptyaftersanitization",
            "\"kind\":\"searchresults\"",
            "\"kind\" : \"searchresults\"",
            "\"sourcepageurl\"",
            "\"mediakind\":\"page\""
        ]
        if blockedMarkers.contains(where: { lower.contains($0) }) {
            return nil
        }

        clean = WebRichContentPayload.removingMarkers(from: clean)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !clean.isEmpty else { return nil }
        return String(clean.prefix(maxChars))
    }

    private func shortTermContextBlock(_ history: [(role: MessageRole, content: String)]) -> String {
        guard !history.isEmpty else { return "none" }
        let lines = history.suffix(4).compactMap { item -> String? in
            guard item.role == .user || item.role == .assistant else { return nil }
            guard let clean = Self.sanitizeHistoryEntryForPromptContext(role: item.role, content: item.content) else { return nil }
            let role = item.role == .assistant ? "assistant" : "user"
            return "- \(role): \(clean)"
        }
        return lines.isEmpty ? "none" : lines.joined(separator: "\n")
    }

    private func actionFingerprint(toolID: String, arguments: [String: String]) -> String {
        let args = arguments
            .map { key, value in "\(key.lowercased())=\(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())" }
            .sorted()
            .joined(separator: "&")
        return "\(toolID.lowercased())?\(args)"
    }

    nonisolated static func isActionAllowed(_ toolID: String, routing: IntentRoutingDecision) -> Bool {
        IntentRouter.isToolAllowed(toolID, for: routing)
    }

    nonisolated static func resolveRequiredToolFallback(intent: UserIntent, prompt: String, allowedToolIDs: [String]) -> String? {
        let allowed = Set(allowedToolIDs.map { ToolRouteGuard.canonicalToolID($0) })
        guard !allowed.isEmpty else { return nil }
        if allowed.count == 1 { return allowed.first }

        let lower = prompt.lowercased()
        func pick(_ toolID: String) -> String? { allowed.contains(toolID) ? toolID : nil }

        switch intent {
        case .camera:
            if ["camera", "photo", "picture", "capture", "take"].contains(where: lower.contains) {
                return pick("camera.capture")
            }
        case .maps:
            if ["where are we", "where am i", "current location", "my location"].contains(where: lower.contains) {
                return pick("location.current")
            }
            if lower.contains("show me on map") { return pick("location.current") ?? pick("maps.search") }
            if ["directions", "navigate", "route"].contains(where: lower.contains) { return pick("maps.directions") }
            if ["nearby", "find", "search", "hardware store", "restaurant"].contains(where: lower.contains) { return pick("maps.search") }
        case .outlook:
            if ["auth", "status", "sign in", "signin", "log in", "login"].contains(where: lower.contains) {
                return pick("outlook.status")
            }
            if ["unread", "new emails", "latest email", "check email", "read email", "outlook email"].contains(where: lower.contains) {
                return pick("outlook.messages.list") ?? pick("outlook.message.read")
            }
        default:
            break
        }

        if intent == .maps { return pick("location.current") ?? pick("maps.search") ?? pick("maps.directions") }
        if intent == .outlook { return pick("outlook.messages.list") ?? pick("outlook.status") }
        return nil
    }

    nonisolated static func requiredTools(for intent: UserIntent) -> Set<String> {
        switch intent {
        case .memory:
            return ["memory.save", "memory.recall"]
        default:
            return []
        }
    }

    nonisolated static func deterministicPrimaryAction(
        routing: IntentRoutingDecision,
        prompt: String,
        scopedTools: [ToolDefinition],
        availableToolIDs: Set<String>
    ) -> AgentAction? {
        guard IntentRouter.intentRequiresTool(routing) else { return nil }
        guard let planned = DeterministicToolPlanner.plan(
            routing: routing,
            prompt: prompt,
            availableToolIDs: availableToolIDs
        ) else {
            return nil
        }
        let canonicalTool = ToolRouteGuard.canonicalToolID(planned.tool)
        guard scopedTools.contains(where: { ToolRouteGuard.canonicalToolID($0.id) == canonicalTool }) else { return nil }
        guard Self.isActionAllowed(canonicalTool, routing: routing) else { return nil }
        let normalizedArgs = ToolRouteGuard.normalizedArguments(for: canonicalTool, rawToolID: planned.tool, arguments: planned.args.stringCoerced)
        let normalizationPassed = normalizedArgs.values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } || normalizedArgs.isEmpty
        guard normalizationPassed else { return nil }
        return AgentAction(tool: canonicalTool, args: AgentJSONArguments(stringDictionary: normalizedArgs))
    }

    private func recordPolicyDiagnostics(selectedTool: String?, allowedForIntent: Set<String>, policyViolation: Bool, replanned: Bool, prompt: String) {
        SlotAgentDiagnosticsRecorder.recordPolicy(
            SlotAgentPolicyTrace(
                id: UUID(),
                createdAt: Date(),
                selectedTool: selectedTool,
                allowedForIntent: allowedForIntent.sorted(),
                policyViolation: policyViolation,
                replanned: replanned,
                userPromptPrefix: String(prompt.prefix(2_000))
            )
        )
    }

    private func yieldFinal(_ text: String, steps: [AgentStep], continuation: AsyncStream<AgentEvent>.Continuation) {
        let sanitizedFinal = FinalOutputSanitizer.sanitizeUserVisibleText(text).text
        for chunk in chunk(sanitizedFinal) {
            continuation.yield(.finalDelta(chunk))
        }
        continuation.yield(.done(finalText: sanitizedFinal, steps: steps))
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

nonisolated struct SlotAgentPolicyTrace: Codable, Sendable {
    let id: UUID
    let createdAt: Date
    let selectedTool: String?
    let allowedForIntent: [String]
    let policyViolation: Bool
    let replanned: Bool
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

    static func recordPolicy(_ trace: SlotAgentPolicyTrace) {
        do {
            let directory = try diagnosticsDirectory()
            let url = directory.appendingPathComponent("slot-agent-policy.jsonl", isDirectory: false)
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
        }
    }

    static func diagnosticsDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("Diagnostics", isDirectory: true).appendingPathComponent("SlotAgent", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
