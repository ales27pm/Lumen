import Foundation
import SwiftData

@Model
final class ChatMessage {
    var id: UUID = UUID()
    var role: String = "user"
    var content: String = ""
    var createdAt: Date = Date()
    var toolName: String?
    var toolStatus: String?
    var toolResult: String?
    var agentStepsJSON: String?
    var conversation: Conversation?

    init(role: MessageRole, content: String, toolName: String? = nil, toolStatus: ToolStatus? = nil, toolResult: String? = nil, agentSteps: [AgentStep] = []) {
        self.role = role.rawValue
        self.content = content
        self.toolName = toolName
        self.toolStatus = toolStatus?.rawValue
        self.toolResult = toolResult
        self.agentStepsJSON = AgentStepCodec.encode(agentSteps)
    }

    var agentSteps: [AgentStep] {
        get { AgentStepCodec.decode(agentStepsJSON) }
        set { agentStepsJSON = AgentStepCodec.encode(newValue) }
    }

    var messageRole: MessageRole { MessageRole(rawValue: role) ?? .user }
    var status: ToolStatus? { toolStatus.flatMap(ToolStatus.init(rawValue:)) }
}

enum MessageRole: String, Codable, CaseIterable, Sendable {
    case system, user, assistant, tool
}

enum ToolStatus: String, Codable, Sendable {
    case pendingApproval
    case running
    case completed
    case denied
    case failed
}
