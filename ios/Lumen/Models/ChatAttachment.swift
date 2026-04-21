import Foundation
import PDFKit

nonisolated struct ChatAttachment: Sendable, Hashable, Identifiable {
    enum Kind: String, Sendable {
        case text
        case pdf

        var icon: String {
            switch self {
            case .text: "doc.text"
            case .pdf: "doc.richtext"
            }
        }
    }

    let id: UUID
    let name: String
    let kind: Kind
    /// Absolute path inside the app's Imports directory.
    let path: String
    /// Approximate byte size of the imported file (for UI).
    let byteSize: Int

    init(id: UUID = UUID(), name: String, kind: Kind, path: String, byteSize: Int) {
        self.id = id
        self.name = name
        self.kind = kind
        self.path = path
        self.byteSize = byteSize
    }
}

nonisolated enum AttachmentResolver {
    /// Maximum characters of content injected per attachment. Keeps prompts bounded.
    static let maxCharsPerAttachment = 6000

    static func make(from url: URL) -> ChatAttachment? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        let ext = url.pathExtension.lowercased()
        let kind: ChatAttachment.Kind = (ext == "pdf") ? .pdf : .text
        return ChatAttachment(name: url.lastPathComponent, kind: kind, path: url.path, byteSize: size)
    }

    /// Extracts readable text for prompt injection. Always bounded.
    static func extractText(_ a: ChatAttachment) -> String {
        let url = URL(fileURLWithPath: a.path)
        switch a.kind {
        case .pdf:
            guard let pdf = PDFDocument(url: url) else { return "" }
            var out = ""
            for i in 0..<pdf.pageCount {
                out += pdf.page(at: i)?.string ?? ""
                out += "\n"
                if out.count >= maxCharsPerAttachment { break }
            }
            return String(out.prefix(maxCharsPerAttachment))
        case .text:
            guard let data = try? Data(contentsOf: url) else { return "" }
            if let utf8 = String(data: data, encoding: .utf8) {
                return String(utf8.prefix(maxCharsPerAttachment))
            }
            if let latin = String(data: data, encoding: .isoLatin1) {
                return String(latin.prefix(maxCharsPerAttachment))
            }
            if let attr = try? NSAttributedString(data: data, options: [:], documentAttributes: nil) {
                return String(attr.string.prefix(maxCharsPerAttachment))
            }
            return ""
        }
    }

    /// Formatted block appended to the system prompt describing all attachments.
    static func contextBlock(for attachments: [ChatAttachment]) -> String {
        guard !attachments.isEmpty else { return "" }
        var out = "\nThe user attached the following file(s) to this message. Their contents are provided below as authoritative context — prefer them over memory or guesses. Do not call files.read for these; they are already visible.\n"
        for (i, a) in attachments.enumerated() {
            let body = extractText(a).trimmingCharacters(in: .whitespacesAndNewlines)
            out += "\n--- Attachment \(i + 1): \(a.name) (\(a.kind.rawValue)) ---\n"
            if body.isEmpty {
                out += "[Could not extract text from this file.]\n"
            } else {
                out += body
                out += "\n"
            }
        }
        out += "--- End attachments ---\n"
        return out
    }
}
