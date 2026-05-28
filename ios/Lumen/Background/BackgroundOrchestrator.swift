import Foundation
import SwiftData
import BackgroundTasks

@MainActor
final class BackgroundOrchestrator {
    static let shared = BackgroundOrchestrator()

    private let lease = BackgroundExecutionLease()
    private let metrics = RuntimeMetricsStore.shared

    func register() {
        TriggerScheduler.shared.registerTasks()
    }

    func schedule() {
        TriggerScheduler.shared.scheduleBackgroundRefresh()
    }

    func handleAppRefresh() async {
        guard let container = SharedContainer.shared else { return }
        let context = ModelContext(container)
        await runTriggerScan(context: context)
    }

    func handleProcessing() async {
        guard let container = SharedContainer.shared else { return }
        let context = ModelContext(container)
        await runTriggerScan(context: context)
        await runMemoryConsolidationIfAllowed()
        await runRAGMaintenanceIfAllowed()
        await runModelHousekeepingIfAllowed()
    }

    func runTriggerScan(context: ModelContext) async {
        let acquired = await lease.acquire(category: "triggerScan", reason: "background trigger scan")
        guard acquired else { return }
        defer { Task { await lease.release(category: "triggerScan") } }
        await TriggerScheduler.shared.fireDueTriggers(context: context, settings: SettingsSnapshot.loadFromDisk())
        try? await metrics.appendMetric(RuntimeMetric(timestamp: Date(), runtimeName: "background", taskKind: "triggerScan", modelIDHash: nil, policySummary: "trigger scheduler fireDueTriggers", latencyMs: nil, success: true, errorCode: nil, thermalState: .from(processThermalState: ProcessInfo.processInfo.thermalState), lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, memoryWarningCount: 0))
    }

    func runMemoryConsolidationIfAllowed() async {
        guard let container = SharedContainer.shared else { return }
        let context = ModelContext(container)
        await MemoryConsolidator.consolidate(context: context, metricsStore: metrics)
    }

    func runRAGMaintenanceIfAllowed() async {
        guard let container = SharedContainer.shared else { return }
        let context = ModelContext(container)
        let ok = await RAGEngine().maintenance(context: context)
        try? await metrics.appendMetric(RuntimeMetric(timestamp: Date(), runtimeName: "background", taskKind: "ragMaintenance", modelIDHash: nil, policySummary: "maintenance", latencyMs: nil, success: ok, errorCode: ok ? nil : "unavailable", thermalState: .from(processThermalState: ProcessInfo.processInfo.thermalState), lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, memoryWarningCount: 0))
    }

    func runModelHousekeepingIfAllowed() async {
        try? await metrics.appendMetric(RuntimeMetric(timestamp: Date(), runtimeName: "background", taskKind: "modelHousekeeping", modelIDHash: nil, policySummary: "not available in current runtime", latencyMs: nil, success: false, errorCode: "not_available", thermalState: .from(processThermalState: ProcessInfo.processInfo.thermalState), lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, memoryWarningCount: 0))
    }
}
