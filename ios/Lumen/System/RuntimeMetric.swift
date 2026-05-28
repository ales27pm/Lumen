import Foundation

struct RuntimeMetric: Codable, Sendable, Equatable {
    let timestamp: Date
    let runtimeName: String
    let taskKind: String
    let modelIDHash: String?
    let policySummary: String
    let latencyMs: Int?
    let success: Bool
    let errorCode: String?
    let thermalState: DeviceThermalState
    let lowPowerMode: Bool
    let memoryWarningCount: Int
}
