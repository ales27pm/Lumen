import Foundation
import UIKit

enum MemoryPressureUnloadPolicy {
    static let slotPriority: [LumenModelSlot] = [.mimicry, .rem, .executor, .cortex, .mouth]
}

@MainActor
final class MemoryPressureMonitor {
    private(set) var warningCount: Int = 0
    private(set) var lastWarningAt: Date?
    private let metricsStore: RuntimeMetricsStore

    init(metricsStore: RuntimeMetricsStore = .shared, notificationCenter: NotificationCenter = .default) {
        self.metricsStore = metricsStore
        notificationCenter.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleWarning()
            }
        }
    }

    func handleWarning() async {
        warningCount += 1
        lastWarningAt = Date()
        FleetRuntimeCleanup.unloadOptionalChatSlots()
        let metric = RuntimeMetric(
            timestamp: Date(),
            runtimeName: "system",
            taskKind: "memoryPressure",
            modelIDHash: nil,
            policySummary: "optional slot cleanup",
            latencyMs: nil,
            success: true,
            errorCode: nil,
            thermalState: .from(processThermalState: ProcessInfo.processInfo.thermalState),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            memoryWarningCount: warningCount
        )
        try? await metricsStore.appendMetric(metric)
    }
}
