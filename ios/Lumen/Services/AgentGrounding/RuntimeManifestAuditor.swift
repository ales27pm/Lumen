import Foundation

public struct RuntimeAgentManifestAuditReport: Codable, Hashable {
    public let passed: Bool
    public let score: Double
    public let failures: [RuntimeManifestFailure]
    public let generatedAt: Date
    public let recommendedDatasetRepairs: [String]
}

public struct RuntimeManifestFailure: Codable, Hashable, Identifiable {
    public var id: String { [type, agent ?? "", actual ?? "", problem].joined(separator: "|") }
    public let type: String
    public let agent: String?
    public let expected: [String]
    public let actual: String?
    public let scenario: String?
    public let problem: String
}

public final class RuntimeManifestAuditor {
    private let registryProvider: RuntimeToolRegistryProviding
    private let supportedTypes: Set<String> = ["string", "double", "int", "bool", "array", "object", "null"]

    public init(registryProvider: RuntimeToolRegistryProviding) {
        self.registryProvider = registryProvider
    }

    public func loadBundledManifest(resourceName: String = "AgentBehaviorManifest", bundle: Bundle = .main) throws -> AgentBehaviorManifest {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
            throw RuntimeManifestAuditError.missingBundledManifest(resourceName)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AgentBehaviorManifest.self, from: data)
    }

    public func audit(manifest: AgentBehaviorManifest) -> RuntimeAgentManifestAuditReport {
        let liveTools = registryProvider.currentToolDefinitions()
        var failures: [RuntimeManifestFailure] = []

        let manifestByID = Dictionary(uniqueKeysWithValues: manifest.tools.map { ($0.id, $0) })
        let liveByID = Dictionary(grouping: liveTools, by: \RuntimeToolDefinition.id)

        for (toolID, liveGroup) in liveByID where liveGroup.count > 1 {
            failures.append(RuntimeManifestFailure(
                type: "duplicate_live_tool_id",
                agent: "runtime",
                expected: [toolID],
                actual: toolID,
                scenario: nil,
                problem: "Runtime registry exposes duplicate tool ID \(toolID)."
            ))
        }

        for manifestTool in manifest.tools {
            guard let liveTool = liveByID[manifestTool.id]?.first else {
                failures.append(RuntimeManifestFailure(
                    type: "missing_live_tool",
                    agent: "runtime",
                    expected: [manifestTool.id],
                    actual: nil,
                    scenario: nil,
                    problem: "Tool exists in manifest but not in runtime registry."
                ))
                continue
            }
            compare(manifestTool: manifestTool, liveTool: liveTool, failures: &failures)
        }

        for liveTool in liveTools where manifestByID[liveTool.id] == nil {
            failures.append(RuntimeManifestFailure(
                type: "unmanifested_live_tool",
                agent: "runtime",
                expected: Array(manifestByID.keys).sorted(),
                actual: liveTool.id,
                scenario: nil,
                problem: "Runtime registry exposes a tool absent from AgentBehaviorManifest.json."
            ))
        }

        let score = Self.score(failureCount: failures.count, manifestToolCount: manifest.tools.count, liveToolCount: liveTools.count)
        return RuntimeAgentManifestAuditReport(
            passed: failures.isEmpty,
            score: score,
            failures: failures,
            generatedAt: Date(),
            recommendedDatasetRepairs: Self.repairHints(for: failures)
        )
    }

    private func compare(manifestTool: RuntimeToolDefinition, liveTool: RuntimeToolDefinition, failures: inout [RuntimeManifestFailure]) {
        if manifestTool.requiresApproval != liveTool.requiresApproval {
            failures.append(RuntimeManifestFailure(
                type: "approval_mismatch",
                agent: "runtime",
                expected: [String(manifestTool.requiresApproval)],
                actual: String(liveTool.requiresApproval),
                scenario: manifestTool.id,
                problem: "requiresApproval differs between manifest and runtime registry."
            ))
        }

        if manifestTool.permissionKey != liveTool.permissionKey {
            failures.append(RuntimeManifestFailure(
                type: "permission_key_mismatch",
                agent: "runtime",
                expected: [manifestTool.permissionKey ?? "nil"],
                actual: liveTool.permissionKey ?? "nil",
                scenario: manifestTool.id,
                problem: "permissionKey differs between manifest and runtime registry."
            ))
        }

        let manifestArgs = Dictionary(uniqueKeysWithValues: manifestTool.arguments.map { ($0.name, $0) })
        let liveArgs = Dictionary(uniqueKeysWithValues: liveTool.arguments.map { ($0.name, $0) })

        for (name, manifestArg) in manifestArgs {
            guard let liveArg = liveArgs[name] else {
                failures.append(RuntimeManifestFailure(
                    type: "missing_live_argument",
                    agent: "runtime",
                    expected: [name],
                    actual: nil,
                    scenario: manifestTool.id,
                    problem: "Manifest argument is absent from runtime tool definition."
                ))
                continue
            }
            if normalizeType(manifestArg.type) != normalizeType(liveArg.type) || manifestArg.required != liveArg.required {
                failures.append(RuntimeManifestFailure(
                    type: "argument_mismatch",
                    agent: "runtime",
                    expected: ["\(name):\(manifestArg.type):required=\(manifestArg.required)"],
                    actual: "\(name):\(liveArg.type):required=\(liveArg.required)",
                    scenario: manifestTool.id,
                    problem: "Argument type or required flag differs between manifest and runtime."
                ))
            }
            if !supportedTypes.contains(normalizeType(liveArg.type)) {
                failures.append(RuntimeManifestFailure(
                    type: "unsupported_runtime_argument_type",
                    agent: "runtime",
                    expected: Array(supportedTypes).sorted(),
                    actual: liveArg.type,
                    scenario: manifestTool.id,
                    problem: "Runtime argument type is unsupported by AgentJSONValue contract."
                ))
            }
        }

        for liveArg in liveTool.arguments where manifestArgs[liveArg.name] == nil {
            failures.append(RuntimeManifestFailure(
                type: "unmanifested_live_argument",
                agent: "runtime",
                expected: Array(manifestArgs.keys).sorted(),
                actual: liveArg.name,
                scenario: manifestTool.id,
                problem: "Runtime exposes an argument absent from the manifest."
            ))
        }
    }

    private func normalizeType(_ value: String) -> String {
        switch value.lowercased() {
        case "str", "text": return "string"
        case "float", "number": return "double"
        case "integer": return "int"
        case "boolean": return "bool"
        case "list": return "array"
        case "dictionary", "dict": return "object"
        default: return value.lowercased()
        }
    }

    private static func score(failureCount: Int, manifestToolCount: Int, liveToolCount: Int) -> Double {
        let denominator = max(1, manifestToolCount + liveToolCount)
        let penalty = Double(failureCount) / Double(denominator)
        return max(0.0, min(1.0, 1.0 - penalty))
    }

    private static func repairHints(for failures: [RuntimeManifestFailure]) -> [String] {
        Array(Set(failures.map { failure in
            switch failure.type {
            case "unmanifested_live_tool", "missing_live_tool":
                return "Regenerate AgentBehaviorManifest.json from the current Swift source."
            case "approval_mismatch":
                return "Regenerate approval-boundary dataset samples for changed tools."
            case "argument_mismatch", "missing_live_argument", "unmanifested_live_argument":
                return "Regenerate Tool Executor schema samples and negative contrast records."
            default:
                return "Review runtime manifest drift and add a REM repair sample."
            }
        })).sorted()
    }
}

public enum RuntimeManifestAuditError: Error, LocalizedError {
    case missingBundledManifest(String)

    public var errorDescription: String? {
        switch self {
        case .missingBundledManifest(let name):
            return "Missing bundled \(name).json resource."
        }
    }
}
