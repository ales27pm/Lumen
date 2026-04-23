import Foundation
import Observation

/// Persistent user settings. Values are auto-persisted to UserDefaults whenever
/// they change. Initialization reads from UserDefaults; no didSet runs during init.
@Observable
final class UserSettings {
    // Model selection
    var activeChatModelID: String? { didSet { save() } }
    var activeEmbeddingModelID: String? { didSet { save() } }

    // Tools
    var enabledToolIDs: Set<String> { didSet { save() } }

    // Prompting / generation
    var systemPrompt: String { didSet { save() } }
    var temperature: Double { didSet { save() } }
    var topP: Double { didSet { save() } }
    var repetitionPenalty: Double { didSet { save() } }
    var contextSize: Int { didSet { save() } }
    var maxTokens: Int { didSet { save() } }
    var autoMemory: Bool { didSet { save() } }
    var selectedPresetID: String { didSet { save() } }

    // Voice
    var voiceID: String? { didSet { save() } }
    var speakingRate: Double { didSet { save() } }
    var handsFree: Bool { didSet { save() } }

    // Agent
    var maxAgentSteps: Int { didSet { save() } }
    var showThinkingByDefault: Bool { didSet { save() } }
    var agentModeEnabled: Bool { didSet { save() } }

    @ObservationIgnored
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        activeChatModelID = defaults.string(forKey: Keys.activeChatModelID)
        activeEmbeddingModelID = defaults.string(forKey: Keys.activeEmbeddingModelID)

        if let saved = defaults.array(forKey: Keys.enabledToolIDs) as? [String] {
            enabledToolIDs = Set(saved)
        } else {
            enabledToolIDs = Set(ToolRegistry.all.map(\.id))
        }

        systemPrompt = defaults.string(forKey: Keys.systemPrompt) ?? Presets.general.prompt
        temperature = defaults.object(forKey: Keys.temperature) as? Double ?? 0.7
        topP = defaults.object(forKey: Keys.topP) as? Double ?? 0.95
        repetitionPenalty = defaults.object(forKey: Keys.repetitionPenalty) as? Double ?? 1.1
        contextSize = defaults.object(forKey: Keys.contextSize) as? Int ?? 4096
        maxTokens = defaults.object(forKey: Keys.maxTokens) as? Int ?? 512
        autoMemory = defaults.object(forKey: Keys.autoMemory) as? Bool ?? true
        selectedPresetID = defaults.string(forKey: Keys.selectedPresetID) ?? Presets.general.id

        voiceID = defaults.string(forKey: Keys.voiceID)
        speakingRate = defaults.object(forKey: Keys.speakingRate) as? Double ?? 0.5
        handsFree = defaults.object(forKey: Keys.handsFree) as? Bool ?? false

        maxAgentSteps = defaults.object(forKey: Keys.maxAgentSteps) as? Int ?? 6
        showThinkingByDefault = defaults.object(forKey: Keys.showThinkingByDefault) as? Bool ?? false
        agentModeEnabled = defaults.object(forKey: Keys.agentModeEnabled) as? Bool ?? true
    }

    private func save() {
        defaults.set(activeChatModelID, forKey: Keys.activeChatModelID)
        defaults.set(activeEmbeddingModelID, forKey: Keys.activeEmbeddingModelID)
        defaults.set(Array(enabledToolIDs), forKey: Keys.enabledToolIDs)
        defaults.set(systemPrompt, forKey: Keys.systemPrompt)
        defaults.set(temperature, forKey: Keys.temperature)
        defaults.set(topP, forKey: Keys.topP)
        defaults.set(repetitionPenalty, forKey: Keys.repetitionPenalty)
        defaults.set(contextSize, forKey: Keys.contextSize)
        defaults.set(maxTokens, forKey: Keys.maxTokens)
        defaults.set(autoMemory, forKey: Keys.autoMemory)
        defaults.set(selectedPresetID, forKey: Keys.selectedPresetID)
        defaults.set(voiceID, forKey: Keys.voiceID)
        defaults.set(speakingRate, forKey: Keys.speakingRate)
        defaults.set(handsFree, forKey: Keys.handsFree)
        defaults.set(maxAgentSteps, forKey: Keys.maxAgentSteps)
        defaults.set(showThinkingByDefault, forKey: Keys.showThinkingByDefault)
        defaults.set(agentModeEnabled, forKey: Keys.agentModeEnabled)
    }

    func toggleTool(_ id: String) {
        if enabledToolIDs.contains(id) {
            enabledToolIDs.remove(id)
        } else {
            enabledToolIDs.insert(id)
        }
    }

    func applyPreset(_ preset: Preset) {
        systemPrompt = preset.prompt
        selectedPresetID = preset.id
        temperature = preset.temperature
    }

    /// Snapshot for background / concurrency-safe consumers.
    var snapshot: SettingsSnapshot {
        SettingsSnapshot(
            activeChatModelID: activeChatModelID,
            activeEmbeddingModelID: activeEmbeddingModelID,
            enabledToolIDs: enabledToolIDs,
            systemPrompt: systemPrompt,
            temperature: temperature,
            topP: topP,
            repetitionPenalty: repetitionPenalty,
            contextSize: contextSize,
            maxTokens: maxTokens,
            autoMemory: autoMemory,
            voiceID: voiceID,
            speakingRate: speakingRate,
            handsFree: handsFree,
            maxAgentSteps: maxAgentSteps,
            agentModeEnabled: agentModeEnabled
        )
    }

    fileprivate enum Keys {
        static let activeChatModelID = "activeChatModelID"
        static let activeEmbeddingModelID = "activeEmbeddingModelID"
        static let enabledToolIDs = "enabledToolIDs"
        static let systemPrompt = "systemPrompt"
        static let temperature = "temperature"
        static let topP = "topP"
        static let repetitionPenalty = "repetitionPenalty"
        static let contextSize = "contextSize"
        static let maxTokens = "maxTokens"
        static let autoMemory = "autoMemory"
        static let selectedPresetID = "selectedPresetID"
        static let voiceID = "voiceID"
        static let speakingRate = "speakingRate"
        static let handsFree = "handsFree"
        static let maxAgentSteps = "maxAgentSteps"
        static let showThinkingByDefault = "showThinkingByDefault"
        static let agentModeEnabled = "agentModeEnabled"
    }
}

