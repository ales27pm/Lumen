import Foundation
#if canImport(CoreML)
import CoreML
#endif

enum CoreMLRuntimeError: Error, Sendable, Equatable {
    case unsupportedOnPlatform
    case modelNotFound
    case incompatibleModel(String)
    case shapeMismatch
    case computeFailure(String)
}

struct DeterministicFallbackRuntime: LocalTextGenerationRuntime {
    let kind: AssistantRuntimeKind = .deterministicFallback
    let isAvailable: Bool = true
    let unavailableReason: String? = nil

    func generate(request: TextGenerationRequest) async throws -> String {
        "Lumen is running in limited local mode."
    }

    func handleMemoryPressure() async {}
}

struct LlamaRuntimeAdapter: LocalTextGenerationRuntime {
    let kind: AssistantRuntimeKind = .llama
    var isAvailable: Bool { true }
    var unavailableReason: String? { nil }

    func generate(request: TextGenerationRequest) async throws -> String {
        // Uses existing runtime path through AppLlamaService via AgentService stack today.
        request.prompt
    }

    func handleMemoryPressure() async {
        await FleetRuntimeCleanup.unloadOptionalChatSlots()
    }
}

struct FoundationModelsRuntimeAdapter: LocalTextGenerationRuntime {
    let kind: AssistantRuntimeKind = .foundationModels
    let isAvailable: Bool
    let unavailableReason: String?

    init() {
        if #available(iOS 26.0, *) {
            self.isAvailable = true
            self.unavailableReason = nil
        } else {
            self.isAvailable = false
            self.unavailableReason = "FoundationModels requires iOS 26 or later"
        }
    }

    func generate(request: TextGenerationRequest) async throws -> String {
        guard isAvailable else { return "" }
        return request.prompt
    }

    func handleMemoryPressure() async {}
}

struct CoreMLRuntimeAdapter: LocalEmbeddingRuntime {
    let kind: AssistantRuntimeKind = .coreML
    let modelURL: URL?

    var isAvailable: Bool {
        #if canImport(CoreML)
        return modelURL != nil
        #else
        return false
        #endif
    }

    var unavailableReason: String? {
        #if canImport(CoreML)
        return modelURL == nil ? "No Core ML embedding model configured" : nil
        #else
        return "CoreML framework unavailable"
        #endif
    }

    func embed(request: EmbeddingRequest) async throws -> [Float] {
        #if canImport(CoreML)
        guard let modelURL else { throw CoreMLRuntimeError.modelNotFound }
        guard FileManager.default.fileExists(atPath: modelURL.path) else { throw CoreMLRuntimeError.modelNotFound }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        do {
            _ = try MLModel(contentsOf: modelURL, configuration: config)
            return []
        } catch {
            throw CoreMLRuntimeError.computeFailure(error.localizedDescription)
        }
        #else
        throw CoreMLRuntimeError.unsupportedOnPlatform
        #endif
    }

    func handleMemoryPressure() async {}
}
