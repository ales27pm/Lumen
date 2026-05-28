import Foundation

actor AssistantKernel {
    private let router: AssistantRuntimeRouter
    private let metricsStore: RuntimeMetricsStore

    init(router: AssistantRuntimeRouter = .init(), metricsStore: RuntimeMetricsStore = .shared) {
        self.router = router
        self.metricsStore = metricsStore
    }

    func selectRuntime(for context: AssistantTurnContext) -> AssistantRuntimeKind {
        router.runtime(for: context)
    }

    func runTextTurn(_ context: AssistantTurnContext) async throws -> String {
        let selection = router.selection(for: context)
        let decision = ComputePolicy.decide(for: context)
        let request = TextGenerationRequest(prompt: context.input, systemPrompt: "", maxTokens: decision.maxTokens)
        let start = Date()

        do {
            let output: String
            switch selection.runtime {
            case .foundationModels:
                output = try await router.foundation.generate(request: request)
            case .llama:
                output = try await router.llama.generate(request: request)
            case .deterministicFallback, .coreML:
                output = try await router.fallback.generate(request: request)
            }
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            try? await metricsStore.appendMetric(RuntimeMetric(timestamp: Date(), runtimeName: selection.runtime.rawValue, taskKind: "\(context.task)", modelIDHash: nil, policySummary: selection.reason, latencyMs: latency, success: true, errorCode: nil, thermalState: .from(processThermalState: context.thermalState), lowPowerMode: context.lowPowerMode, memoryWarningCount: 0))
            return output
        } catch {
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            try? await metricsStore.appendMetric(RuntimeMetric(timestamp: Date(), runtimeName: selection.runtime.rawValue, taskKind: "\(context.task)", modelIDHash: nil, policySummary: selection.reason, latencyMs: latency, success: false, errorCode: String(describing: error), thermalState: .from(processThermalState: context.thermalState), lowPowerMode: context.lowPowerMode, memoryWarningCount: 0))
            throw error
        }
    }
}
