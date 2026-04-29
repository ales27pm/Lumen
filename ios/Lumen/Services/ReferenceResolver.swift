import Foundation

nonisolated struct ReferenceResolution: Sendable {
    let originalPrompt: String
    let rewrittenPrompt: String
    let resolvedReferences: [String: String]
    let confidence: Double
    let diagnostics: [String]

    var hasRewrite: Bool { originalPrompt != rewrittenPrompt }
}

nonisolated enum ReferenceResolver {
    static func resolve(
        prompt: String,
        history: [(role: MessageRole, content: String)],
        relevantMemories: [MemoryContextItem],
        currentTurnLedger: [ToolLedgerEntry] = []
    ) -> ReferenceResolution {
        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPrompt.isEmpty else {
            return ReferenceResolution(originalPrompt: prompt, rewrittenPrompt: prompt, resolvedReferences: [:], confidence: 0, diagnostics: ["empty_prompt"])
        }

        var rewritten = normalizedPrompt
        var mapping: [String: String] = [:]
        var diagnostics: [String] = []
        var score: Double = 0

        let candidates = recentPersonCandidates(history: history, relevantMemories: relevantMemories)
        if containsPronoun(normalizedPrompt) {
            if let candidate = candidates.first {
                rewritten = rewritePronouns(in: rewritten, with: candidate)
                mapping["pronoun"] = candidate
                score += 0.75
                diagnostics.append("resolved_pronoun_from_recent_context")
            } else {
                diagnostics.append("pronoun_detected_no_safe_referent")
            }
        }

        if containsPreviousReference(normalizedPrompt) {
            if let tool = currentTurnLedger.last?.toolID {
                rewritten = rewritePreviousReference(in: rewritten, replacement: "the previous \(tool) result")
                mapping["previous one"] = "previous \(tool) result"
                score += 0.2
                diagnostics.append("resolved_deictic_from_current_turn_toolledger")
            } else {
                diagnostics.append("deictic_detected_without_current_turn_toolledger")
            }
        }

        let bounded = min(1.0, max(0.0, score))
        return ReferenceResolution(
            originalPrompt: prompt,
            rewrittenPrompt: rewritten,
            resolvedReferences: mapping,
            confidence: bounded,
            diagnostics: diagnostics
        )
    }

    private static func containsPronoun(_ text: String) -> Bool {
        let lower = text.lowercased()
        return [" call her", " text her", " message her", "call him", "text him", "message him", "her ", " him "]
            .contains { lower.contains($0) } || lower.hasPrefix("call her") || lower.hasPrefix("call him") || lower.hasPrefix("text her") || lower.hasPrefix("text him")
    }

    private static func containsPreviousReference(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["previous one", "that one", "last one", "use previous"].contains { lower.contains($0) }
    }

    private static func rewritePronouns(in text: String, with referent: String) -> String {
        var out = text
        let patterns = ["\\bher\\b", "\\bhim\\b"]
        for pattern in patterns {
            out = out.replacingOccurrences(of: pattern, with: referent, options: [.regularExpression, .caseInsensitive])
        }
        return out
    }

    private static func rewritePreviousReference(in text: String, replacement: String) -> String {
        var out = text
        ["previous one", "that one", "last one"].forEach { token in
            out = out.replacingOccurrences(of: token, with: replacement, options: [.caseInsensitive])
        }
        return out
    }

    private static func recentPersonCandidates(history: [(role: MessageRole, content: String)], relevantMemories: [MemoryContextItem]) -> [String] {
        let historyTail = history.suffix(8).map(\.content)
        let memoryTail = relevantMemories
            .filter { $0.scope == .person || ($0.topic?.lowercased().contains("contact") ?? false) }
            .prefix(8)
            .map(\.content)

        let raw = Array(historyTail) + Array(memoryTail)
        return raw.compactMap(extractPersonName)
    }

    private static func extractPersonName(_ text: String) -> String? {
        let pattern = #"\b([A-Z][a-z]+(?:\s+[A-Z][a-z]+){0,2})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for match in matches.reversed() {
            let candidate = ns.substring(with: match.range(at: 1))
            if candidate.count >= 3, !["Call", "Text", "Message", "Use", "Previous"].contains(candidate) {
                return candidate
            }
        }
        return nil
    }
}
