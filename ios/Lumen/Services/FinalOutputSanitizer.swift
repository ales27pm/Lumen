import Foundation

nonisolated struct SanitizedFinalOutput: Sendable, Equatable {
    let text: String
    let removedArtifacts: [FinalOutputArtifact]
    let hadUnsafeLeakage: Bool
}

nonisolated enum FinalOutputArtifact: String, Codable, Sendable, Equatable {
    case thinkBlock
    case malformedThinkPrefix
    case lumenWebPayload
    case rawToolPayload
    case emptyAfterSanitization
}

nonisolated enum FinalOutputSanitizer {
    static let fallback = "I hit an internal response-format issue. Please try again."
    private static let lock = NSLock()
    private static var recoveredBySanitizedText: [String: SanitizedFinalOutput] = [:]

    static func sanitizeUserVisibleText(_ raw: String) -> SanitizedFinalOutput {
        var text = raw
        var removed: [FinalOutputArtifact] = []

        func mark(_ artifact: FinalOutputArtifact) { if !removed.contains(artifact) { removed.append(artifact) } }

        let originalLower = raw.lowercased()
        if originalLower.contains("<think") || originalLower.contains("</think>") { mark(.thinkBlock) }
        if originalLower.contains("<lumen_web_payload") || originalLower.contains("</lumen_web_payload>") { mark(.lumenWebPayload) }
        if originalLower.contains("{\"kind\":\"searchresults\"") || originalLower.contains("\"mediakind\":\"page\"") { mark(.rawToolPayload) }

        text = text.replacingOccurrences(of: "(?is)<think>.*?</think>", with: " ", options: .regularExpression)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("<think>") {
            text = ""
            mark(.malformedThinkPrefix)
        }
        text = text.replacingOccurrences(of: "(?is)^\\s*<think>.*$", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?is)<lumen_web_payload>.*?</lumen_web_payload>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?is)<lumen_web_payload[^>]*>.*$", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?is)</lumen_web_payload>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?is)\\{\\s*\"kind\"\\s*:\\s*\"searchResults\".*?\\}", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?is)\"mediaKind\"\\s*:\\s*\"page\"", with: " ", options: .regularExpression)

        text = text.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.isEmpty {
            mark(.emptyAfterSanitization)
            text = fallback
        }

        let output = SanitizedFinalOutput(text: text, removedArtifacts: removed, hadUnsafeLeakage: !removed.isEmpty)
        lock.lock()
        recoveredBySanitizedText[output.text] = output
        lock.unlock()
        return output
    }

    static func consumeRecoveredUnsafeOutput(forSanitizedText text: String) -> SanitizedFinalOutput? {
        lock.lock()
        defer { lock.unlock() }
        return recoveredBySanitizedText.removeValue(forKey: text)
    }
}
