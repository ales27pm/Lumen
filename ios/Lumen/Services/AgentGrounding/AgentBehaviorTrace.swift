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
    let modelFamily: String?
    let baseModelPath: String?
    let adapterID: String?
    let adapterSlot: String?
    let adapterPath: String?
    let adapterApplied: Bool?
    let adapterScale: Float?
    let adapterFailureReason: String?
    let generationElapsedMs: Int?
    let firstTokenLatencyMs: Int?
    let outputTokenCount: Int?
    let estimatedPromptTokenCount: Int?
    let preFirstTokenMs: Int?
    let messageBuildMs: Int?
    let decodeMs: Int?
    let tokensPerSecond: Double?
    let ensureReadyMs: Int?
    let adapterActivationMs: Int?
    let runtimePath: String?
    let activeAdapterSlot: String?
    let maxTokensRequested: Int?
    let maxTokensEffective: Int?
    let promptCharCount: Int?
    let accelerationDiagnostic: String?

    init(
        id: UUID,
        createdAt: Date,
        event: Event,
        slot: String,
        stage: String,
        intent: String?,
        promptPrefix: String,
        rawOutputPrefix: String,
        selectedToolID: String?,
        toolArguments: [String: String],
        allowedToolIDs: [String],
        requiresApproval: Bool?,
        approvalMode: String?,
        parseError: String?,
        emittedFinalInActionTurn: Bool,
        modelFamily: String? = nil,
        baseModelPath: String? = nil,
        adapterID: String? = nil,
        adapterSlot: String? = nil,
        adapterPath: String? = nil,
        adapterApplied: Bool? = nil,
        adapterScale: Float? = nil,
        adapterFailureReason: String? = nil,
        generationElapsedMs: Int? = nil,
        firstTokenLatencyMs: Int? = nil,
        outputTokenCount: Int? = nil,
        estimatedPromptTokenCount: Int? = nil,
        preFirstTokenMs: Int? = nil,
        messageBuildMs: Int? = nil,
        decodeMs: Int? = nil,
        tokensPerSecond: Double? = nil,
        ensureReadyMs: Int? = nil,
        adapterActivationMs: Int? = nil,
        runtimePath: String? = nil,
        activeAdapterSlot: String? = nil,
        maxTokensRequested: Int? = nil,
        maxTokensEffective: Int? = nil,
        promptCharCount: Int? = nil,
        accelerationDiagnostic: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.event = event
        self.slot = slot
        self.stage = stage
        self.intent = intent
        self.promptPrefix = promptPrefix
        self.rawOutputPrefix = rawOutputPrefix
        self.selectedToolID = selectedToolID
        self.toolArguments = toolArguments
        self.allowedToolIDs = allowedToolIDs
        self.requiresApproval = requiresApproval
        self.approvalMode = approvalMode
        self.parseError = parseError
        self.emittedFinalInActionTurn = emittedFinalInActionTurn
        self.modelFamily = modelFamily
        self.baseModelPath = baseModelPath
        self.adapterID = adapterID
        self.adapterSlot = adapterSlot
        self.adapterPath = adapterPath
        self.adapterApplied = adapterApplied
        self.adapterScale = adapterScale
        self.adapterFailureReason = adapterFailureReason
        self.generationElapsedMs = generationElapsedMs
        self.firstTokenLatencyMs = firstTokenLatencyMs
        self.outputTokenCount = outputTokenCount
        self.estimatedPromptTokenCount = estimatedPromptTokenCount
        self.preFirstTokenMs = preFirstTokenMs
        self.messageBuildMs = messageBuildMs
        self.decodeMs = decodeMs
        self.tokensPerSecond = tokensPerSecond
        self.ensureReadyMs = ensureReadyMs
        self.adapterActivationMs = adapterActivationMs
        self.runtimePath = runtimePath
        self.activeAdapterSlot = activeAdapterSlot
        self.maxTokensRequested = maxTokensRequested
        self.maxTokensEffective = maxTokensEffective
        self.promptCharCount = promptCharCount
        self.accelerationDiagnostic = accelerationDiagnostic
    }
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
    let repairSamples: [AgentBehaviorRepairSample]
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

nonisolated struct AgentBehaviorRepairSample: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    let createdAt: Date
    let agent: String
    let violationCode: String
    let promptPrefix: String
    let expected: String
    let badOutput: String
    let correctedOutput: String
    let lesson: String
    let curriculum: String
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

    static func clear() {
        do {
            let url = try diagnosticsDirectory().appendingPathComponent(fileName, isDirectory: false)
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            // Diagnostics cleanup must never break app execution.
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
