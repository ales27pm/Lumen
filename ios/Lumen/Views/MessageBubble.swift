import SwiftUI
import SwiftData

struct MessageBubble: View {
    let message: ChatMessage
    var streamingOverride: String? = nil

    @Environment(\.modelContext) private var modelContext
    @State private var didBookmark: Bool = false
    @State private var webPreview: WebPreviewItem?
    @State private var mapPreview: MapPreviewItem?
    @State private var imagePreview: ImagePreviewItem?
    @State private var videoPreview: VideoPreviewItem?
    @State private var pdfPreview: PDFPreviewItem?

    private var assistantVisibleContent: String {
        AssistantOutputSanitizer.sanitize(streamingOverride ?? message.content)
    }

    static func streaming(text: String) -> some View {
        let fake = ChatMessage(role: .assistant, content: text)
        return MessageBubble(message: fake, streamingOverride: text)
    }

    var body: some View {
        switch message.messageRole {
        case .user:
            userBubble
        case .assistant:
            assistantBubble
        case .tool:
            ToolCallCard(message: message)
        case .system:
            EmptyView()
        }
    }

    private var userBubble: some View {
        HStack(alignment: .top) {
            Spacer(minLength: 48)
            Text(message.content)
                .font(.body)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Theme.accent)
                .clipShape(.rect(cornerRadius: 12))
        }
    }

    private var assistantBubble: some View {
        let steps = streamingOverride == nil ? message.agentSteps : []
        let visibleContent = assistantVisibleContent
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                if !steps.isEmpty {
                    AgentStepsPanel(steps: steps, expanded: false)
                }
                Text(visibleContent)
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if streamingOverride == nil {
                    if let webURL = firstWebURL(from: visibleContent) {
                        EmbeddedContentButton(icon: "globe", title: "Open Web Page", subtitle: webURL.host() ?? webURL.absoluteString) {
                            webPreview = WebPreviewItem(url: webURL)
                        }
                    }
                    if let mapQuery = firstMapQuery(from: visibleContent) {
                        EmbeddedContentButton(icon: "map", title: "Open Map", subtitle: mapQuery) {
                            mapPreview = MapPreviewItem(query: mapQuery)
                        }
                    }
                    if let imageURL = firstImageURL(from: visibleContent) {
                        EmbeddedContentButton(icon: "photo", title: "Open Image", subtitle: imageURL.lastPathComponent.isEmpty ? (imageURL.host() ?? imageURL.absoluteString) : imageURL.lastPathComponent) {
                            imagePreview = ImagePreviewItem(url: imageURL)
                        }
                    }
                    if let videoURL = firstVideoURL(from: visibleContent) {
                        EmbeddedContentButton(icon: "play.rectangle", title: "Open Video", subtitle: videoURL.lastPathComponent.isEmpty ? (videoURL.host() ?? videoURL.absoluteString) : videoURL.lastPathComponent) {
                            videoPreview = VideoPreviewItem(url: videoURL)
                        }
                    }
                    if let pdfURL = firstPDFURL(from: visibleContent) {
                        EmbeddedContentButton(icon: "doc.richtext", title: "Open PDF", subtitle: pdfURL.lastPathComponent.isEmpty ? (pdfURL.host() ?? pdfURL.absoluteString) : pdfURL.lastPathComponent) {
                            pdfPreview = PDFPreviewItem(url: pdfURL)
                        }
                    }

                    HStack(spacing: 10) {
                        if message.wasStopped {
                            HStack(spacing: 4) {
                                Image(systemName: "stop.circle").font(.caption2)
                                Text("Stopped").font(.caption2.weight(.medium))
                            }
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border, lineWidth: 1) }
                        }
                        MessageActionButton(icon: "doc.on.doc") {
                            UIPasteboard.general.string = visibleContent
                        }
                        MessageActionButton(icon: didBookmark ? "bookmark.fill" : "bookmark") { bookmark(content: visibleContent) }
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 32)
        }
        .sheet(item: $webPreview) { item in EmbeddedWebBrowserSheet(url: item.url) }
        .sheet(item: $mapPreview) { item in EmbeddedMapSheet(query: item.query) }
        .sheet(item: $imagePreview) { item in EmbeddedImageSheet(url: item.url) }
        .sheet(item: $videoPreview) { item in EmbeddedVideoSheet(url: item.url) }
        .sheet(item: $pdfPreview) { item in EmbeddedPDFSheet(url: item.url) }
    }

    private func firstWebURL(from text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let ns = text as NSString
        let matches = detector.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        let mediaExt: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "bmp", "mp4", "mov", "m4v", "webm", "pdf"]
        for match in matches {
            guard let url = match.url else { continue }
            let host = url.host()?.lowercased() ?? ""
            if host.contains("maps.apple.com") { continue }
            if mediaExt.contains(url.pathExtension.lowercased()) { continue }
            return url
        }
        return nil
    }

    private func firstMapQuery(from text: String) -> String? {
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let ns = text as NSString
            let matches = detector.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
            for match in matches {
                guard let url = match.url, (url.host()?.lowercased().contains("maps.apple.com") == true) else { continue }
                if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                    if let daddr = comps.queryItems?.first(where: { $0.name == "daddr" })?.value, !daddr.isEmpty { return daddr }
                    if let q = comps.queryItems?.first(where: { $0.name == "q" })?.value, !q.isEmpty { return q }
                }
            }
        }

        let prefix = "Opening Maps with directions to "
        if text.hasPrefix(prefix) {
            let value = text.dropFirst(prefix.count).trimmingCharacters(in: CharacterSet(charactersIn: ". \n"))
            if !value.isEmpty { return value }
        }
        return nil
    }

    private func firstImageURL(from text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let ns = text as NSString
        let matches = detector.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        let imageExt: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "bmp"]
        for match in matches {
            guard let url = match.url else { continue }
            if imageExt.contains(url.pathExtension.lowercased()) { return url }
        }
        return nil
    }

    private func firstVideoURL(from text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let ns = text as NSString
        let matches = detector.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        let videoExt: Set<String> = ["mp4", "mov", "m4v", "webm"]
        for match in matches {
            guard let url = match.url else { continue }
            if videoExt.contains(url.pathExtension.lowercased()) { return url }
        }
        return nil
    }

    private func firstPDFURL(from text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let ns = text as NSString
        let matches = detector.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        for match in matches {
            guard let url = match.url else { continue }
            if url.pathExtension.lowercased() == "pdf" { return url }
        }
        return nil
    }

    private func bookmark(content: String) {
        guard !didBookmark else { return }
        let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        didBookmark = true
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        let snippet = String(cleaned.prefix(400))
        let ctx = modelContext
        Task { @MainActor in
            await MemoryStore.remember(snippet, kind: .fact, source: "bookmark", context: ctx)
        }
    }
}