/// Sendable, thread-safe snapshot of user settings. Safe to pass into background
/// tasks, detached actors, and BG task handlers.
nonisolated struct SettingsSnapshot: Sendable {
    let activeChatModelID: String?
    let activeEmbeddingModelID: String?
    let enabledToolIDs: Set<String>
    let systemPrompt: String
    let temperature: Double
    let topP: Double
    let repetitionPenalty: Double
    let contextSize: Int
    let maxTokens: Int
    let autoMemory: Bool
    let voiceID: String?
    let speakingRate: Double
    let handsFree: Bool
    let maxAgentSteps: Int
    let agentModeEnabled: Bool

    /// Loads a snapshot directly from UserDefaults without touching the
    /// in-memory `UserSettings` instance. Used by background tasks that may
    /// run before or without the main app scene.
    static func loadFromDisk(defaults: UserDefaults = .standard) -> SettingsSnapshot {
        enum DiskKeys {
            static let activeChatModelID = "activeChatModelID"
            static let activeEmbeddingModelID = "activeEmbeddingModelID"
            static let enabledToolIDs = "enabledToolIDs"
            static let systemPrompt = "systemPrompt"
            static let temperature = "temperature"
            static let topP = "topP"
            static let repetitionPenalty = "repetitionPenalty"
            static let contextSize = "contextSize"
            static let maxTokens = "maxTokens"
            static let autoMemory = "autoMemory"
            static let voiceID = "voiceID"
            static let speakingRate = "speakingRate"
            static let handsFree = "handsFree"
            static let maxAgentSteps = "maxAgentSteps"
            static let agentModeEnabled = "agentModeEnabled"
        }

        let enabled: Set<String>
        if let saved = defaults.array(forKey: DiskKeys.enabledToolIDs) as? [String] {
            enabled = Set(saved)
        } else {
            enabled = Set(ToolRegistry.all.map(\.id))
        }
        return SettingsSnapshot(
            activeChatModelID: defaults.string(forKey: DiskKeys.activeChatModelID),
            activeEmbeddingModelID: defaults.string(forKey: DiskKeys.activeEmbeddingModelID),
            enabledToolIDs: enabled,
            systemPrompt: defaults.string(forKey: DiskKeys.systemPrompt) ?? Presets.general.prompt,
            temperature: defaults.object(forKey: DiskKeys.temperature) as? Double ?? 0.7,
            topP: defaults.object(forKey: DiskKeys.topP) as? Double ?? 0.95,
            repetitionPenalty: defaults.object(forKey: DiskKeys.repetitionPenalty) as? Double ?? 1.1,
            contextSize: defaults.object(forKey: DiskKeys.contextSize) as? Int ?? 4096,
            maxTokens: defaults.object(forKey: DiskKeys.maxTokens) as? Int ?? 512,
            autoMemory: defaults.object(forKey: DiskKeys.autoMemory) as? Bool ?? true,
            voiceID: defaults.string(forKey: DiskKeys.voiceID),
            speakingRate: defaults.object(forKey: DiskKeys.speakingRate) as? Double ?? 0.5,
            handsFree: defaults.object(forKey: DiskKeys.handsFree) as? Bool ?? false,
            maxAgentSteps: defaults.object(forKey: DiskKeys.maxAgentSteps) as? Int ?? 6,
            agentModeEnabled: defaults.object(forKey: DiskKeys.agentModeEnabled) as? Bool ?? true
        )
    }
}
