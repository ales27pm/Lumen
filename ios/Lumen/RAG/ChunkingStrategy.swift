import Foundation

enum ChunkingContentType { case plain, markdown, code }
struct ChunkingConfig { let maxChars: Int; let overlap: Int }
struct ChunkPiece: Sendable { let text: String; let start: Int; let end: Int }

enum ChunkingStrategy {
    static func chunk(_ text: String, type: ChunkingContentType, config: ChunkingConfig = .init(maxChars: 700, overlap: 80)) -> [ChunkPiece] {
        let units: [String]
        switch type {
        case .markdown: units = text.components(separatedBy: "\n#")
        case .code: units = text.components(separatedBy: "\nfunc ")
        case .plain: units = text.components(separatedBy: "\n\n")
        }
        var out: [ChunkPiece] = []; var cursor = 0
        for u in units {
            let t = u.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            var i = 0
            while i < t.count {
                let end = min(t.count, i + config.maxChars)
                let sidx = t.index(t.startIndex, offsetBy: i)
                let eidx = t.index(t.startIndex, offsetBy: end)
                let seg = String(t[sidx..<eidx])
                out.append(.init(text: seg, start: cursor + i, end: cursor + end))
                if end == t.count { break }
                i = max(0, end - config.overlap)
            }
            cursor += t.count + 2
        }
        return out
    }
}
