import Foundation

nonisolated enum ApprovalSource: String, Sendable, Codable {
    case uiConfirmation
}

nonisolated struct ToolApprovalState: Sendable, Codable, Hashable {
    let pendingActionID: UUID
    let toolID: String
    let arguments: AgentJSONArguments
    let approvedAt: Date?
    let source: ApprovalSource

    var executionApproval: ToolExecutionApproval {
        guard source == .uiConfirmation, approvedAt != nil else { return .autonomous }
        return .userApproved
    }
}

nonisolated enum ExecutorActionKind: String, Sendable, Codable {
    case executeTool
    case requestApproval
    case requestPermission
    case clarification
    case reject
}

nonisolated struct ExecutorPendingApproval: Sendable, Codable, Hashable {
    let pendingActionID: UUID
    let toolID: String
    let arguments: AgentJSONArguments
    let confirmationMessage: String
    let reason: String
}

@MainActor
final class ToolApprovalQueue {
    static let shared = ToolApprovalQueue()
    private var pendingByID: [UUID: ExecutorPendingApproval] = [:]
    private init() {}

    func enqueue(toolID: String, toolName: String, arguments: [String: String]) -> ExecutorPendingApproval {
        let pending = ExecutorPendingApproval(
            pendingActionID: UUID(),
            toolID: toolID,
            arguments: AgentJSONArguments(stringDictionary: arguments),
            confirmationMessage: "Approve \(toolName) with arguments: \(arguments)",
            reason: "requiresApproval"
        )
        pendingByID[pending.pendingActionID] = pending
        return pending
    }

    func resolve(_ pendingActionID: UUID) -> ExecutorPendingApproval? { pendingByID[pendingActionID] }
    func clear(_ pendingActionID: UUID) { pendingByID.removeValue(forKey: pendingActionID) }
}

nonisolated enum ApprovalBoundaryFormatter {
    static func approvalMessage(for pending: ExecutorPendingApproval) -> String {
        "Approval required before running \(pending.toolID). Pending action id: \(pending.pendingActionID.uuidString)."
    }
}
