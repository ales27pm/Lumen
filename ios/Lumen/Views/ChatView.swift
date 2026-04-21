import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ChatView: View {
    @Bindable var conversation: Conversation
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Query private var storedModels: [StoredModel]

    @State private var draft: String = ""
    @State private var streamingText: String = ""
    @State private var streamingSteps: [AgentStep] = []
    @State private var streamingTask: Task<Void, Never>?
    @State private var showVoiceMode = false
    @State private var showFilePicker = false
    @State private var attachedFileName: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(conversation.sortedMessages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                        if !streamingSteps.isEmpty {
                            AgentStepsPanel(steps: streamingSteps, expanded: true)
                                .id("steps")
                        }
                        if !streamingText.isEmpty {
                            MessageBubble.streaming(text: streamingText)
                                .id("streaming")
                        }
                        Color.clear.frame(height: 8).id("bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }
                .scrollDismissesKeyboard(.immediately)
                .contentShape(Rectangle())
                .onTapGesture { isFocused = false }
                .onChange(of: conversation.messages.count) { _, _ in
                    withAnimation(.spring) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: streamingText) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: streamingSteps.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }

            Divider().background(Theme.border)

            if let name = attachedFileName {
                HStack(spacing: 8) {
                    Image(systemName: "paperclip")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                    Text(name)
                        .font(.caption).foregroundStyle(Theme.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button {
                        attachedFileName = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption).foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Theme.surface)
                .clipShape(.rect(cornerRadius: 8))
                .padding(.horizontal, 12).padding(.top, 6)
            }

            ChatInputBar(
                draft: $draft,
                isFocused: _isFocused,
                isGenerating: appState.isGenerating,
                onSend: { send(text: nil) },
                onStop: stop,
                onVoice: { showVoiceMode = true },
                onAttach: { showFilePicker = true },
                onDismissKeyboard: { isFocused = false }
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.background)
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { isFocused = false }
            }
        }
        .fullScreenCover(isPresented: $showVoiceMode) {
            VoiceModeView(onTranscript: { text in
                showVoiceMode = false
                send(text: text)
            })
        }
        .fileImporter(isPresented: $showFilePicker,
                      allowedContentTypes: [.plainText, .pdf, .text, .utf8PlainText, .rtf, .commaSeparatedText, .json, .xml, .html, .sourceCode, UTType(filenameExtension: "md") ?? .plainText],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                if FileStore.importFile(from: url) != nil {
                    attachedFileName = url.lastPathComponent
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                }
            }
        }
    }

    private func send(text overrideText: String?) {
        let source = overrideText ?? draft
        var text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if let attached = attachedFileName {
            let note = text.isEmpty
                ? "I've attached the file \"\(attached)\". Use the files.read tool to read it, then answer my follow-up questions."
                : "\(text)\n\n(Attached file: \"\(attached)\" — use files.read to access it.)"
            text = note
        }
        guard !text.isEmpty, !appState.isGenerating else { return }
        if overrideText == nil { draft = ""; attachedFileName = nil }

        let userMsg = ChatMessage(role: .user, content: text)
        conversation.messages.append(userMsg)
        conversation.updatedAt = Date()
        if conversation.title == "New Chat" {
            conversation.title = String(text.prefix(36))
        }
        try? modelContext.save()

        UIImpactFeedbackGenerator(style: .soft).impactOccurred()

        appState.isGenerating = true
        streamingText = ""
        streamingSteps = []

        streamingTask = Task {
            if !(await ensureChatModelLoaded()) {
                let msg = ChatMessage(role: .assistant, content: "No chat model is loaded. Open the Models tab, download a chat model, and tap Use to activate it.")
                conversation.messages.append(msg)
                try? modelContext.save()
                appState.isGenerating = false
                return
            }
            let memories = await MemoryStore.recall(query: text, context: modelContext).map(\.content)

            if appState.agentModeEnabled {
                await runAgent(text: text, memories: memories)
            } else {
                await runPlain(text: text, memories: memories)
            }
        }
    }

    private func runAgent(text: String, memories: [String]) async {
        let history = conversation.sortedMessages.dropLast().map { ($0.messageRole, $0.content) }
        let tools = ToolRegistry.all.filter { appState.enabledToolIDs.contains($0.id) }
        let req = AgentRequest(
            systemPrompt: conversation.systemPrompt ?? appState.systemPrompt,
            history: Array(history),
            userMessage: text,
            temperature: appState.temperature,
            topP: appState.topP,
            repetitionPenalty: appState.repetitionPenalty,
            maxTokens: appState.maxTokens,
            maxSteps: appState.maxAgentSteps,
            availableTools: tools,
            relevantMemories: memories
        )

        var steps: [AgentStep] = []
        var finalText = ""

        for await event in await AgentService.shared.run(req) {
            if Task.isCancelled { break }
            switch event {
            case .step(let step):
                if let idx = steps.firstIndex(where: { $0.id == step.id }) {
                    steps[idx] = step
                } else {
                    steps.append(step)
                }
                streamingSteps = steps
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            case .stepDelta(let id, let text):
                if let idx = steps.firstIndex(where: { $0.id == id }) {
                    steps[idx].content = text
                    streamingSteps = steps
                }
            case .finalDelta(let chunk):
                finalText += chunk
                streamingText = finalText
            case .done(let final, let allSteps):
                finalText = final.isEmpty ? finalText : final
                steps = allSteps
            case .error(let msg):
                finalText = msg
            }
        }

        let assistantMsg = ChatMessage(role: .assistant, content: finalText, agentSteps: steps)
        conversation.messages.append(assistantMsg)
        streamingText = ""
        streamingSteps = []

        if appState.autoMemory, finalText.count > 60 {
            await MemoryStore.remember(
                "User asked: \(text). Assistant: \(String(finalText.prefix(160)))",
                kind: .conversation, source: "chat", context: modelContext
            )
            await MemoryStore.extractAndStore(userText: text, assistantText: finalText, context: modelContext)
        }

        conversation.updatedAt = Date()
        try? modelContext.save()
        appState.isGenerating = false
    }

    private func runPlain(text: String, memories: [String]) async {
        let request = GenerateRequest(
            systemPrompt: conversation.systemPrompt ?? appState.systemPrompt,
            history: conversation.sortedMessages.dropLast().map { ($0.messageRole, $0.content) },
            userMessage: text,
            temperature: appState.temperature,
            topP: appState.topP,
            repetitionPenalty: appState.repetitionPenalty,
            maxTokens: appState.maxTokens,
            modelName: conversation.modelName ?? "default",
            availableTools: ToolRegistry.all.filter { appState.enabledToolIDs.contains($0.id) },
            relevantMemories: memories
        )

        var accumulated = ""
        for await token in await LlamaService.shared.stream(request) {
            switch token {
            case .text(let s):
                accumulated += s
                streamingText = accumulated
            case .toolCall, .done:
                break
            }
        }

        let assistantMsg = ChatMessage(role: .assistant, content: accumulated)
        conversation.messages.append(assistantMsg)
        streamingText = ""

        if appState.autoMemory, accumulated.count > 60 {
            await MemoryStore.remember(
                "User asked: \(text). Assistant said: \(accumulated.prefix(140))",
                kind: .conversation, source: "chat", context: modelContext
            )
        }

        conversation.updatedAt = Date()
        try? modelContext.save()
        appState.isGenerating = false
    }

    private func ensureChatModelLoaded() async -> Bool {
        if await LlamaService.shared.isChatLoaded { return true }
        guard let id = appState.activeChatModelID,
              let m = storedModels.first(where: { $0.id.uuidString == id }),
              m.modelRole == .chat,
              FileManager.default.fileExists(atPath: m.localPath) else {
            if let fallback = storedModels.first(where: { $0.modelRole == .chat && FileManager.default.fileExists(atPath: $0.localPath) }) {
                appState.activeChatModelID = fallback.id.uuidString
                appState.persist()
                do {
                    try await LlamaService.shared.loadChatModel(path: fallback.localPath, contextSize: appState.contextSize)
                    return true
                } catch {
                    return false
                }
            }
            return false
        }
        do {
            try await LlamaService.shared.loadChatModel(path: m.localPath, contextSize: appState.contextSize)
            return true
        } catch {
            return false
        }
    }

    private func stop() {
        let task = streamingTask
        streamingTask = nil
        task?.cancel()
        let captured = streamingText
        let capturedSteps = streamingSteps
        streamingText = ""
        streamingSteps = []
        Task {
            _ = await task?.value
            await MainActor.run {
                appState.isGenerating = false
                if !captured.isEmpty {
                    let msg = ChatMessage(role: .assistant, content: captured, agentSteps: capturedSteps, wasStopped: true)
                    conversation.messages.append(msg)
                    conversation.updatedAt = Date()
                    try? modelContext.save()
                }
            }
        }
    }
}