private struct WebPreviewItem: Identifiable { let id = UUID(); let url: URL }
private struct MapPreviewItem: Identifiable { let id = UUID(); let query: String }
private struct ImagePreviewItem: Identifiable { let id = UUID(); let url: URL }
private struct VideoPreviewItem: Identifiable { let id = UUID(); let url: URL }
private struct PDFPreviewItem: Identifiable { let id = UUID(); let url: URL }

private struct EmbeddedContentButton: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.caption).foregroundStyle(Theme.textSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                    Text(subtitle).font(.caption2).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Theme.textTertiary)
            }
            .padding(8)
            .background(Theme.surfaceHigh)
            .clipShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

struct MessageActionButton: View {
    let icon: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.caption).foregroundStyle(Theme.textTertiary)
        }
        .buttonStyle(.plain)
    }
}

struct ToolCallCard: View {
    @Bindable var message: ChatMessage
    @Environment(\.modelContext) private var modelContext
    @State private var expanded: Bool = true

    var body: some View {
        let toolID = message.toolName ?? ""
        let tool = ToolRegistry.find(id: toolID)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: tool?.icon ?? "wrench.and.screwdriver")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tool?.name ?? toolID).font(.subheadline.weight(.medium)).foregroundStyle(Theme.textPrimary)
                    Text(statusLabel).font(.caption).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }

            if expanded {
                if !message.content.isEmpty {
                    Text(message.content)
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Theme.surfaceHigh)
                        .clipShape(.rect(cornerRadius: 8))
                }

                if message.status == .pendingApproval {
                    HStack(spacing: 8) {
                        Button(role: .destructive) { deny() } label: { Text("Deny").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered)
                        Button { approve() } label: { Text("Approve").frame(maxWidth: .infinity).fontWeight(.medium) }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accent)
                    }
                } else if let result = message.toolResult, !result.isEmpty {
                    Text(result)
                        .font(.footnote)
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Theme.surfaceHigh)
                        .clipShape(.rect(cornerRadius: 8))
                }
            }
        }
        .padding(12)
        .background(Theme.surface)
        .clipShape(.rect(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border, lineWidth: 1) }
    }

    private var statusLabel: String {
        switch message.status {
        case .pendingApproval: "Waiting for approval"
        case .running: "Running"
        case .completed: "Completed"
        case .denied: "Denied"
        case .failed: "Failed"
        case .none: "Tool call"
        }
    }

    private func approve() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let toolID = message.toolName ?? ""
        let args = parseArgs(message.content)
        let routing = IntentRouter.classify(inferredUserPrompt())
        guard IntentRouter.isToolAllowed(toolID, for: routing) else {
            message.toolStatus = ToolStatus.denied.rawValue
            message.toolResult = IntentRouter.blockedToolMessage(for: routing)
            try? modelContext.save()
            return
        }

        message.toolStatus = ToolStatus.running.rawValue
        Task {
            let result = await ToolExecutor.shared.execute(
                toolID,
                arguments: args,
                approval: .userApproved
            )
            message.toolStatus = ToolStatus.completed.rawValue
            message.toolResult = FinalIntentValidator.validate(result, routing: routing, fallback: nil)
            try? modelContext.save()
        }
    }

    private func inferredUserPrompt() -> String {
        guard let conversation = message.conversation else { return message.content }
        let sorted = conversation.sortedMessages
        guard let currentIndex = sorted.firstIndex(where: { $0.id == message.id }) else {
            return sorted.last(where: { $0.messageRole == .user })?.content ?? message.content
        }
        let previous = sorted[..<currentIndex].last(where: { $0.messageRole == .user })
        return previous?.content ?? message.content
    }

    private func deny() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        message.toolStatus = ToolStatus.denied.rawValue
        message.toolResult = "Denied by user."
        try? modelContext.save()
    }

    private func parseArgs(_ string: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in string.components(separatedBy: ",") {
            let parts = pair.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { out[parts[0]] = parts[1] }
        }
        return out
    }
}
