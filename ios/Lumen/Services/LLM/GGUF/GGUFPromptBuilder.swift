import Foundation

nonisolated enum GGUFPromptBuilder {
    private static let maximumPromptCharacters = 2_000_000

    static func buildPrompt(from request: LLMRequest) throws -> String {
        var parts: [String] = []

        if let systemPrompt = nonEmpty(request.systemPrompt) {
            parts.append(section(marker: "<|system|>", body: systemPrompt))
        }

        if let toolDefinitions = buildToolDefinitions(request.tools) {
            parts.append(section(marker: "<|tool|>", body: toolDefinitions))
        }

        let contextBlock = buildContextBlock(request.context)
        var insertedContext = false

        for message in request.messages {
            if message.role == .user, insertedContext == false {
                if let contextBlock {
                    parts.append(section(marker: "<|system|>", body: contextBlock))
                }
                insertedContext = true
            }

            guard let content = nonEmpty(message.content) else { continue }
            parts.append(section(marker: marker(for: message.role), body: content))
        }

        if insertedContext == false, let contextBlock {
            parts.append(section(marker: "<|system|>", body: contextBlock))
        }

        if parts.isEmpty == false, request.messages.last?.role != .assistant {
            parts.append("<|assistant|>")
        }

        let prompt = parts.joined(separator: "\n\n")
        guard prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw LLMEngineError.invalidRequest("Prompt is empty.")
        }

        let promptCharacterCount = prompt.count
        guard promptCharacterCount <= maximumPromptCharacters else {
            throw LLMEngineError.contextTooLarge(
                max: maximumPromptCharacters / 4,
                actual: approximateTokenCount(forCharacterCount: promptCharacterCount)
            )
        }

        return prompt
    }

    private static func section(marker: String, body: String) -> String {
        "\(marker)\n\(body)"
    }

    private static func marker(for role: LLMChatMessage.Role) -> String {
        switch role {
        case .system:
            return "<|system|>"
        case .user:
            return "<|user|>"
        case .assistant:
            return "<|assistant|>"
        case .tool:
            return "<|tool|>"
        }
    }

    private static func buildContextBlock(_ context: [LLMContextItem]) -> String? {
        let entries = context.compactMap { item -> String? in
            guard let content = nonEmpty(item.content) else { return nil }

            var lines: [String] = []
            if let title = nonEmpty(item.title) {
                lines.append("Title: \(title)")
            }
            if let source = nonEmpty(item.source) {
                lines.append("Source: \(source)")
            }
            lines.append(content)
            return lines.joined(separator: "\n")
        }

        guard entries.isEmpty == false else { return nil }
        return "Context:\n" + entries.enumerated().map { index, entry in
            "[\(index + 1)]\n\(entry)"
        }.joined(separator: "\n\n")
    }

    private static func buildToolDefinitions(_ tools: [LLMToolDefinition]) -> String? {
        let definitions = tools.compactMap { tool -> String? in
            guard let name = nonEmpty(tool.name) else { return nil }
            var lines = [
                "Tool: \(name)",
                "Description: \(nonEmpty(tool.description) ?? "No description provided.")"
            ]
            if let schema = nonEmpty(tool.jsonSchema) {
                lines.append("Schema: \(schema)")
            }
            lines.append("Requires user approval: \(tool.requiresUserApproval)")
            lines.append("Destructive: \(tool.isDestructive)")
            return lines.joined(separator: "\n")
        }

        guard definitions.isEmpty == false else { return nil }
        return "Available tools:\n" + definitions.joined(separator: "\n\n")
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func approximateTokenCount(forCharacterCount characterCount: Int) -> Int {
        Int(ceil(Double(characterCount) / 4.0))
    }
}
