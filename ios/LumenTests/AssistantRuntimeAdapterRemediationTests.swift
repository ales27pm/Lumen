import XCTest
@testable import Lumen

final class AssistantRuntimeAdapterRemediationTests: XCTestCase {
    func testLlamaAndFoundationDoNotEchoPrompt() async {
        let request = TextGenerationRequest(prompt: "private prompt", systemPrompt: "", maxTokens: 16)
        do {
            _ = try await LlamaRuntimeAdapter(isAvailable: true, unavailableReason: nil).generate(request: request)
            XCTFail("Llama adapter should not produce prompt echo")
        } catch {}
        do {
            _ = try await FoundationModelsRuntimeAdapter().generate(request: request)
            XCTFail("FoundationModels adapter should not produce prompt echo")
        } catch {}
    }

    func testCoreMLMissingFileUnavailable() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let runtime = CoreMLRuntimeAdapter(modelURL: url)
        XCTAssertFalse(runtime.isAvailable)
        XCTAssertEqual(runtime.unavailableReason, "Configured Core ML model file is missing")
    }

    func testMetricErrorSanitizerDoesNotExposeDescription() {
        let code = RuntimeMetricErrorSanitizer.code(for: LocalRuntimeError.unavailable("raw private text"))
        XCTAssertEqual(code, "runtime_unavailable")
        XCTAssertFalse(code.contains("raw private text"))
    }
}
