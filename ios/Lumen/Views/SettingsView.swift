import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var showDeveloperAlert = false
    @State private var developerAlertMessage = ""
    @State private var parseFailureSummary = "• Parse-failure traces: loading…"

    var body: some View {
        @Bindable var state = appState

        NavigationStack {
            Form {
                Section("Prompt Presets") {
                    Picker("Preset", selection: Binding(
                        get: { state.selectedPresetID },
                        set: { id in
                            if let p = Presets.all.first(where: { $0.id == id }) {
                                state.applyPreset(p)
                            }
                        }
                    )) {
                        ForEach(Presets.all) { preset in
                            Label(preset.name, systemImage: preset.icon).tag(preset.id)
                        }
                    }
                }

                Section("Agent") {
                    Toggle("Agent mode", isOn: Binding(get: { state.agentModeEnabled }, set: { state.agentModeEnabled = $0 }))
                    Toggle("Show thinking by default", isOn: Binding(get: { state.showThinkingByDefault }, set: { state.showThinkingByDefault = $0 }))
                    Stepper(value: Binding(get: { state.maxAgentSteps }, set: { state.maxAgentSteps = $0 }), in: 1...10) {
                        HStack {
                            Text("Max steps")
                            Spacer()
                            Text("\(state.maxAgentSteps)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }

                Section("Voice") {
                    Toggle("Hands-free", isOn: Binding(get: { state.handsFree }, set: { state.handsFree = $0 }))
                    HStack {
                        Text("Speaking rate")
                        Spacer()
                        Text(String(format: "%.2f", state.speakingRate))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Slider(value: Binding(get: { state.speakingRate }, set: { state.speakingRate = $0 }), in: 0.3...0.7)
                    NavigationLink {
                        VoicePickerList()
                    } label: {
                        HStack {
                            Text("Voice")
                            Spacer()
                            Text(currentVoiceName).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }

                Section("System Prompt") {
                    TextEditor(text: Binding(get: { state.systemPrompt }, set: { state.systemPrompt = $0 }))
                        .frame(minHeight: 120)
                        .font(.footnote)
                }

                Section("Generation") {
                    sliderRow("Temperature", value: Binding(get: { state.temperature }, set: { state.temperature = $0 }), range: 0...2, format: "%.2f")
                    sliderRow("Top-P", value: Binding(get: { state.topP }, set: { state.topP = $0 }), range: 0...1, format: "%.2f")
                    sliderRow("Repetition penalty", value: Binding(get: { state.repetitionPenalty }, set: { state.repetitionPenalty = $0 }), range: 1...1.5, format: "%.2f")
                    Stepper(value: Binding(get: { state.contextSize }, set: { state.contextSize = $0 }), in: 1024...32768, step: 1024) {
                        HStack {
                            Text("Context size")
                            Spacer()
                            Text("\(state.contextSize)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Stepper(value: Binding(get: { state.maxTokens }, set: { state.maxTokens = $0 }), in: 128...4096, step: 128) {
                        HStack {
                            Text("Max output")
                            Spacer()
                            Text("\(state.maxTokens)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }

                Section("Memory") {
                    Toggle("Auto-remember", isOn: Binding(get: { state.autoMemory }, set: { state.autoMemory = $0 }))
                }

                Section("Developer") {
                    Button {
                        runDeveloperChecks()
                    } label: {
                        Label("Run tests", systemImage: "checkmark.circle")
                    }
                    .accessibilityIdentifier("settings.developer.runTests")

                    NavigationLink {
                        DeveloperTextView(title: "Logs", bodyText: logsText)
                    } label: {
                        Label("Logs", systemImage: "doc.text.magnifyingglass")
                    }
                    .accessibilityIdentifier("settings.developer.logs")

                    NavigationLink {
                        DeveloperTextView(title: "Debug", bodyText: debugText)
                    } label: {
                        Label("Debug", systemImage: "ladybug")
                    }
                    .accessibilityIdentifier("settings.developer.debug")

                    NavigationLink {
                        DeveloperTextView(title: "Diagnostic", bodyText: diagnosticText)
                    } label: {
                        Label("Diagnostic", systemImage: "stethoscope")
                    }
                    .accessibilityIdentifier("settings.developer.diagnostic")
                }

                Section {
                    NavigationLink {
                        PermissionsView()
                    } label: {
                        Label("Permissions", systemImage: "hand.raised")
                    }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Review which system features Lumen can access.")
                }

                Section("About") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Lumen").font(.subheadline.weight(.semibold))
                        Text("Runs open-source language models locally via llama.cpp. Embeddings stored in local SQLite. Tool calls executed on-device. Nothing leaves your phone.")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            .navigationTitle("Settings")
            .task {
                await refreshParseFailureSummary()
            }
            .alert("Run tests", isPresented: $showDeveloperAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(developerAlertMessage)
            }
        }
    }

    private var currentVoiceName: String {
        if let id = appState.voiceID,
           let v = VoiceCatalog.available().first(where: { $0.id == id }) {
            return v.name
        }
        return "System default"
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
            Slider(value: value, in: range)
        }
    }

    private var logsText: String {
        let modelsDirectory = ModelStorage.modelsDirectoryURL()
        let imported = FileStore.importedFiles()
        let modelFiles = (try? FileManager.default.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return """
        Last launch diagnostics:
        • Imported files: \(imported.count)
        • Model files: \(modelFiles.count)
        • Models path: \(modelsDirectory.path)
        \(parseFailureSummary)
        """
    }

    private var debugText: String {
        """
        Runtime:
        • isGenerating: \(appState.isGenerating ? "true" : "false")
        • agentModeEnabled: \(appState.agentModeEnabled ? "true" : "false")
        • showThinkingByDefault: \(appState.showThinkingByDefault ? "true" : "false")
        • maxAgentSteps: \(appState.maxAgentSteps)

        Generation:
        • temperature: \(String(format: "%.2f", appState.temperature))
        • topP: \(String(format: "%.2f", appState.topP))
        • repetitionPenalty: \(String(format: "%.2f", appState.repetitionPenalty))
        • contextSize: \(appState.contextSize)
        • maxTokens: \(appState.maxTokens)
        """
    }

    private var diagnosticText: String {
        let permissions = PermissionKind.allCases
            .map { "\($0.title): \(PermissionsCenter.shared.state($0).label)" }
            .joined(separator: "\n")
        return """
        Permissions:
        \(permissions)
        """
    }

    private func runDeveloperChecks() {
        let fm = FileManager.default
        let modelsDirectory = ModelStorage.modelsDirectoryURL(fileManager: fm)
        let canReadModels = fm.isReadableFile(atPath: modelsDirectory.path)
        let canWriteModels = fm.isWritableFile(atPath: modelsDirectory.path)
        let importsDirectory = FileStore.importsDirectory
        let canReadImports = fm.isReadableFile(atPath: importsDirectory.path)
        let canWriteImports = fm.isWritableFile(atPath: importsDirectory.path)

        let checks: [(String, Bool)] = [
            ("Models folder readable", canReadModels),
            ("Models folder writable", canWriteModels),
            ("Imports folder readable", canReadImports),
            ("Imports folder writable", canWriteImports),
        ]

        let passed = checks.filter(\.1).count
        let summary = checks
            .map { check in "• \(check.0): \(check.1 ? "PASS" : "FAIL")" }
            .joined(separator: "\n")
        developerAlertMessage = "\(passed)/\(checks.count) checks passed\n\n\(summary)"
        showDeveloperAlert = true
    }

    private func refreshParseFailureSummary() async {
        let summaryText = await Task.detached(priority: .utility) {
            AgentParseFailureSummaryLoader.developerText(topN: 5)
        }.value
        parseFailureSummary = summaryText
    }
}

private struct DeveloperTextView: View {
    let title: String
    let bodyText: String

    var body: some View {
        ScrollView {
            Text(bodyText)
                .font(.footnote.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
