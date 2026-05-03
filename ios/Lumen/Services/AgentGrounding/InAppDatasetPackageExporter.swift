import Foundation

nonisolated struct LumenInAppDatasetPackage: Codable, Sendable, Hashable {
    let schemaVersion: String
    let generatedAt: Date
    let app: InAppDatasetAppInfo
    let manifestSource: String
    let usedRuntimeFallback: Bool
    let runtimeManifestAudit: RuntimeAgentManifestAuditReport?
    let behaviorAudit: AgentBehaviorAuditReport?
    let scenarioResults: [RuntimeScenarioResult]
    let recentTraces: [AgentBehaviorTrace]
    let traceSelectedToolAllowedCount: Int
    let exportPolicy: InAppDatasetExportPolicy
}

nonisolated struct InAppDatasetAppInfo: Codable, Sendable, Hashable {
    let name: String
    let bundleIdentifier: String?
    let shortVersion: String?
    let buildNumber: String?
}

nonisolated struct InAppDatasetExportPolicy: Codable, Sendable, Hashable {
    let format: String
    let privacy: String
    let promptPolicy: String
    let traceLimit: Int
    let source: String
}

nonisolated struct InAppDatasetPackageExportResult: Sendable, Hashable {
    let url: URL
    let package: LumenInAppDatasetPackage
}

nonisolated enum InAppDatasetPackageExporter {
    static let schemaVersion = "1.0.0"
    private static let directoryName = "LumenDatasetExports"

    static func makePackage(
        manifestSource: String,
        usedRuntimeFallback: Bool,
        runtimeManifestAudit: RuntimeAgentManifestAuditReport?,
        behaviorAudit: AgentBehaviorAuditReport?,
        scenarioResults: [RuntimeScenarioResult],
        traceLimit: Int = 200
    ) -> LumenInAppDatasetPackage {
        let traces = AgentBehaviorTraceRecorder.recent(limit: traceLimit)
        LumenInAppDatasetPackage(
            schemaVersion: schemaVersion,
            generatedAt: Date(),
            app: InAppDatasetAppInfo(
                name: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Lumen",
                bundleIdentifier: Bundle.main.bundleIdentifier,
                shortVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ),
            manifestSource: manifestSource,
            usedRuntimeFallback: usedRuntimeFallback,
            runtimeManifestAudit: runtimeManifestAudit,
            behaviorAudit: behaviorAudit,
            scenarioResults: scenarioResults,
            recentTraces: traces,
            traceSelectedToolAllowedCount: traces.reduce(into: 0) { count, trace in
                guard let selectedToolID = trace.selectedToolID else { return }
                if trace.allowedToolIDs.contains(selectedToolID) {
                    count += 1
                }
            },
            exportPolicy: InAppDatasetExportPolicy(
                format: "single-json-package",
                privacy: "contains only manifest audit failures, behavior violations, deterministic scenarios, and truncated trace prefixes; no full conversations, contacts, calendar bodies, files, photos, or tool payload bodies are exported",
                promptPolicy: "promptPrefix fields are bounded and should be treated as diagnostic snippets only",
                traceLimit: traceLimit,
                source: "RuntimeManifestAuditor + AgentModelBehaviorAuditor + RuntimeScenarioRunner + AgentBehaviorTraceRecorder"
            )
        )
    }

    static func writePackage(
        manifestSource: String,
        usedRuntimeFallback: Bool,
        runtimeManifestAudit: RuntimeAgentManifestAuditReport?,
        behaviorAudit: AgentBehaviorAuditReport?,
        scenarioResults: [RuntimeScenarioResult],
        traceLimit: Int = 200
    ) throws -> InAppDatasetPackageExportResult {
        let package = makePackage(
            manifestSource: manifestSource,
            usedRuntimeFallback: usedRuntimeFallback,
            runtimeManifestAudit: runtimeManifestAudit,
            behaviorAudit: behaviorAudit,
            scenarioResults: scenarioResults,
            traceLimit: traceLimit
        )
        let directory = try exportDirectory()
        let fileName = "lumen-in-app-dataset-\(Self.safeTimestamp(package.generatedAt))-\(UUID().uuidString.lowercased()).json"
        let url = directory.appendingPathComponent(fileName, isDirectory: false)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(package)
        try data.write(to: url, options: [.atomic])
        return InAppDatasetPackageExportResult(url: url, package: package)
    }

    static func exportDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let directory = base
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func safeTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }
}
