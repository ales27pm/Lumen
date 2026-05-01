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
                let requiresTool = IntentRouter.intentRequiresTool(routing)

                if routing.requiresClarification {
                    let clarification = routing.clarificationPrompt ?? "Could you clarify what you want me to do?"
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
                if let mapFollowUp = deterministicMapFollowUpAction(
                    routing: routing,
                    prompt: executionPrompt,
                    conversationID: req.conversationID,
                    availableToolIDs: availableToolIDs
                ) {
                    let result = await executeAction(
                        mapFollowUp,
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
                        finalText = await generateFinal(req: req, resolution: resolution, routing: routing, observations: observations, draft: observations.last)
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

                if let deterministic = DeterministicToolPlanner.plan(routing: routing, prompt: executionPrompt, availableToolIDs: availableToolIDs) {
                    let result = await executeAction(
                        deterministic,
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
                        finalText = await generateFinal(req: req, resolution: resolution, routing: routing, observations: observations, draft: observations.last)
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

                let maxSteps = boundedMaxSteps(for: routing, requested: req.maxSteps)
                for stepIndex in 0..<maxSteps {
                    let hasObservation = !observations.isEmpty
                    let structuredMode = structuredModeForTurn(requiresTool: requiresTool, hasObservation: hasObservation)
                    let slot: LumenModelSlot = structuredMode == .finalOnly ? .mouth : (stepIndex == 0 ? .cortex : .executor)
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
                        temperature: structuredMode == .finalOnly ? min(req.temperature, 0.35) : 0.0,
                        topP: structuredMode == .finalOnly ? min(req.topP, 0.8) : 0.05,
                        maxTokens: min(req.maxTokens, structuredMode == .actionOnly ? 180 : 260),
                        modelName: structuredMode == .finalOnly ? "mouth-final-json" : "executor-action-json"
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

                    if structuredMode == .actionOnly, let final = parsed.final, !final.isEmpty {
                        recordTrace(slot: slot, stage: "structured-turn-action-only", stepIndex: stepIndex, error: "unexpected_final_in_action_turn", raw: turnOutput, prompt: executionPrompt)
                        finalText = await generateFinal(req: req, resolution: resolution, routing: routing, observations: observations, draft: nil)
                        yieldFinal(finalText, steps: steps, continuation: continuation)
                        return
                    }

                    if let final = parsed.final, !final.isEmpty {
                        finalText = FinalIntentValidator.validate(final, routing: routing, fallback: observations.last)
                        finalText = appendRichPayloadMarkersIfNeeded(to: finalText, from: observations)
                        yieldFinal(finalText, steps: steps, continuation: continuation)
                        return
                    }

                    if structuredMode == .finalOnly {
                        finalText = await generateFinal(req: req, resolution: resolution, routing: routing, observations: observations, draft: observations.last ?? turnOutput)
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

        let actionStep = AgentStep(kind: .action, content: action.displayContent, toolID: canonicalTool, toolArgs: normalizedArgs)
        steps.append(actionStep)
        continuation.yield(.step(actionStep))

        guard SlotAgentService.isActionAllowed(canonicalTool, routing: routing) else {
            recordTrace(slot: .executor, stage: "tool-execution", stepIndex: stepIndex, error: "tool_not_allowed_for_intent", raw: action.displayContent, prompt: req.userMessage)
            return .blocked(IntentRouter.blockedToolMessage(for: routing))
        }

        executedActionFingerprints.insert(fingerprint)
        let observation = await ToolExecutor.shared.execute(
            canonicalTool,
            arguments: normalizedArgs,
            approval: approvalForExplicitUserIntent(toolID: canonicalTool, routing: routing)
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

    

    


    private func deterministicMapFollowUpAction(
        routing: IntentRoutingDecision,
        prompt: String,
        conversationID: UUID?,
        availableToolIDs: Set<String>
    ) -> AgentAction? {
        guard routing.intent == .maps else { return nil }
        let text = prompt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let followUps = ["show me on map", "show it on map", "open it in maps", "open on map", "show this location on map", "navigate there", "directions there", "take me there", "show it"]
        guard followUps.contains(where: { text.contains($0) }) else { return nil }

        let recentEntries = ToolLedger.shared.shortTermEntries(conversationID: conversationID).reversed()
        guard let entry = recentEntries.first(where: { $0.toolID == "location.current" }) else { return nil }
        guard let coords = LocationReferenceExtractor.coordinates(from: entry.result) else { return nil }
        let coordinateString = String(format: "%.4f,%.4f", coords.latitude, coords.longitude)

        if availableToolIDs.contains("maps.directions") {
            return AgentAction(tool: "maps.directions", args: ["destination": .string(coordinateString)])
        }
        if availableToolIDs.contains("maps.search") {
            return AgentAction(tool: "maps.search", args: ["query": .string(coordinateString)])
        }
        return nil
    }

    private func approvalForExplicitUserIntent(toolID: String, routing: IntentRoutingDecision) -> ToolExecutionApproval {
        switch (routing.intent, toolID) {
        case (.phoneCall, "phone.call"), (.messageDraft, "messages.draft"), (.emailDraft, "mail.draft"):
            return .userApproved
        case (.outlook, "outlook.draft.create"),
             (.outlook, "outlook.mail.send"),
             (.outlook, "outlook.message.mark_read"),
             (.outlook, "outlook.message.mark_unread"),
             (.outlook, "outlook.message.move"),
             (.outlook, "outlook.message.archive"),
             (.outlook, "outlook.message.delete"),
             (.outlook, "outlook.message.reply"),
             (.outlook, "outlook.message.reply_all"),
             (.outlook, "outlook.message.forward"):
            return .userApproved
        default:
            return .autonomous
        }
    }

    private func generateFinal(req: AgentRequest, resolution: ReferenceResolution, routing: IntentRoutingDecision, observations: [String], draft: String?) async -> String {
        let prompt = makeMouthPrompt(req: req, resolution: resolution, observations: observations, draft: draft)
        let text = await generateText(
            slot: .mouth,
            req: req,
            userMessage: prompt,
            temperature: min(req.temperature, 0.35),
            topP: min(req.topP, 0.8),
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
        let validated = FinalIntentValidator.validate(candidate, routing: routing, fallback: observations.last ?? draft)
        return appendRichPayloadMarkersIfNeeded(to: validated, from: observations + [draft ?? ""])
    }

    private func generateDirectFinal(req: AgentRequest, resolution: ReferenceResolution, routing: IntentRoutingDecision) async -> String {
        let contextBlock = shortTermContextBlock(req.history)
        let prompt = """
        You are Lumen. Answer naturally and helpfully. Do not output JSON.

        Recent safe conversation context for pronoun/reference resolution only:
        \(contextBlock)

        Original user request:
        \(resolution.originalPrompt)

        Interpreted request to answer:
        \(resolution.rewrittenPrompt)
        """
        let text = await generateText(slot: .mouth, req: req, userMessage: prompt, temperature: min(req.temperature, 0.35), topP: min(req.topP, 0.8), maxTokens: req.maxTokens, modelName: "mouth-direct")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? "I’m here." : trimmed
        return FinalIntentValidator.validate(candidate, routing: routing, fallback: nil)
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

    private func makeStructuredTurnPrompt(req: AgentRequest, resolution: ReferenceResolution, observations: [String], stepIndex: Int, scopedTools: [ToolDefinition], mode: StructuredTurnMode) -> String {
        let tools = scopedTools.map { tool in "- \(tool.id): \(tool.description)" }.joined(separator: "\n")
        let observationBlock = observations.isEmpty ? "none" : observations.map(WebRichContentPayload.removingMarkers).joined(separator: "\n")
        let contextBlock = shortTermContextBlock(req.history)

        switch mode {
        case .actionOnly:
            return """
            You are Lumen v1 tool router step \(stepIndex + 1). Return exactly one JSON object and no markdown.

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
            - Output an action object only.
            - Do not output final, answer, final_answer, prose, markdown, code fences, or explanations.
            - Use exactly one tool from Available tools.
            - Use recent context only to resolve words like he, she, her, him, it, that, them, previous, last.
            - Never reuse previous tool observations as current results.
            - Never call the same tool with the same arguments twice.
            - For phone calls to a person by name or pronoun, use contacts.search first unless a phone number is already explicit.
            - For Outlook/Hotmail inbox checks, prefer outlook.messages.list with unreadOnly=true when user asks unread.
            - For "read latest email", use outlook.message.read with {"message":"latest"}.
            - If the tool needs the user's current place, use location="current location".
            """
        case .finalOnly:
            return """
            You are Lumen v1 finalizer step \(stepIndex + 1). Return exactly one JSON object and no markdown.

            Recent safe conversation context for pronoun/reference resolution only:
            \(contextBlock)

            Original user request:
            \(resolution.originalPrompt)

            Rewritten execution request (source of truth):
            \(resolution.rewrittenPrompt)

            Current request observations:
            \(observationBlock)

            Required output schema:
            {"thought":"short finalization note","final":"answer shown to the user"}

            Hard rules:
            - Output a final object only.
            - Do not output action, tool, args, markdown, code fences, or explanations outside JSON.
            - Use current request observations as the source of truth.
            - Use recent context only to resolve references, not as a fresh tool result.
            - Never claim an action that is not in the observations.
            """
        case .directFinal:
            return """
            You are Lumen v1 direct answer step \(stepIndex + 1). Return exactly one JSON object and no markdown.

            Recent safe conversation context:
            \(contextBlock)

            Original user request:
            \(resolution.originalPrompt)

            Rewritten execution request (source of truth):
            \(resolution.rewrittenPrompt)

            Required output schema:
            {"thought":"short answer note","final":"answer shown to the user"}

            Hard rules:
            - Output a final object only.
            - Do not output action, tool, args, markdown, code fences, or explanations outside JSON.
            - Do not invent tool results.
            """
        }
    }

    private func makeMouthPrompt(req: AgentRequest, resolution: ReferenceResolution, observations: [String], draft: String?) -> String {
        let observationBlock = observations.isEmpty ? "none" : observations.map(WebRichContentPayload.removingMarkers).joined(separator: "\n")
        let draftBlockRaw = draft?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? draft! : "none"
        let draftBlock = WebRichContentPayload.removingMarkers(from: draftBlockRaw)
        let contextBlock = shortTermContextBlock(req.history)
        return """
        Write the final user-facing answer for the current user request only. Do not output JSON.

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
        """
    }

    private enum StructuredTurnMode: String {
        case actionOnly
        case finalOnly
        case directFinal
    }

    private func structuredModeForTurn(requiresTool: Bool, hasObservation: Bool) -> StructuredTurnMode {
        if hasObservation { return .finalOnly }
        return requiresTool ? .actionOnly : .directFinal
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

    private func shortTermContextBlock(_ history: [(role: MessageRole, content: String)]) -> String {
        guard !history.isEmpty else { return "none" }
        return history.suffix(4).map { item in
            let role: String
            switch item.role {
            case .user: role = "user"
            case .assistant: role = "assistant"
            case .tool: role = "tool"
            case .system: role = "system"
            }
            let clean = AssistantOutputSanitizer.sanitize(item.content)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "- \(role): \(String(clean.prefix(500)))"
        }.joined(separator: "\n")
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
