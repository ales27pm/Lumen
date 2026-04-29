import Foundation

@MainActor
final class AgentModelBehaviorAuditor {
    init() {}

    func audit(manifest: AgentBehaviorManifest, messages: [ChatMessage], limit: Int = 80) -> AgentBehaviorAuditReport {
        let ordered = messages.sorted { $0.createdAt < $1.createdAt }
        let boundedLimit = max(0, limit)
        let startIndex = max(0, ordered.count - boundedLimit)
        let toolsByID = Dictionary(manifest.tools.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let toolsByCanonicalID = Dictionary(manifest.tools.map { (ToolRouteGuard.canonicalToolID($0.id), $0) }, uniquingKeysWith: { first, _ in first })
        let manifestAllowedByIntent = allowedToolsByIntent(manifest).mapValues { Set($0.map(ToolRouteGuard.canonicalToolID)) }
        let forbiddenSentinels = Set(manifest.sentinels.forbiddenInUserOutput)
        var violations: [AgentBehaviorViolation] = []
        var auditedTraceCount = 0

        for index in startIndex..<ordered.count {
            let message = ordered[index]
            guard message.messageRole == .assistant else { continue }
            let prompt = previousUserPrompt(before: index, in: ordered) ?? ""
            let routing = IntentRouter.classify(prompt)
            let expectedIntent = routing.intent.rawValue
            let expectedManifestTools = manifestAllowedByIntent[expectedIntent] ?? []
            let runtimeAllowedTools = routing.allowedToolIDs
            let actionSteps = message.agentSteps.filter { $0.kind == .action }
            let visibleFinal = AssistantOutputSanitizer.sanitize(message.content)
            auditedTraceCount += 1

            if containsSentinel(visibleFinal, sentinels: forbiddenSentinels) {
                violations.append(violation(
                    severity: .critical,
                    code: "final_sentinel_leak",
                    agent: "mouth",
                    expected: "No static-analysis forbidden sentinel in user-visible final text.",
                    actual: visibleFinal,
                    prompt: prompt,
                    problem: "Mouth/final answer leaked a manifest-forbidden internal marker."
                ))
            }

            for step in message.agentSteps where containsSentinel(step.content, sentinels: forbiddenSentinels) {
                violations.append(violation(
                    severity: .error,
                    code: "agent_step_sentinel_leak",
                    agent: step.kind == .action ? "executor" : "cortex",
                    expected: "No forbidden sentinel in visible agent steps.",
                    actual: step.content,
                    prompt: prompt,
                    problem: "A persisted reasoning/action/observation step contains a static-analysis forbidden marker."
                ))
            }

            let manifestSaysToolExpected = !expectedManifestTools.isEmpty && routing.intent != .chat && routing.intent != .unknown
            if manifestSaysToolExpected && actionSteps.isEmpty && !routing.requiresClarification {
                violations.append(violation(
                    severity: .error,
                    code: "missing_required_tool_action",
                    agent: "cortex",
                    expected: "Intent \(expectedIntent) should select one of: \(expectedManifestTools.sorted().joined(separator: ", "))",
                    actual: "No action step was persisted.",
                    prompt: prompt,
                    problem: "The model produced no tool action even though the static manifest/runtime router expects a tool-backed intent."
                ))
            }

            if routing.intent == .chat && !actionSteps.isEmpty {
                violations.append(violation(
                    severity: .critical,
                    code: "tool_used_for_chat_intent",
                    agent: "cortex",
                    expected: "Chat intent should answer directly with no tool action.",
                    actual: actionSteps.compactMap(\.toolID).joined(separator: ", "),
                    prompt: prompt,
                    problem: "The model selected tools for a prompt classified as normal chat."
                ))
            }

            for action in actionSteps {
                guard let selectedToolID = action.toolID ?? action.toolArgs?["tool"] else {
                    violations.append(violation(
                        severity: .critical,
                        code: "action_missing_tool_id",
                        agent: "executor",
                        expected: "Action step must include a manifest tool ID.",
                        actual: action.content,
                        prompt: prompt,
                        problem: "Executor emitted or persisted an action without a tool ID."
                    ))
                    continue
                }

                let canonicalToolID = ToolRouteGuard.canonicalToolID(selectedToolID)

                guard let tool = toolsByID[selectedToolID] ?? toolsByCanonicalID[canonicalToolID] else {
                    violations.append(violation(
                        severity: .critical,
                        code: "unknown_tool_id",
                        agent: "executor",
                        expected: "Known manifest tool IDs: \(toolsByID.keys.sorted().joined(separator: ", "))",
                        actual: selectedToolID,
                        prompt: prompt,
                        problem: "Executor selected a tool ID absent from the static code-analysis manifest."
                    ))
                    continue
                }

                if !expectedManifestTools.isEmpty && !expectedManifestTools.contains(canonicalToolID) {
                    violations.append(violation(
                        severity: .critical,
                        code: "tool_not_allowed_by_static_manifest",
                        agent: "cortex",
                        expected: "Intent \(expectedIntent) allows: \(expectedManifestTools.sorted().joined(separator: ", "))",
                        actual: selectedToolID,
                        prompt: prompt,
                        problem: "Cortex/Executor selected a tool outside the static manifest routing matrix."
                    ))
                }

                if !runtimeAllowedTools.isEmpty && !runtimeAllowedTools.contains(canonicalToolID) {
                    violations.append(violation(
                        severity: .critical,
                        code: "tool_not_allowed_by_runtime_router",
                        agent: "cortex",
                        expected: "Runtime router allows: \(runtimeAllowedTools.sorted().joined(separator: ", "))",
                        actual: selectedToolID,
                        prompt: prompt,
                        problem: "Cortex/Executor selected a tool outside the live IntentRouter decision."
                    ))
                }

                let providedArgs = action.toolArgs ?? [:]
                for arg in tool.arguments where arg.required {
                    if providedArgs[arg.name]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                        violations.append(violation(
                            severity: .error,
                            code: "missing_required_tool_argument",
                            agent: "executor",
                            expected: "\(tool.id).\(arg.name): \(arg.type), required=true",
                            actual: providedArgs.keys.sorted().joined(separator: ", "),
                            prompt: prompt,
                            problem: "Executor omitted a required argument from the static manifest schema."
                        ))
                    }
                }

                if tool.requiresApproval && !isObviouslyUserInitiatedWrite(prompt: prompt, toolID: tool.id) {
                    violations.append(violation(
                        severity: .warning,
                        code: "approval_sensitive_tool_selected",
                        agent: "executor",
                        expected: "Tool \(tool.id) requires an approval boundary unless the request is explicitly user-initiated.",
                        actual: action.content,
                        prompt: prompt,
                        problem: "A requiresApproval tool was selected. Verify that the approval boundary was respected."
                    ))
                }
            }
        }

        let weightedPenalty = violations.reduce(0.0) { $0 + $1.severity.weight }
        let denominator = max(1.0, Double(auditedTraceCount) * 2.0)
        let score = max(0.0, min(1.0, 1.0 - weightedPenalty / denominator))

        return AgentBehaviorAuditReport(
            passed: violations.allSatisfy { $0.severity == .warning },
            score: score,
            generatedAt: Date(),
            traceCount: auditedTraceCount,
            violationCount: violations.count,
            sourceCommit: manifest.sourceIntegrity?.commit,
            violations: violations.sorted { lhs, rhs in
                if lhs.severity.weight == rhs.severity.weight { return lhs.createdAt > rhs.createdAt }
                return lhs.severity.weight > rhs.severity.weight
            },
            recommendations: recommendations(from: violations)
        )
    }

