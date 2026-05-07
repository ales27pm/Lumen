import Foundation
import Testing
@testable import Lumen

struct AgentGroundingRegressionTests {
    private static let outlookTools = [
        "outlook.status", "outlook.folders.list", "outlook.messages.list", "outlook.messages.search",
        "outlook.message.read", "outlook.attachments.list", "outlook.draft.create", "outlook.mail.send",
        "outlook.message.mark_read", "outlook.message.mark_unread", "outlook.message.move", "outlook.message.archive",
        "outlook.message.delete", "outlook.message.reply", "outlook.message.reply_all", "outlook.message.forward"
    ]

    @Test func runtimeAuditorHasNoUnmanifestedOutlookToolsWhenManifestContainsThem() async throws {
        let tools = Self.outlookTools.map { RuntimeToolDefinition(id: $0) }
        let manifest = makeManifest(tools: tools, intent: "outlook", allowed: Self.outlookTools)
        let auditor = RuntimeManifestAuditor(registryProvider: StaticRuntimeToolRegistryProvider(tools: tools))
        let report = auditor.audit(manifest: manifest)
        #expect(report.passed)
        #expect(!report.failures.contains(where: { $0.type == "unmanifested_live_tool" && ($0.actual?.hasPrefix("outlook") ?? false) }))
    }

    @MainActor
    @Test func behaviorAuditorAcceptsCameraAndMapsActionSteps() async throws {
        let tools = [RuntimeToolDefinition(id: "camera.capture"), RuntimeToolDefinition(id: "location.current"), RuntimeToolDefinition(id: "maps.search"), RuntimeToolDefinition(id: "maps.directions")]
        let manifest = makeManifest(tools: tools, intent: "camera", allowed: ["camera.capture"], extraIntents: [
            ManifestRoutingEntry(intent: "maps", allowedTools: ["location.current", "maps.search", "maps.directions"], forbiddenTools: [])
        ])

        let now = Date()
        let messages: [ChatMessage] = [
            ChatMessage(role: .user, content: "Open camera and take a picture"),
            ChatMessage(role: .assistant, content: "Done", agentSteps: [AgentStep(kind: .action, content: "camera.capture", toolID: "camera.capture")]),
            ChatMessage(role: .user, content: "Show me on map"),
            ChatMessage(role: .assistant, content: "Need location", agentSteps: [AgentStep(kind: .action, content: "location.current", toolID: "location.current")]),
            ChatMessage(role: .user, content: "Where are we"),
            ChatMessage(role: .assistant, content: "Current location", agentSteps: [AgentStep(kind: .action, content: "location.current", toolID: "location.current")])
        ].enumerated().map { idx, msg in
            msg.createdAt = now.addingTimeInterval(TimeInterval(idx))
            return msg
        }

        let audit = AgentModelBehaviorAuditor().audit(manifest: manifest, messages: messages)
        #expect(!audit.violations.contains(where: { $0.code == "missing_required_tool_action" }))
    }

    @MainActor
    @Test func behaviorAuditorFailsOnHiddenReasoningLeak() async throws {
        let manifest = makeManifest(tools: [], intent: "chat", allowed: [])
        let now = Date()
        let messages: [ChatMessage] = [
            ChatMessage(role: .user, content: "hello"),
            ChatMessage(role: .assistant, content: "<think>secret</think>Hi")
        ].enumerated().map { idx, msg in
            msg.createdAt = now.addingTimeInterval(TimeInterval(idx))
            return msg
        }
        let audit = AgentModelBehaviorAuditor().audit(manifest: manifest, messages: messages)
        #expect(!audit.passed)
        #expect(audit.violations.contains(where: { $0.code == "hiddenReasoningLeak" }))
    }