struct ChatInputBar: View {
    @Binding var draft: String
    @FocusState var isFocused: Bool
    var isGenerating: Bool
    var onSend: () -> Void
    var onStop: () -> Void
    var onVoice: () -> Void
    var onAttach: () -> Void
    var onDismissKeyboard: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isFocused {
                Button(action: onDismissKeyboard) {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.body)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
            } else {
                Button(action: onAttach) {
                    Image(systemName: "paperclip")
                        .font(.body)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
            }

            HStack(alignment: .bottom, spacing: 4) {
                TextField("Message Lumen", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($isFocused)
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                    .tint(Theme.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)

                if !draft.isEmpty {
                    Button { draft = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.trailing, 8)
                }
            }
            .background(Theme.surface)
            .clipShape(.rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            }

            if draft.trimmingCharacters(in: .whitespaces).isEmpty && !isGenerating {
                Button(action: onVoice) {
                    Image(systemName: "waveform")
                        .font(.body)
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 36, height: 36)
                        .background(Theme.surface)
                        .clipShape(.rect(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Theme.border, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    if isGenerating { onStop() } else { onSend() }
                } label: {
                    Image(systemName: isGenerating ? "stop.fill" : "arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(isGenerating ? Color.red.opacity(0.85) : Theme.accent)
                        .clipShape(.rect(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
