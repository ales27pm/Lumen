import Foundation

nonisolated enum WebTools {
    static func webSearch(query: String) async -> String {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Need a query." }
        let q = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        guard let url = URL(string: "https://duckduckgo.com/?q=\(q)&format=json&no_redirect=1&no_html=1") else {
            return "Invalid query."
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return "No results."
            }
            var lines: [String] = []
            if let abstract = obj["AbstractText"] as? String, !abstract.isEmpty {
                lines.append(abstract)
                if let src = obj["AbstractURL"] as? String, !src.isEmpty { lines.append(src) }
            }
            if let related = obj["RelatedTopics"] as? [[String: Any]] {
                for item in related.prefix(5) {
                    if let text = item["Text"] as? String, !text.isEmpty {
                        lines.append("• \(text)")
                    }
                }
            }
            if lines.isEmpty {
                return "No direct answer. Try a different phrasing, or use web.fetch with a URL."
            }
            return lines.joined(separator: "\n")
        } catch {
            return "Search failed: \(error.localizedDescription)"
        }
    }

    static func webFetch(url: String) async -> String {
        guard let u = URL(string: url) else { return "Invalid URL." }
        do {
            var req = URLRequest(url: u)
            req.setValue("Mozilla/5.0 (iPhone; Lumen/2.0)", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 20
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let html = String(data: data, encoding: .utf8) else { return "Couldn't decode page." }
            let text = stripHTML(html)
            let trimmed = String(text.prefix(2000))
            return trimmed.isEmpty ? "Page was empty." : trimmed
        } catch {
            return "Fetch failed: \(error.localizedDescription)"
        }
    }

    private static func stripHTML(_ html: String) -> String {
        var s = html
        if let range = s.range(of: "<body", options: .caseInsensitive) {
            s = String(s[range.lowerBound...])
        }
        let patterns = ["<script[\\s\\S]*?</script>", "<style[\\s\\S]*?</style>", "<[^>]+>"]
        for p in patterns {
            s = s.replacingOccurrences(of: p, with: " ", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