    @Test func requiredToolFallbackRoutesCameraMapsAndOutlookPrompts() {
        #expect(SlotAgentService.resolveRequiredToolFallback(intent: .camera, prompt: "Open camera and take a picture", allowedToolIDs: ["camera.capture"]) == "camera.capture")
        #expect(SlotAgentService.resolveRequiredToolFallback(intent: .maps, prompt: "Where are we", allowedToolIDs: ["location.current", "maps.search", "maps.directions"]) == "location.current")

        let mapFallback = SlotAgentService.resolveRequiredToolFallback(intent: .maps, prompt: "Show me on map", allowedToolIDs: ["location.current", "maps.search", "maps.directions"])
        #expect(["location.current", "maps.search"].contains(mapFallback ?? ""))

        #expect(SlotAgentService.resolveRequiredToolFallback(intent: .outlook, prompt: "Read new emails", allowedToolIDs: Self.outlookTools) == "outlook.messages.list")
        #expect(SlotAgentService.resolveRequiredToolFallback(intent: .outlook, prompt: "Read my unread emails", allowedToolIDs: Self.outlookTools) == "outlook.messages.list")
        #expect(SlotAgentService.resolveRequiredToolFallback(intent: .outlook, prompt: "Read the latest email", allowedToolIDs: Self.outlookTools) == "outlook.messages.list")
        #expect(SlotAgentService.resolveRequiredToolFallback(intent: .outlook, prompt: "Check my unread outlook emails", allowedToolIDs: Self.outlookTools) == "outlook.messages.list")
        #expect(SlotAgentService.resolveRequiredToolFallback(intent: .outlook, prompt: "Check my outlook email", allowedToolIDs: Self.outlookTools) == "outlook.messages.list")
    }

    @Test func agentGroundingPackageDoesNotExportStaticScenarioResultsByDefault() throws {
        AgentBehaviorTraceRecorder.clear()
        let scenario = RuntimeScenario(
            id: "calendar::calendar.create",
            intent: "calendar",
            expectedToolID: "calendar.create",
            requiresApproval: false,
            prompt: "Create a calendar event."
        )
        let failure = RuntimeManifestFailure(
            type: "scenario_unknown_tool",
            agent: "cortex",
            expected: ["calendar.create"],
            actual: "calendar.create",
            scenario: scenario.prompt,
            problem: "Static manifest scenario failure, not model execution."
        )
        let package = InAppDatasetPackageExporter.makePackage(
            manifestSource: "test-manifest",
            usedRuntimeFallback: false,
            runtimeManifestAudit: nil,
            behaviorAudit: nil,
            scenarioResults: [
                RuntimeScenarioResult(
                    id: scenario.id,
                    scenario: scenario,
                    passed: false,
                    failures: [failure]
                )
            ],
            traceLimit: 0
        )

        #expect(package.schemaVersion == "1.1.0")
        #expect(package.exportPolicy.sourceLayer == "agentGroundingRuntimeAudit")
        #expect(package.exportPolicy.ownsLiveE2EScenarios == false)
        #expect(package.exportPolicy.includesDeterministicStaticScenarios == false)
        #expect(package.scenarioResults.isEmpty)
    }

    @Test func agentGroundingPackageCanExplicitlyIncludeStaticScenarioResultsButMarksThemNonE2E() throws {
        AgentBehaviorTraceRecorder.clear()
        let scenario = RuntimeScenario(
            id: "calendar::calendar.create",
            intent: "calendar",
            expectedToolID: "calendar.create",
            requiresApproval: false,
            prompt: "Create a calendar event."
        )
        let package = InAppDatasetPackageExporter.makePackage(
            manifestSource: "test-manifest",
            usedRuntimeFallback: false,
            runtimeManifestAudit: nil,
            behaviorAudit: nil,
            scenarioResults: [
                RuntimeScenarioResult(
                    id: scenario.id,
                    scenario: scenario,
                    passed: true,
                    failures: []
                )
            ],
            traceLimit: 0,
            includeScenarioResults: true
        )

        #expect(package.exportPolicy.ownsLiveE2EScenarios == false)
        #expect(package.exportPolicy.includesDeterministicStaticScenarios == true)
        #expect(package.exportPolicy.deterministicScenarioPolicy.contains("not proof of live model execution"))
        #expect(package.scenarioResults.count == 1)
    }

    private func makeManifest(tools: [RuntimeToolDefinition], intent: String, allowed: [String], extraIntents: [ManifestRoutingEntry] = []) -> AgentBehaviorManifest {
        AgentBehaviorManifest(
            schemaVersion: "1",
            app: ManifestAppInfo(name: "Lumen", bundleIdentifier: nil, buildVersion: nil, generatedAt: nil),
            sourceIntegrity: ManifestSourceIntegrity(commit: "test", files: []),
            fleet: ManifestFleet(contractVersion: "1", slots: []),
            tools: tools,
            intents: [ManifestIntent(id: intent, allowedToolIDs: allowed)],
            routingMatrix: [ManifestRoutingEntry(intent: intent, allowedTools: allowed, forbiddenTools: [])] + extraIntents,
            memory: nil,
            sentinels: ManifestSentinels(forbiddenInUserOutput: [])
        )
    }
}
