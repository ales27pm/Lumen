import SwiftUI

public struct AgentGroundingAuditView: View {
    private let auditor: RuntimeManifestAuditor
    private let scenarioRunner = RuntimeScenarioRunner()

    @State private var report: RuntimeAgentManifestAuditReport?
    @State private var scenarioResults: [RuntimeScenarioResult] = []
    @State private var errorMessage: String?

    public init(registryProvider: RuntimeToolRegistryProviding) {
        self.auditor = RuntimeManifestAuditor(registryProvider: registryProvider)
    }

    public var body: some View {
        List {
            Section {
                Button("Run Agent Grounding Audit") {
                    runAudit()
                }
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
            do {
                let manifest = try auditor.loadBundledManifest()
                let auditReport = auditor.audit(manifest: manifest)
                let scenarios = scenarioRunner.validateStaticScenarios(manifest: manifest)
                DispatchQueue.main.async {
                    report = auditReport
                    scenarioResults = scenarios
                    errorMessage = nil
                }
            } catch {
                DispatchQueue.main.async {
                    report = nil
                    scenarioResults = []
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func scoreText(_ score: Double) -> String {
        "\(Int((score * 100).rounded()))%"
    }
}
