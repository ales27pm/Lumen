import Foundation

nonisolated struct AgentBehaviorTrace: Codable, Sendable, Identifiable, Hashable {
    enum Event: String, Codable, Sendable {
        case modelTurn
        case toolAction
        case finalAnswer
    }

    let id: UUID
    let createdAt: Date
    let event: Event
    let slot: String
    let stage: String
    let intent: String?
    let promptPrefix: String
    let rawOutputPrefix: String
    let selectedToolID: String?
    let toolArguments: [String: String]
    let allowedToolIDs: [String]
    let requiresApproval: Bool?
    let approvalMode: String?
    let parseError: String?
    let emittedFinalInActionTurn: Bool
}

nonisolated struct AgentBehaviorAuditReport: Codable, Sendable, Hashable {
    let passed: Bool
    let score: Double
    let generatedAt: Date
    let traceCount: Int
    let violationCount: Int
    let sourceCommit: String?
    let violations: [AgentBehaviorViolation]
    let recommendations: [String]
}

nonisolated struct AgentBehaviorViolation: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    let createdAt: Date
    let severity: Severity
    let code: String
    let agent: String
    let expected: String
    let actual: String
    let promptPrefix: String
    let problem: String

    enum Severity: String, Codable, Sendable {
        case warning
        case error
        case critical

        var weight: Double {
            switch self {
            case .warning: 0.5
            case .error: 1.0
            case .critical: 2.0
            }
        }
    }
}

nonisolated enum AgentBehaviorTraceRecorder {
    private static let fileName = "agent-behavior-traces.jsonl"

    static func record(_ trace: AgentBehaviorTrace) {
        do {
            let directory = try diagnosticsDirectory()
            let url = directory.appendingPathComponent(fileName, isDirectory: false)
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
            // Diagnostics must never break assistant execution.
        }
    }

    static func recent(limit: Int = 200) -> [AgentBehaviorTrace] {
        do {
            let url = try diagnosticsDirectory().appendingPathComponent(fileName, isDirectory: false)
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return [] }
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let traces = text
                .split(whereSeparator: \.isNewline)
                .compactMap { line -> AgentBehaviorTrace? in
                    guard let lineData = String(line).data(using: .utf8) else { return nil }
                    return try? decoder.decode(AgentBehaviorTrace.self, from: lineData)
                }
            let boundedLimit = max(0, limit)
            return Array(traces.suffix(boundedLimit))
        } catch {
            return []
        }
    }

    static func diagnosticsDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let directory = base
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("AgentBehavior", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
