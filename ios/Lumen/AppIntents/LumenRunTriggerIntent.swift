import Foundation
import SwiftData
#if canImport(AppIntents)
import AppIntents

@available(iOS 16.0, *)
struct LumenRunTriggerIntent: AppIntent {
    static var title: LocalizedStringResource = "Run Lumen Trigger"
    static var openAppWhenRun = false

    @Parameter(title: "Trigger Name") var triggerName: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let name = triggerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120 else { return .result(value: "Trigger name must be 1...120 characters.") }
        guard let container = SharedContainer.shared else {
            return .result(value: LumenIntentResultRenderer.degraded("trigger store unavailable"))
        }
        let ctx = ModelContext(container)
        let all = (try? ctx.fetch(FetchDescriptor<Trigger>())) ?? []
        guard let trigger = all.first(where: { $0.title.localizedCaseInsensitiveContains(name) }) else {
            return .result(value: "No matching trigger found.")
        }
        if LumenIntentPolicy.requiresOpenAppForSensitiveAction(trigger.prompt) {
            return .result(value: LumenIntentResultRenderer.openAppRequired("trigger may require sensitive tools"))
        }
        let result = await TriggerScheduler.shared.runTrigger(trigger, context: ctx, settings: SettingsSnapshot.loadFromDisk(), notify: false) ?? "No result."
        return .result(value: String(result.prefix(500)))
    }
}
#endif
