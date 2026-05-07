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

    static func sanitizeUserVisibleText(_ raw: String) -> SanitizedFinalOutput {
        var text = raw
        var removed: [FinalOutputArtifact] = []

        func mark(_ artifact: FinalOutputArtifact) {
            if !removed.contains(artifact) {
                removed.append(artifact)
            }
        }

        let originalLower = raw.lowercased()
        if originalLower.contains("<think") || originalLower.contains("</think>") {
            mark(.thinkBlock)
        }
        if originalLower.contains("<lumen_web_payload") || originalLower.contains("</lumen_web_payload>") {
            mark(.lumenWebPayload)
        }
        if containsRawToolPayloadMarker(originalLower) {
            mark(.rawToolPayload)
        }

        text = text.replacingOccurrences(of: "(?is)<think>.*?</think>", with: " ", options: .regularExpression)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("<think>") {
            text = ""
            mark(.malformedThinkPrefix)
        }
        text = text.replacingOccurrences(of: "(?is)^\\s*<think>.*$", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?is)<lumen_web_payload>.*?</lumen_web_payload>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?is)<lumen_web_payload[^>]*>.*$", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?is)</lumen_web_payload>", with: " ", options: .regularExpression)

        let rawPayloadRemoval = removingRawToolPayloadObjects(from: text)
        if rawPayloadRemoval.removedAny {
            text = rawPayloadRemoval.text
            mark(.rawToolPayload)
        }

        text = normalizeWhitespace(text)

        if text.isEmpty {
            mark(.emptyAfterSanitization)
            text = fallback
        }

        return SanitizedFinalOutput(text: text, removedArtifacts: removed, hadUnsafeLeakage: !removed.isEmpty)
    }

    private static func normalizeWhitespace(_ text: String) -> String {
        text
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsRawToolPayloadMarker(_ lowercasedText: String) -> Bool {
        lowercasedText.contains("{\"kind\":\"searchresults\"")
            || lowercasedText.contains("\"kind\" : \"searchresults\"")
            || lowercasedText.contains("\"mediakind\":\"page\"")
            || lowercasedText.contains("\"mediakind\" : \"page\"")
            || lowercasedText.contains("\"sourcepageurl\"")
    }

    private static func removingRawToolPayloadObjects(from source: String) -> (text: String, removedAny: Bool) {
        var output = ""
        var index = source.startIndex
        var removedAny = false

        while index < source.endIndex {
            guard source[index] == "{" else {
                output.append(source[index])
                index = source.index(after: index)
                continue
            }

            guard let objectEnd = balancedJSONObjectEnd(in: source, from: index) else {
                output.append(source[index])
                index = source.index(after: index)
                continue
            }

            let nextIndex = source.index(after: objectEnd)
            let candidate = String(source[index..<nextIndex])
            if containsRawToolPayloadMarker(candidate.lowercased()) {
                output.append(" ")
                removedAny = true
            } else {
                output.append(candidate)
            }
            index = nextIndex
        }

        return (output, removedAny)
    }

    private static func balancedJSONObjectEnd(in source: String, from start: String.Index) -> String.Index? {
        var index = start
        var depth = 0
        var isInsideString = false
        var isEscaped = false

        while index < source.endIndex {
            let character = source[index]

            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInsideString = false
                }
            } else {
                if character == "\"" {
                    isInsideString = true
                } else if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        return index
                    }
                }
            }

            index = source.index(after: index)
        }

        return nil
    }
}
