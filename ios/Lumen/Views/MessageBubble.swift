import SwiftUI
import SwiftData

struct MessageBubble: View {
    let message: ChatMessage
    var streamingOverride: String? = nil

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
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                if !steps.isEmpty {
                    AgentStepsPanel(steps: steps, expanded: false)
                }
                Text(streamingOverride ?? message.content)
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if streamingOverride == nil {
                    HStack(spacing: 10) {
                        if message.wasStopped {
                            HStack(spacing: 4) {
                                Image(systemName: "stop.circle")
                                    .font(.caption2)
                                Text("Stopped")
                                    .font(.caption2.weight(.medium))
                            }
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .overlay {
                                RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border, lineWidth: 1)
                            }
                        }
                        MessageActionButton(icon: "doc.on.doc") {
                            UIPasteboard.general.string = message.content
                        }
                        MessageActionButton(icon: "bookmark") { /* remember */ }
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 32)
        }
    }
}

struct MessageActionButton: View {
    let icon: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
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
                    Text(tool?.name ?? toolID)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text(statusLabel)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
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
                        Button(role: .destructive) { deny() } label: {
                            Text("Deny").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button { approve() } label: {
                            Text("Approve").frame(maxWidth: .infinity).fontWeight(.medium)
                        }
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
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        }
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
        message.toolStatus = ToolStatus.running.rawValue
        let args = parseArgs(message.content)
        Task {
            let result = await ToolExecutor.shared.execute(message.toolName ?? "", arguments: args)
            message.toolStatus = ToolStatus.completed.rawValue
            message.toolResult = result
            try? modelContext.save()
        }
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
