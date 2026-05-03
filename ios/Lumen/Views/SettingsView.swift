import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @State private var showDeveloperAlert = false
    @State private var developerAlertMessage = ""
    @State private var parseFailureSummary = "• Parse-failure traces: loading…"
    @State private var parseNoiseSummary = "• Recoverable noise traces: loading…"

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

                Section {
                    Toggle("Auto-download fleet", isOn: Binding(get: { state.autoDownloadFleetModels }, set: { state.autoDownloadFleetModels = $0 }))
                    Toggle("Ask before fleet downloads", isOn: Binding(get: { state.confirmFleetDownloads }, set: { state.confirmFleetDownloads = $0 }))
                } header: {
                    Text("Fleet")
                } footer: {
                    Text("Auto-download installs the recommended v1 model fleet on launch when artifacts are missing and storage is available.")
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
                    NavigationLink {
                        AgentGroundingAuditView(registryProvider: LiveRuntimeToolRegistryProvider())
                    } label: {
                        Label("Agent grounding audit", systemImage: "checkmark.seal.text.page")
                    }
                    .accessibilityIdentifier("settings.developer.agentGroundingAudit")

                    NavigationLink {
                        E2ETestRunnerView()
                    } label: {
                        Label("End-to-end tests", systemImage: "testtube.2")
                    }
                    .accessibilityIdentifier("settings.developer.e2eTests")

                    Button {
                        runDeveloperChecks()
                    } label: {
                        Label("Run storage checks", systemImage: "checkmark.circle")
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
            .alert("Run checks", isPresented: $showDeveloperAlert) {
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

        Fleet:
        • autoDownloadFleetModels: \(appState.autoDownloadFleetModels ? "true" : "false")
        • confirmFleetDownloads: \(appState.confirmFleetDownloads ? "true" : "false")

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

        Recoverable noise signatures:
        \(parseNoiseSummary)

        Latest E2E:
        \(E2ETestLogStore.latestText())
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
        let e2eDirectory = try? E2ETestLogStore.reportsDirectory()
        let canWriteE2E = e2eDirectory.map { fm.isWritableFile(atPath: $0.path) } ?? false

        let checks: [(String, Bool)] = [
            ("Models folder readable", canReadModels),
            ("Models folder writable", canWriteModels),
            ("Imports folder readable", canReadImports),
            ("Imports folder writable", canWriteImports),
            ("E2E folder writable", canWriteE2E),
        ]

        let passed = checks.filter(\.1).count
        let summary = checks
            .map { check in "• \(check.0): \(check.1 ? "PASS" : "FAIL")" }
            .joined(separator: "\n")
        developerAlertMessage = "\(passed)/\(checks.count) checks passed\n\n\(summary)"
        showDeveloperAlert = true
    }

    private func refreshParseFailureSummary() async {
        let summary = await Task.detached(priority: .utility) {
            (
                AgentParseFailureSummaryLoader.developerText(topN: 5),
                AgentParseNoiseSummaryLoader.developerText(topN: 5)
            )
        }.value
        parseFailureSummary = summary.0
        parseNoiseSummary = summary.1
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

private struct E2ETestRunnerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @State private var isRunning = false
    @State private var runMode: RunMode = .standard
    @State private var reportText = E2ETestLogStore.latestText()
    @State private var latestReport: E2ETestReport?
    @State private var lastExportURL: URL?
    @State private var exportError: String?

    var body: some View {
        List {
            Section {
                Picker("Mode", selection: $runMode) {
                    ForEach(RunMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                Button {
                    run()
                } label: {
                    HStack {
                        Label(isRunning ? "Running…" : runMode.buttonTitle, systemImage: "play.circle")
                        Spacer()
                        if isRunning { ProgressView() }
                    }
                }
                .disabled(isRunning)

                Button {
                    reportText = E2ETestLogStore.latestText()
                } label: {
                    Label("Reload latest report", systemImage: "arrow.clockwise")
                }

                Button {
                    exportLatestReport()
                } label: {
                    Label("Export Live E2E Report JSON", systemImage: "square.and.arrow.up")
                }
                .disabled(latestReport == nil)

                if let lastExportURL {
                    LabeledContent("Last E2E export", value: lastExportURL.lastPathComponent)
                        .font(.caption)
                    ShareLink(item: lastExportURL) {
                        Label("Share Live E2E JSON", systemImage: "square.and.arrow.up")
                    }
                }
            } footer: {
                Text(runMode.footerText)
            }

            if let exportError {
                Section("Export Error") {
                    Text(exportError).foregroundStyle(.red)
                }
            }

            Section("Scenarios") {
                ForEach(runMode.scenarios) { scenario in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(scenario.title)
                            .font(.subheadline.weight(.medium))
                        Text(scenario.prompt)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        Text("Intent: \(scenario.expectedIntent.rawValue) · \(scenario.kind.rawValue) · agent run: \(scenario.requiresAgentRun ? "yes" : "no")")
                            .font(.caption2.monospaced())
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.vertical, 2)
                }
            }

            Section("Latest Report") {
                Text(reportText)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("E2E Tests")
        .onChange(of: runMode) { _, _ in
            reportText = E2ETestLogStore.latestText()
            latestReport = nil
            lastExportURL = nil
            exportError = nil
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func run() {
        guard !isRunning else { return }
        isRunning = true
        exportError = nil
        reportText = runMode.runningLabel
        Task { @MainActor in
            let report: E2ETestReport
            switch runMode {
            case .standard:
                report = await E2ETestRunner.runStandard(appState: appState, context: modelContext)
            case .trainingValidation:
                report = await E2ETestRunner.runTrainingValidation(appState: appState, context: modelContext)
            }
            latestReport = report
            reportText = report.summaryText
            isRunning = false
        }
    }

    private func exportLatestReport() {
        guard let latestReport else { return }
        do {
            let result = try EvidenceLayerExporter.writeLayer(
                payload: latestReport,
                filePrefix: "lumen-live-e2e-report",
                format: "live-e2e-test-report-json",
                sourceLayer: "e2eTestReport",
                ownsLiveE2EScenarios: true,
                includesDeterministicStaticScenarios: false,
                privacy: "Contains prompts, final outputs, failures, and event logs from the current local E2E run. Review before sharing outside the improve-loop.",
                notes: [
                    "This is the live E2E model/test layer export.",
                    "Scenarios with requiresAgentRun=true are intended to exercise the loaded SlotAgentService path.",
                    "If a scenario says no model loaded or routing-only checks completed, the offline ingester treats it as invalid E2E evidence."
                ]
            )
            lastExportURL = result.url
            exportError = nil
        } catch {
            exportError = "Live E2E report export failed: \(error.localizedDescription)"
        }
    }
}


private extension E2ETestRunnerView {
    enum RunMode: CaseIterable {
        case standard
        case trainingValidation

        var title: String {
            switch self {
            case .standard: return "Standard"
            case .trainingValidation: return "Training validation"
            }
        }

        var buttonTitle: String {
            switch self {
            case .standard: return "Run full E2E suite"
            case .trainingValidation: return "Run training validation"
            }
        }

        var runningLabel: String {
            switch self {
            case .standard: return "Running E2E suite…"
            case .trainingValidation: return "Running training validation…"
            }
        }

        var scenarios: [E2ETestScenario] {
            switch self {
            case .standard: return E2ETestScenario.standard
            case .trainingValidation: return E2ETestScenario.trainingValidation
            }
        }

        var footerText: String {
            switch self {
            case .standard:
                return "Runs deterministic routing checks plus live agent scenarios for tool boundaries, chat quality, stale-context regressions, and final-answer validation. Export creates a live E2E JSON layer with ownsLiveE2EScenarios=true."
            case .trainingValidation:
                return "Runs multi-scenario in-app validation using trained models in real agent flows, then summarizes failures as training signals for the next fine-tuning cycle. Export creates a live E2E JSON layer with ownsLiveE2EScenarios=true."
            }
        }
    }
}