    private func previousUserPrompt(before index: Int, in messages: [ChatMessage]) -> String? {
        guard index > 0 else { return nil }
        for candidate in messages[..<index].reversed() where candidate.messageRole == .user {
            return candidate.content
        }
        return nil
    }

    private func allowedToolsByIntent(_ manifest: AgentBehaviorManifest) -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for entry in manifest.routingMatrix {
            out[entry.intent, default: []].formUnion(entry.allowedTools)
        }
        for intent in manifest.intents {
            out[intent.id, default: []].formUnion(intent.allowedToolIDs)
        }
        return out
    }

    private func containsSentinel(_ text: String, sentinels: Set<String>) -> Bool {
        guard !text.isEmpty else { return false }
        return sentinels.contains { sentinel in
            !sentinel.isEmpty && text.localizedCaseInsensitiveContains(sentinel)
        }
    }

    private func isObviouslyUserInitiatedWrite(prompt: String, toolID: String) -> Bool {
        _ = toolID
        let lower = prompt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let actionVerbs = ["send", "create", "draft", "call", "save", "schedule", "cancel", "set", "remind"]

        guard actionVerbs.contains(where: { lower.contains($0) }) else { return false }

        let explicitRequestMarkers = [
            "please ",
            "can you ",
            "could you ",
            "i want you to ",
            "i need you to ",
            "help me ",
            "for me"
        ]

        let imperativePatterns = [
            "please send", "please create", "please draft", "please call", "please save", "please schedule", "please cancel", "please set", "please remind",
            "send this", "create this", "draft this", "call ", "save this", "schedule this", "cancel this", "set this", "remind me",
            "i want you to send", "i want you to create", "i want you to draft", "i want you to call", "i need you to call", "i need you to create"
        ]

        let informationalMarkers = [
            "how to", "what is", "what's", "why", "when", "example", "examples", "should i", "can i", "could i", "tell me about"
        ]

        if informationalMarkers.contains(where: { lower.contains($0) }) {
            return false
        }

        let hasFirstPerson = lower.contains(" i ") || lower.hasPrefix("i ") || lower.contains(" my ") || lower.hasPrefix("my ")
        let hasRequestMarker = explicitRequestMarkers.contains(where: { lower.contains($0) })
        let hasImperativePattern = imperativePatterns.contains(where: { lower.contains($0) })

        if hasImperativePattern {
            return true
        }

        if hasFirstPerson && hasRequestMarker {
            return true
        }

        return false
    }

    private func violation(
        severity: AgentBehaviorViolation.Severity,
        code: String,
        agent: String,
        expected: String,
        actual: String,
        prompt: String,
        problem: String
    ) -> AgentBehaviorViolation {
        AgentBehaviorViolation(
            id: UUID(),
            createdAt: Date(),
            severity: severity,
            code: code,
            agent: agent,
            expected: String(expected.prefix(1_000)),
            actual: String(actual.prefix(1_000)),
            promptPrefix: String(prompt.prefix(500)),
            problem: problem
        )
    }

    private func recommendations(from violations: [AgentBehaviorViolation]) -> [String] {
        var out: Set<String> = []
        if violations.contains(where: { $0.code == "unknown_tool_id" }) {
            out.insert("Regenerate/refresh the manifest and add negative tool-ID contrast samples for Executor.")
        }
        if violations.contains(where: { $0.code.contains("not_allowed") || $0.code == "tool_used_for_chat_intent" }) {
            out.insert("Add Cortex routing contrast samples for the violated intent/tool pairs.")
        }
        if violations.contains(where: { $0.code == "missing_required_tool_argument" }) {
            out.insert("Regenerate Tool Executor schema samples and reinforce required argument coverage.")
        }
        if violations.contains(where: { $0.code.contains("sentinel") }) {
            out.insert("Add Mouth/step sanitizer regression samples for forbidden sentinel leakage.")
        }
        if violations.contains(where: { $0.code.contains("approval") }) {
            out.insert("Add approval-boundary samples for requiresApproval tools and verify UI confirmation paths.")
        }
        return out.sorted()
    }
}
