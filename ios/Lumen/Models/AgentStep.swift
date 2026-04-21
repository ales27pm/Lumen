import Foundation

nonisolated struct AgentStep: Codable, Sendable, Identifiable, Hashable {
    var id: UUID = UUID()
    var kind: Kind
    var content: String
    var toolID: String?
    var toolArgs: [String: String]?

    nonisolated enum Kind: String, Codable, Sendable {
        case thought
        case action
        case observation
        case reflection
    }

    var icon: String {
        switch kind {
        case .thought: "brain"
        case .action: "wrench.and.screwdriver.fill"
        case .observation: "eye.fill"
        case .reflection: "sparkle"
        }
    }

    var label: String {
        switch kind {
        case .thought: "Thought"
        case .action: "Action"
        case .observation: "Observation"
        case .reflection: "Reflection"
        }
    }
}

nonisolated enum AgentStepCodec {
    static func encode(_ steps: [AgentStep]) -> String? {
        guard !steps.isEmpty else { return nil }
        let enc = JSONEncoder()
        guard let data = try? enc.encode(steps) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ string: String?) -> [AgentStep] {
        guard let string, let data = string.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([AgentStep].self, from: data)) ?? []
    }
}
