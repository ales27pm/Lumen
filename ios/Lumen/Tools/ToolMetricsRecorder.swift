import Foundation

actor ToolMetricsRecorder {
    let store: RuntimeMetricsStore
    init(store: RuntimeMetricsStore = .shared) { self.store = store }
    func record(toolID: ToolID, status: ToolResultStatus, success: Bool, errorCode: String? = nil) async {
        let metric = RuntimeMetric(timestamp: Date(), runtimeName: "tool", taskKind: toolID, modelIDHash: nil, policySummary: status.rawValue, latencyMs: nil, success: success, errorCode: errorCode, thermalState: .from(processThermalState: ProcessInfo.processInfo.thermalState), lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, memoryWarningCount: 0)
        try? await store.appendMetric(metric)
    }
}
