import Foundation
import WebKit

@MainActor
nonisolated enum WebTools {
    private static let searchPolicy = ToolRetryPolicy(maxAttempts: 3, baseDelay: 0.35, maxDelay: 1.5, jitterRatio: 0.25)
    private static let fetchPolicy = ToolRetryPolicy(maxAttempts: 2, baseDelay: 0.4, maxDelay: 1.2, jitterRatio: 0.2)

    static func webSearch(query: String) async -> String {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Need a query." }
        let q = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        guard let url = URL(string: "https://duckduckgo.com/?q=\(q)&format=json&no_redirect=1&no_html=1") else {
            return "Invalid query."
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; Lumen/2.0)", forHTTPHeaderField: "User-Agent")

        let result = await executeWebRequest(endpoint: "duckduckgo.search", request: request, timeout: 8, retryPolicy: searchPolicy, context: "Web search")
        switch result {
        case .failure(let message): return message
        case .success(let body, _):
            guard let data = body.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return ToolNetworkResilience.fallbackMessage(for: .parsing, context: "Web search")
            }
            var lines: [String] = []
            if let abstract = obj["AbstractText"] as? String, !abstract.isEmpty {
                lines.append(abstract)
                if let src = obj["AbstractURL"] as? String, !src.isEmpty { lines.append(src) }
            }
            if let related = obj["RelatedTopics"] as? [[String: Any]] {
                for item in related.prefix(5) {
                    if let text = item["Text"] as? String, !text.isEmpty { lines.append("• \(text)") }
                }
            }
            return lines.isEmpty ? "No direct answer. Try a different phrasing, or use web.fetch with a URL." : lines.joined(separator: "\n")
        }
    }

    static func webFetch(url: String) async -> String {
        guard let u = URL(string: url) else { return "Invalid URL." }
        var req = URLRequest(url: u)
        req.setValue("Mozilla/5.0 (iPhone; Lumen/2.0)", forHTTPHeaderField: "User-Agent")

        let result = await executeWebRequest(endpoint: "web.fetch", request: req, timeout: 12, retryPolicy: fetchPolicy, context: "Web page fetch")
        switch result {
        case .failure(let message): return message
        case .success(let html, _):
            let text = stripHTML(html)
            let trimmed = String(text.prefix(2000))
            return trimmed.isEmpty ? "Page was empty." : trimmed
        }
    }

    private static func executeWebRequest(endpoint: String, request: URLRequest, timeout: TimeInterval, retryPolicy: ToolRetryPolicy, context: String) async -> Result<(String, HTTPURLResponse?), String> {
        if !(await ToolNetworkResilience.circuitBreaker.allowRequest(endpoint: endpoint)) {
            return .failure(ToolNetworkResilience.fallbackMessage(for: .circuitOpen, context: context))
        }

        var retries = 0
        let started = Date()
        for attempt in 1...retryPolicy.maxAttempts {
            do {
                let (content, response) = try await WebViewRequestLoader.load(request: request, timeout: timeout)
                let errorClass = ToolNetworkResilience.classify(error: nil, response: response)
                if let status = response?.statusCode, !(200..<300).contains(status) {
                    if ToolNetworkResilience.shouldRetry(errorClass: errorClass), attempt < retryPolicy.maxAttempts {
                        retries += 1
                        try? await Task.sleep(nanoseconds: ToolNetworkResilience.backoffDelay(attempt: attempt, policy: retryPolicy))
                        continue
                    }
                    await ToolNetworkResilience.circuitBreaker.record(endpoint: endpoint, success: false)
                    ToolNetworkTelemetry.emit(.init(endpoint: endpoint, latencyMs: Date().timeIntervalSince(started) * 1000, success: false, errorClass: errorClass, retryCount: retries, statusCode: status))
                    return .failure(ToolNetworkResilience.fallbackMessage(for: errorClass, context: context))
                }

                await ToolNetworkResilience.circuitBreaker.record(endpoint: endpoint, success: true)
                ToolNetworkTelemetry.emit(.init(endpoint: endpoint, latencyMs: Date().timeIntervalSince(started) * 1000, success: true, errorClass: nil, retryCount: retries, statusCode: response?.statusCode))
                return .success((content, response))
            } catch {
                let errorClass = ToolNetworkResilience.classify(error: error, response: nil)
                if ToolNetworkResilience.shouldRetry(errorClass: errorClass), attempt < retryPolicy.maxAttempts {
                    retries += 1
                    try? await Task.sleep(nanoseconds: ToolNetworkResilience.backoffDelay(attempt: attempt, policy: retryPolicy))
                    continue
                }
                await ToolNetworkResilience.circuitBreaker.record(endpoint: endpoint, success: false)
                ToolNetworkTelemetry.emit(.init(endpoint: endpoint, latencyMs: Date().timeIntervalSince(started) * 1000, success: false, errorClass: errorClass, retryCount: retries, statusCode: nil))
                return .failure(ToolNetworkResilience.fallbackMessage(for: errorClass, context: context))
            }
        }
        return .failure(ToolNetworkResilience.fallbackMessage(for: .unknown, context: context))
    }

    private static func stripHTML(_ html: String) -> String {
        var s = html
        if let range = s.range(of: "<body", options: .caseInsensitive) {
            s = String(s[range.lowerBound...])
        }
        let patterns = ["<script[\\s\\S]*?</script>", "<style[\\s\\S]*?</style>", "<[^>]+>"]
        for p in patterns { s = s.replacingOccurrences(of: p, with: " ", options: .regularExpression) }
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
private final class WebViewRequestLoader: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<(String, HTTPURLResponse?), Error>?
    private var response: HTTPURLResponse?
    private lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        return view
    }()

    static func load(request: URLRequest, timeout: TimeInterval) async throws -> (String, HTTPURLResponse?) {
        let loader = WebViewRequestLoader()
        return try await loader.load(request: request, timeout: timeout)
    }

    private func load(request: URLRequest, timeout: TimeInterval) async throws -> (String, HTTPURLResponse?) {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            _ = webView.load(request)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, let continuation = self.continuation else { return }
                self.continuation = nil
                self.webView.stopLoading()
                continuation.resume(throwing: URLError(.timedOut))
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let continuation = continuation else { return }
        self.continuation = nil
        webView.evaluateJavaScript("document.documentElement.outerHTML.toString()") { result, error in
            if let error {
                continuation.resume(throwing: error)
                return
            }
            let html = result as? String ?? ""
            continuation.resume(returning: (html, self.response))
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard let continuation = continuation else { return }
        self.continuation = nil
        continuation.resume(throwing: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard let continuation = continuation else { return }
        self.continuation = nil
        continuation.resume(throwing: error)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        response = navigationResponse.response as? HTTPURLResponse
        return .allow
    }
}
