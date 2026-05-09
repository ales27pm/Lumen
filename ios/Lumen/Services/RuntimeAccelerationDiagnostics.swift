import Foundation
import Metal

nonisolated struct RuntimeAccelerationDiagnostics: Codable, Sendable, Hashable {
    let backendRequested: String
    let metalDeviceAvailable: Bool
    let metalDeviceName: String?
    let metalLowPower: Bool?
    let metalHeadless: Bool?
    let metalUnifiedMemory: Bool?
    let recommendedMaxWorkingSetSizeMB: Double?
    let requestedGpuLayers: Int?
    let requestedKQVOffload: Bool?
    let actualBackend: String?
    let actualOffloadedLayers: Int?
    let actualGpuMemoryMB: Double?
    let actualGpuUtilizationPercent: Double?
    let aneAvailable: Bool?
    let aneUsedByCurrentRuntime: Bool
    let aneUtilizationPercent: Double?
    let verificationLevel: String
    let notes: [String]

    static func forCurrentRuntime(requestedBackend: String, requestedGpuLayers: Int?, requestedKQVOffload: Bool?, actualBackend: String? = nil, notes extra: [String] = []) -> RuntimeAccelerationDiagnostics {
        let device = MTLCreateSystemDefaultDevice()
        let deviceAvailable = device != nil
        var notes = extra
        notes.append("ANE is not used by the GGUF/llama.cpp runtime. ANE requires a Core ML / ANE-compatible runtime path.")
        if actualBackend == nil && requestedBackend == "metal" {
            notes.append("llama.cpp backend log callback unavailable from current Swift wrapper; actual Metal offload cannot be confirmed in-app.")
        }
        let verification: String
        if requestedBackend == "cpu" {
            verification = "cpu_only"
        } else if requestedBackend == "metal" && actualBackend == nil {
            verification = "requested_unverified"
        } else if actualBackend != nil {
            verification = "confirmed"
        } else {
            verification = "unavailable"
        }
        return RuntimeAccelerationDiagnostics(
            backendRequested: requestedBackend,
            metalDeviceAvailable: deviceAvailable,
            metalDeviceName: device?.name,
            metalLowPower: device?.isLowPower,
            metalHeadless: device?.isHeadless,
            metalUnifiedMemory: device?.hasUnifiedMemory,
            recommendedMaxWorkingSetSizeMB: device.map { Double($0.recommendedMaxWorkingSetSize) / (1024 * 1024) },
            requestedGpuLayers: requestedGpuLayers,
            requestedKQVOffload: requestedKQVOffload,
            actualBackend: actualBackend,
            actualOffloadedLayers: nil,
            actualGpuMemoryMB: nil,
            actualGpuUtilizationPercent: nil,
            aneAvailable: nil,
            aneUsedByCurrentRuntime: false,
            aneUtilizationPercent: nil,
            verificationLevel: verification,
            notes: notes
        )
    }
}
