import Foundation

struct LegacyPromptAssembled: Sendable {
    let systemPrompt: String
    let userMessage: String
    let groundingAppendix: String
    let estimatedChars: Int
    let truncationOccurred: Bool
    let memorySectionChars: Int
    let ragSectionChars: Int
    let toolSectionChars: Int
}

enum LegacyPromptAssembler {
    static func assemble(baseSystemPrompt: String, baseUserMessage: String, sections: [PromptGroundingSection], policy: LegacyPromptInjectionPolicy, roleMetadata: String? = nil) -> LegacyPromptAssembled {
        func titled(_ name: String, _ body: String) -> String { body.isEmpty ? "" : "[\(name)]\n\(body)\n" }
        let mem = sections.first(where: {$0.title.lowercased().contains("memory") && (policy.allowSensitiveSections || $0.privacyLevel != .sensitive)})?.content ?? ""
        let rag = sections.first(where: {$0.title.lowercased().contains("source") && (policy.allowSensitiveSections || $0.privacyLevel != .sensitive)})?.content ?? ""
        let tool = sections.first(where: {$0.title.lowercased().contains("tool")})?.content ?? ""
        let runtime = sections.first(where: {$0.title.lowercased().contains("runtime")})?.content ?? ""

        let memC = String(mem.prefix(policy.memoryMax))
        let ragC = String(rag.prefix(policy.ragMax))
        let toolC = String(tool.prefix(policy.toolMax))
        let runC = String(runtime.prefix(policy.runtimeMax))
        var appendix = ""
        appendix += titled("LOCAL MEMORY", memC)
        appendix += titled("LOCAL SOURCES", ragC)
        appendix += titled("AVAILABLE LOCAL TOOLS", toolC)
        appendix += titled("RUNTIME POLICY", runC)
        if let roleMetadata, !roleMetadata.isEmpty { appendix += titled("ROLE STAGE", String(roleMetadata.prefix(180))) }
        let finalUser = baseUserMessage + (appendix.isEmpty ? "" : "\n\n" + appendix)
        let trunc = mem.count > memC.count || rag.count > ragC.count || tool.count > toolC.count || runtime.count > runC.count
        return .init(systemPrompt: baseSystemPrompt, userMessage: finalUser, groundingAppendix: appendix, estimatedChars: finalUser.count + baseSystemPrompt.count, truncationOccurred: trunc, memorySectionChars: memC.count, ragSectionChars: ragC.count, toolSectionChars: toolC.count)
    }
}
