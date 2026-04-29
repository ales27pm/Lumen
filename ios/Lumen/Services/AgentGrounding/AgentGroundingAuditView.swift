import SwiftUI

public struct AgentGroundingAuditView: View {
    private let auditor: RuntimeManifestAuditor
    private let scenarioRunner = RuntimeScenarioRunner()

    @State private var report: RuntimeAgentManifestAuditReport?
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
                Text("Loads the writable Application Support manifest first, seeds it from the bundled AgentBehaviorManifest.json when available, then compares it against the live ToolRegistry. Runtime fallback is only used when no stored or bundled manifest exists.")
            }

            if let errorMessage {
                Section("Error") {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }

            if let report {
                Section("Result") {
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
                    Section("Failures") {
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
                    Section("Recommended Repairs") {
                        ForEach(report.recommendedDatasetRepairs, id: \.self) { repair in
                            Text(repair)
                        }
                    }
                }
            }

            if !scenarioResults.isEmpty {
                Section("Scenario Checks") {
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
        DispatchQueue.global(qos: .userInitiated).async {
            let loadResult = auditor.loadManifestFromStoreBundleOrRuntimeFallback()
            let auditReport = auditor.audit(manifest: loadResult.manifest)
            let scenarios = scenarioRunner.validateStaticScenarios(manifest: loadResult.manifest)
            DispatchQueue.main.async {
                report = auditReport
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
}
