import SwiftUI
import SwiftData

public struct AgentGroundingAuditView: View {
    private let auditor: RuntimeManifestAuditor
    private let scenarioRunner = RuntimeScenarioRunner()
    private let behaviorAuditor = AgentModelBehaviorAuditor()

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ChatMessage.createdAt, order: .forward) private var messages: [ChatMessage]

    @State private var report: RuntimeAgentManifestAuditReport?
    @State private var behaviorReport: AgentBehaviorAuditReport?
    @State private var scenarioResults: [RuntimeScenarioResult] = []
    @State private var errorMessage: String?
    @State private var manifestSource: String?
    @State private var usedRuntimeFallback = false

    public init(registryProvider: RuntimeToolRegistryProviding) {
        self.auditor = RuntimeManifestAuditor(registryProvider: registryProvider)
    }

    public var body: some View {
        List {
            Section {
                Button("Run Agent Grounding Audit") {
                    runAudit()
                }
            } footer: {
                Text("Compares the static crawler manifest against live runtime tools and recent model behaviour. The model-behaviour layer checks actual persisted agent steps against expected manifest routing, schemas, approval boundaries, and sentinel rules.")
            }

            if let errorMessage {
                Section("Error") {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }

            if let report {
                Section("Runtime Registry") {
                    HStack {
                        Text(report.passed ? "Passed" : "Failed")
                        Spacer()
                        Text(scoreText(report.score))
                            .font(.headline)
                    }
                    Text(report.generatedAt.formatted())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let manifestSource {
                        LabeledContent("Manifest", value: manifestSource)
                            .font(.caption)
                    }
                    if usedRuntimeFallback {
                        Label("Runtime fallback was used. Add AgentBehaviorManifest.json to the app bundle or seed the Application Support manifest before trusting this as a source-of-truth audit.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                if !report.failures.isEmpty {
                    Section("Runtime Failures") {
                        ForEach(report.failures) { failure in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(failure.type).font(.headline)
                                Text(failure.problem).font(.subheadline)
                                if let actual = failure.actual {
                                    Text("Actual: \(actual)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if !report.recommendedDatasetRepairs.isEmpty {
                    Section("Runtime Repair Hints") {
                        ForEach(report.recommendedDatasetRepairs, id: \.self) { repair in
                            Text(repair)
                        }
                    }
                }
            }

            if let behaviorReport {
                Section("Model Behaviour") {
                    HStack {
                        Text(behaviorReport.passed ? "Grounded" : "Drift detected")
                        Spacer()
                        Text(scoreText(behaviorReport.score))
                            .font(.headline)
                    }
                    LabeledContent("Audited traces", value: "\(behaviorReport.traceCount)")
                    LabeledContent("Violations", value: "\(behaviorReport.violationCount)")
                    if let sourceCommit = behaviorReport.sourceCommit, !sourceCommit.isEmpty {
                        LabeledContent("Static source", value: String(sourceCommit.prefix(10)))
                            .font(.caption)
                    }
                    Text(behaviorReport.generatedAt.formatted())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !behaviorReport.violations.isEmpty {
                    Section("Model Drift Violations") {
                        ForEach(behaviorReport.violations.prefix(30)) { violation in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Label(violation.code, systemImage: severityIcon(violation.severity))
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(severityColor(violation.severity))
                                    Spacer()
                                    Text(violation.agent)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Text(violation.problem)
                                    .font(.caption)
                                if !violation.promptPrefix.isEmpty {
                                    Text("Prompt: \(violation.promptPrefix)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                DisclosureGroup("Expected / Actual") {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Expected: \(violation.expected)")
                                        Text("Actual: \(violation.actual)")
                                    }
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                }
                                .font(.caption)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                if !behaviorReport.recommendations.isEmpty {
                    Section("Model Repair Recommendations") {
                        ForEach(behaviorReport.recommendations, id: \.self) { recommendation in
                            Text(recommendation)
                        }
                    }
                }
            }

            if !scenarioResults.isEmpty {
                Section("Static Scenario Checks") {
                    ForEach(scenarioResults) { result in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(result.scenario.intent)
                                Text(result.scenario.expectedToolID)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(result.passed ? .green : .red)
                        }
                    }
                }
            }
        }
        .navigationTitle("Agent Grounding")
    }

    private func runAudit() {
        let currentMessages = Array(messages.suffix(200))
        DispatchQueue.global(qos: .userInitiated).async {
            let loadResult = auditor.loadManifestFromStoreBundleOrRuntimeFallback()
            let auditReport = auditor.audit(manifest: loadResult.manifest)
            let scenarios = scenarioRunner.validateStaticScenarios(manifest: loadResult.manifest)
            DispatchQueue.main.async {
                let modelReport = behaviorAuditor.audit(manifest: loadResult.manifest, messages: currentMessages)
                report = auditReport
                behaviorReport = modelReport
                scenarioResults = scenarios
                manifestSource = loadResult.source
                usedRuntimeFallback = loadResult.usedRuntimeFallback
                errorMessage = nil
            }
        }
    }

    private func scoreText(_ score: Double) -> String {
        "\(Int((score * 100).rounded()))%"
    }

    private func severityIcon(_ severity: AgentBehaviorViolation.Severity) -> String {
        switch severity {
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        case .critical: "flame"
        }
    }

    private func severityColor(_ severity: AgentBehaviorViolation.Severity) -> Color {
        switch severity {
        case .warning: .orange
        case .error: .red
        case .critical: .purple
        }
    }
}
