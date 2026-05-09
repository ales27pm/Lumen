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
