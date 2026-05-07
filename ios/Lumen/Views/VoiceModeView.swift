import SwiftUI
import SwiftData

struct VoiceModeView: View {
    var onTranscript: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(VoiceService.self) private var voice
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]

    @State private var phase: Phase = .idle
    @State private var responseText: String = ""
    @State private var responseTask: Task<Void, Never>?
    @State private var spokenPrefix: Int = 0
    @State private var finishedStreaming = false
    @State private var stepsBuffer: [AgentStep] = []
    @State private var activeVoiceTurnID: UUID?

    enum Phase { case idle, listening, thinking, speaking }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 24) {
                HStack {
                    Button { close() } label: {
                        Image(systemName: "xmark")
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
                    Spacer()
                    statusPill
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                Spacer()

                VoiceWaveform(level: voice.inputLevel, phase: phase)
                    .frame(height: 120)
                    .padding(.horizontal, 40)

                VStack(spacing: 10) {
                    Text(statusTitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text(transcriptText)
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 24)
                        .frame(minHeight: 72)
                        .animation(.easeInOut(duration: 0.2), value: transcriptText)
                }

                Spacer()

                HStack(spacing: 32) {
                    Button { toggleHandsFree() } label: {
                        VStack(spacing: 4) {
                            Image(systemName: appState.handsFree ? "infinity.circle.fill" : "infinity")
                                .font(.title3)
                                .foregroundStyle(appState.handsFree ? Theme.accent : Theme.textSecondary)
                            Text("Hands-free").font(.caption2).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .buttonStyle(.plain)

                    Button { mainAction() } label: {
                        Image(systemName: mainIcon)
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 72, height: 72)
                            .background(mainButtonColor)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

                    Button { interrupt() } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "hand.raised")
                                .font(.title3)
                                .foregroundStyle(phase == .speaking ? Color(red: 0.95, green: 0.5, blue: 0.5) : Theme.textTertiary)
                            Text("Interrupt").font(.caption2).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(phase != .speaking)
                }
                .padding(.bottom, 40)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { startListening() }
        .onDisappear { cleanup() }
    }

    private var statusTitle: String {
        switch phase {
        case .idle: "Tap to speak"
        case .listening: "Listening"
        case .thinking: "Thinking"
        case .speaking: "Speaking"
        }
    }

    private var transcriptText: String {
        switch phase {
        case .listening: voice.liveTranscript.isEmpty ? "Say something — Lumen is listening." : voice.liveTranscript
        case .thinking: voice.liveTranscript
        case .speaking: responseText
        case .idle: "Tap the mic to start."
        }
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            StatusDot(color: phaseColor, size: 6)
            Text(statusTitle)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Theme.surface)
        .clipShape(.rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1)
        }
    }

    private var phaseColor: Color {
        switch phase {
        case .idle: Theme.textTertiary
        case .listening: Color(red: 0.5, green: 0.85, blue: 0.6)
        case .thinking: Color(red: 0.95, green: 0.75, blue: 0.4)
        case .speaking: Theme.accent
        }
    }

    private var mainIcon: String {
        switch phase {
        case .idle: "mic.fill"
        case .listening: "checkmark"
        case .thinking: "stop.fill"
        case .speaking: "stop.fill"
        }
    }

    private var mainButtonColor: Color {
        switch phase {
        case .idle: Theme.accent
        case .listening: Color(red: 0.4, green: 0.75, blue: 0.55)
        case .thinking: Color(red: 0.85, green: 0.65, blue: 0.35)
        case .speaking: Color(red: 0.9, green: 0.45, blue: 0.45)
        }
    }

    private func mainAction() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        switch phase {
        case .idle: startListening()
        case .listening: finishListening()
        case .thinking, .speaking: interrupt()
        }
    }

    private func startListening() {
        voice.stopSpeaking()
        responseText = ""
        activeVoiceTurnID = nil
        phase = .listening
        Task {
            await voice.startListening { text in
                Task { @MainActor in handleTranscript(text) }
            }
        }
    }

    private func finishListening() {
        voice.finishListening()
    }

    private func handleTranscript(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if appState.handsFree { startListening() } else { phase = .idle }
            return
        }
        phase = .thinking
        runAgent(text: trimmed)
    }

    private func runAgent(text: String) {
        responseText = ""
        spokenPrefix = 0
        finishedStreaming = false
        stepsBuffer = []
        let turnID = UUID()
        activeVoiceTurnID = turnID

        responseTask = Task {
            let convo = conversations.first ?? {
                let c = Conversation(title: String(text.prefix(36)), systemPrompt: appState.systemPrompt)
                modelContext.insert(c)
                return c
            }()
            let userMsg = ChatMessage(role: .user, content: text)
            convo.messages.append(userMsg)

            _ = await ModelLoader.ensureChatLoaded(appState: appState, stored: [])

            let routing = IntentRouter.classify(text)
            let memories = await safeRecalledMemories(query: text, routing: routing)
            let tools = ToolRegistry.all
                .filter { appState.enabledToolIDs.contains($0.id) }
                .filter { IntentRouter.isToolAllowed($0.id, for: routing) }

            let gatedMemories = MemoryGate.filter(intent: routing.intent, items: memories, userMessage: text)
            let req = AgentRequest(
                systemPrompt: appState.systemPrompt,
                history: safeShortTermContext(in: convo, excludingCurrentUserMessageID: userMsg.id),
                userMessage: text,
                temperature: appState.temperature,
                topP: appState.topP,
                repetitionPenalty: appState.repetitionPenalty,
                maxTokens: appState.maxTokens,
                maxSteps: appState.maxAgentSteps,
                availableTools: tools,
                relevantMemories: gatedMemories,
                conversationID: convo.id,
                turnID: turnID
            )

            var finalText = ""
            for await event in SlotAgentService.shared.run(req) {
                if Task.isCancelled || activeVoiceTurnID != turnID { break }
                switch event {
                case .step(let s): stepsBuffer.append(s)
                case .stepDelta: break
                case .finalDelta(let chunk):
                    finalText += chunk
                    let sanitized = AssistantOutputSanitizer.sanitize(finalText, lastUserMessage: text)
                    responseText = FinalIntentValidator.validate(sanitized, routing: routing, fallback: nil)
                    if phase != .speaking { phase = .speaking }
                    speakPending()
                case .done(let f, let all):
                    finalText = f.isEmpty ? finalText : f
                    stepsBuffer = all
                case .error(let msg):
                    finalText = msg
                    responseText = FinalIntentValidator.validate(msg, routing: routing, fallback: nil)
                }
            }

            guard !Task.isCancelled, activeVoiceTurnID == turnID else { return }
            finishedStreaming = true
            finalText = AssistantOutputSanitizer.sanitize(finalText, lastUserMessage: text)
            finalText = FinalIntentValidator.validate(finalText, routing: routing, fallback: nil)
            responseText = finalText
            speakPending()

            let assistantMsg = ChatMessage(role: .assistant, content: finalText, agentSteps: stepsBuffer)
            convo.messages.append(assistantMsg)
            convo.updatedAt = Date()
            try? modelContext.save()

            if appState.autoMemory, finalText.count > 60, isSafeToStoreMemory(userText: text, assistantText: finalText, routing: routing) {
                await MemoryStore.remember(
                    "User asked: \(text). Assistant: \(String(finalText.prefix(160)))",
                    kind: .conversation, source: "voice", context: modelContext
                )
                let transient = stepsBuffer.filter { $0.kind == .observation || $0.kind == .action }.map(\.content)
                await MemoryStore.extractAndStore(userText: text, assistantText: finalText, transientTexts: transient, context: modelContext)
            }

            activeVoiceTurnID = nil
        }
    }

    private func safeShortTermContext(in conversation: Conversation, excludingCurrentUserMessageID currentID: UUID) -> [(role: MessageRole, content: String)] {
        conversation.sortedMessages
            .filter { $0.id != currentID }
            .suffix(4)
            .compactMap { message in
                guard message.messageRole == .user || message.messageRole == .assistant else { return nil }
                let clean = message.content
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else { return nil }
                return (message.messageRole, String(clean.prefix(500)))
            }
    }

    private func safeRecalledMemories(query: String, routing: IntentRoutingDecision) async -> [MemoryContextItem] {
        await MemoryRecall.recallAndNormalize(query: query, routing: routing, context: modelContext, limit: 8)
    }

    private func isSafeToStoreMemory(userText: String, assistantText: String, routing: IntentRoutingDecision) -> Bool {
        FinalIntentValidator.validate(assistantText, routing: routing, fallback: nil) == assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func speakPending() {
        if phase != .speaking { phase = .speaking }
        let currentChars = Array(responseText)
        guard spokenPrefix < currentChars.count else {
            if finishedStreaming && !voice.isSpeaking { onFinishedSpeaking() }
            return
        }
        let remaining = Array(currentChars[spokenPrefix...])
        let boundaries: Set<Character> = [".", "!", "?", "\n"]
        var end = remaining.count
        if !finishedStreaming {
            if let lastIdx = remaining.lastIndex(where: { boundaries.contains($0) }) {
                end = lastIdx + 1
            } else {
                return
            }
        }
        let chunk = String(remaining[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        spokenPrefix += end
        guard !chunk.isEmpty else { return }
        if !voice.isSpeaking {
            voice.speakChunk(chunk, voiceID: appState.voiceID, rate: appState.speakingRate)
            observeSpeechEnd()
        } else {
            voice.speakChunk(chunk, voiceID: appState.voiceID, rate: appState.speakingRate)
        }
    }

    private func observeSpeechEnd() {
        Task { @MainActor in
            while voice.isSpeaking { try? await Task.sleep(for: .milliseconds(150)); if Task.isCancelled { return } }
            if finishedStreaming && spokenPrefix >= responseText.count {
                onFinishedSpeaking()
            } else {
                speakPending()
            }
        }
    }

    private func onFinishedSpeaking() {
        if appState.handsFree {
            startListening()
        } else {
            phase = .idle
        }
    }

    private func interrupt() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        let turnID = activeVoiceTurnID
        activeVoiceTurnID = nil
        responseTask?.cancel()
        voice.stopSpeaking()
        voice.stopListening()
        phase = .idle
        if turnID != nil, appState.handsFree { startListening() }
    }

    private func toggleHandsFree() {
        appState.handsFree.toggle()
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    private func close() {
        cleanup()
        dismiss()
    }

    private func cleanup() {
        activeVoiceTurnID = nil
        responseTask?.cancel()
        voice.stopListening()
        voice.stopSpeaking()
    }
}

struct VoiceWaveform: View {
    var level: Double
    var phase: VoiceModeView.Phase
    @State private var animate = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                HStack(spacing: 4) {
                    let count = 32
                    ForEach(0..<count, id: \.self) { i in
                        let norm = Double(i) / Double(count - 1)
                        let wave = sin(t * 3.0 + norm * 6.0) * 0.5 + 0.5
                        let reactive = max(0.15, level * 1.8)
                        let active = phase == .idle ? 0.2 : 1.0
                        let h = geo.size.height * (0.15 + wave * reactive * active * 0.85)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color(for: phase))
                            .frame(maxWidth: .infinity)
                            .frame(height: h)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
        }
    }

    private func color(for phase: VoiceModeView.Phase) -> Color {
        switch phase {
        case .idle: Theme.textTertiary
        case .listening: Color(red: 0.5, green: 0.85, blue: 0.6)
        case .thinking: Color(red: 0.95, green: 0.75, blue: 0.4)
        case .speaking: Theme.accent
        }
    }
}
