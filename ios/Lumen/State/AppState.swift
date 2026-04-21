import SwiftUI
import Observation

@Observable
final class AppState {
    var activeChatModelID: String?
    var activeEmbeddingModelID: String?
    var enabledToolIDs: Set<String> = Set(ToolRegistry.all.map(\.id))

    var systemPrompt: String = Presets.general.prompt
    var temperature: Double = 0.7
    var topP: Double = 0.95
    var repetitionPenalty: Double = 1.1
    var contextSize: Int = 4096
    var maxTokens: Int = 512
    var autoMemory: Bool = true
    var selectedPresetID: String = Presets.general.id

    // Voice
    var voiceID: String?
    var speakingRate: Double = 0.5
    var handsFree: Bool = false

    // Agent
    var maxAgentSteps: Int = 6
    var showThinkingByDefault: Bool = false
    var agentModeEnabled: Bool = true

    var downloads: [String: DownloadProgress] = [:]
    var isGenerating: Bool = false

    @ObservationIgnored
    private let defaults = UserDefaults.standard

    init() {
        activeChatModelID = defaults.string(forKey: "activeChatModelID")
        activeEmbeddingModelID = defaults.string(forKey: "activeEmbeddingModelID")
        if let saved = defaults.array(forKey: "enabledToolIDs") as? [String] {
            enabledToolIDs = Set(saved)
        }
        systemPrompt = defaults.string(forKey: "systemPrompt") ?? Presets.general.prompt
        temperature = defaults.object(forKey: "temperature") as? Double ?? 0.7
        topP = defaults.object(forKey: "topP") as? Double ?? 0.95
        repetitionPenalty = defaults.object(forKey: "repetitionPenalty") as? Double ?? 1.1
        contextSize = defaults.object(forKey: "contextSize") as? Int ?? 4096
        maxTokens = defaults.object(forKey: "maxTokens") as? Int ?? 512
        autoMemory = defaults.object(forKey: "autoMemory") as? Bool ?? true
        selectedPresetID = defaults.string(forKey: "selectedPresetID") ?? Presets.general.id
        voiceID = defaults.string(forKey: "voiceID")
        speakingRate = defaults.object(forKey: "speakingRate") as? Double ?? 0.5
        handsFree = defaults.object(forKey: "handsFree") as? Bool ?? false
        maxAgentSteps = defaults.object(forKey: "maxAgentSteps") as? Int ?? 6
        showThinkingByDefault = defaults.object(forKey: "showThinkingByDefault") as? Bool ?? false
        agentModeEnabled = defaults.object(forKey: "agentModeEnabled") as? Bool ?? true
    }

    func persist() {
        defaults.set(activeChatModelID, forKey: "activeChatModelID")
        defaults.set(activeEmbeddingModelID, forKey: "activeEmbeddingModelID")
        defaults.set(Array(enabledToolIDs), forKey: "enabledToolIDs")
        defaults.set(systemPrompt, forKey: "systemPrompt")
        defaults.set(temperature, forKey: "temperature")
        defaults.set(topP, forKey: "topP")
        defaults.set(repetitionPenalty, forKey: "repetitionPenalty")
        defaults.set(contextSize, forKey: "contextSize")
        defaults.set(maxTokens, forKey: "maxTokens")
        defaults.set(autoMemory, forKey: "autoMemory")
        defaults.set(selectedPresetID, forKey: "selectedPresetID")
        defaults.set(voiceID, forKey: "voiceID")
        defaults.set(speakingRate, forKey: "speakingRate")
        defaults.set(handsFree, forKey: "handsFree")
        defaults.set(maxAgentSteps, forKey: "maxAgentSteps")
        defaults.set(showThinkingByDefault, forKey: "showThinkingByDefault")
        defaults.set(agentModeEnabled, forKey: "agentModeEnabled")
    }

    func toggleTool(_ id: String) {
        if enabledToolIDs.contains(id) { enabledToolIDs.remove(id) }
        else { enabledToolIDs.insert(id) }
        persist()
    }

    func applyPreset(_ preset: Preset) {
        systemPrompt = preset.prompt
        selectedPresetID = preset.id
        temperature = preset.temperature
        persist()
    }
}

nonisolated struct DownloadProgress: Sendable {
    var fractionCompleted: Double
    var bytesReceived: Int64
    var totalBytes: Int64
    var state: State

    enum State: Sendable { case queued, downloading, paused, completed, failed(String) }
}

nonisolated struct Preset: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let icon: String
    let prompt: String
    let temperature: Double
}

nonisolated enum Presets {
    static let general = Preset(
        id: "general",
        name: "General",
        icon: "sparkles",
        prompt: "You are Lumen, a helpful, concise on-device AI assistant. You have access to tools for calendar, reminders, contacts, location, messages, photos, camera, health, and motion. When a user request requires real-world actions or live data, call the appropriate tool using the tool-calling format. Respect user privacy — all data stays on this device.",
        temperature: 0.7
    )
    static let coder = Preset(
        id: "coder",
        name: "Coder",
        icon: "chevron.left.forwardslash.chevron.right",
        prompt: "You are Lumen in coder mode. Give precise, modern code answers. Prefer Swift/SwiftUI for iOS. Use fenced code blocks. Be terse.",
        temperature: 0.3
    )
    static let researcher = Preset(
        id: "researcher",
        name: "Researcher",
        icon: "books.vertical.fill",
        prompt: "You are Lumen in researcher mode. Be thorough, cite reasoning, and structure answers with headings. Think step-by-step.",
        temperature: 0.5
    )
    static let journal = Preset(
        id: "journal",
        name: "Journal",
        icon: "book.closed.fill",
        prompt: "You are Lumen in journal mode. Be warm, reflective, and ask open-ended questions. Help the user process thoughts privately.",
        temperature: 0.8
    )
    static let roleplay = Preset(
        id: "roleplay",
        name: "Roleplay",
        icon: "theatermasks.fill",
        prompt: "You are Lumen in creative mode. Be imaginative, vivid, and dramatic. Stay in character.",
        temperature: 1.0
    )

    static let all: [Preset] = [general, coder, researcher, journal, roleplay]
    static func find(id: String) -> Preset { all.first { $0.id == id } ?? general }
}
