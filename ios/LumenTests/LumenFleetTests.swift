import Testing
@testable import Lumen

struct LumenFleetTests {
    @Test func contractValidationFailsDeterministicallyWhenSlotMappingIsMissing() async throws {
        var mapping: [LumenModelSlot: LumenModelSlotContract] = [
            .cortex: .cortex,
            .executor: .executor,
            .mouth: .mouth,
            .mimicry: .mimicry,
            .rem: .rem,
            .embedding: .embedding,
        ]
        mapping.removeValue(forKey: .rem)

        do {
            try LumenModelSlotContract.validateCompleteness(using: mapping)
            Issue.record("Expected validation to throw for missing slot contract")
        } catch let error as LumenModelSlotContract.ContractError {
            guard case .incompleteMapping(let missingSlots, _, _) = error else {
                Issue.record("Expected incompleteMapping error")
                return
            }
            #expect(missingSlots == [.rem])
        }
    }

    @Test func requiredContractThrowsForMissingSlotWithoutFallback() async throws {
        do {
            _ = try LumenModelSlotContract.requiredContract(for: .rem, using: [.cortex: .cortex])
            Issue.record("Expected missingContract error")
        } catch let error as LumenModelSlotContract.ContractError {
            guard case .missingContract(let slot, _, let modelConfigVersion) = error else {
                Issue.record("Expected missingContract error")
                return
            }
            #expect(slot == .rem)
            #expect(modelConfigVersion == LumenModelSlotContract.fleetContractVersion)
        }
    }

    @Test @MainActor func v0ResolverAssignsAllTextSlotsFromSingleSmallChatModel() async throws {
        let chat = StoredModel(
            name: "Qwen2.5 Coder Fleet",
            repoId: "Qwen/Qwen2.5-Coder-0.5B-Instruct-GGUF",
            fileName: "qwen2.5-coder-0.5b-instruct-q4_k_m.gguf",
            sizeBytes: 450_000_000,
            quantization: "Q4_K_M",
            parameters: "0.5B",
            role: .chat,
            localPath: "/tmp/qwen2.5-coder-0.5b-instruct-q4_k_m.gguf"
        )
        let embedding = StoredModel(
            name: "Nomic Embed",
            repoId: "nomic-ai/nomic-embed-text-v1.5-GGUF",
            fileName: "nomic-embed-text-v1.5.Q4_K_M.gguf",
            sizeBytes: 85_000_000,
            quantization: "Q4_K_M",
            parameters: "137M",
            role: .embedding,
            localPath: "/tmp/nomic-embed-text-v1.5.Q4_K_M.gguf"
        )

        let snapshot = LumenModelFleetResolver.resolveV0(
            activeChatModelID: chat.id.uuidString,
            activeEmbeddingModelID: embedding.id.uuidString,
            storedModels: [chat, embedding]
        )

        #expect(snapshot.mode == .v0SingleRuntime)
        #expect(snapshot.isRunnableV0)
        #expect(snapshot.missingSlots.isEmpty)
        #expect(snapshot.assignment(for: .cortex)?.modelID == chat.id)
        #expect(snapshot.assignment(for: .executor)?.modelID == chat.id)
        #expect(snapshot.assignment(for: .mouth)?.modelID == chat.id)
        #expect(snapshot.assignment(for: .mimicry)?.modelID == chat.id)
        #expect(snapshot.assignment(for: .rem)?.modelID == chat.id)
        #expect(snapshot.assignment(for: .embedding)?.modelID == embedding.id)
        #expect(snapshot.runtimeResidentSlots == Set(LumenModelSlot.allCases))
        #expect(snapshot.targetResidentSlots == Set(LumenModelSlot.allCases))
    }

    @Test @MainActor func fleetResolverKeepsEmbeddingAssignmentWhenHintsDoNotMatch() async throws {
        let chat = StoredModel(
            name: "Local Chat",
            repoId: "local/chat",
            fileName: "local-chat.gguf",
            sizeBytes: 1,
            quantization: "local",
            parameters: "local",
            role: .chat,
            localPath: "/tmp/local-chat.gguf"
        )
        let customEmbedding = StoredModel(
            name: "Vector Store Model",
            repoId: "local/vector-store-model",
            fileName: "vectors.gguf",
            sizeBytes: 1,
            quantization: "local",
            parameters: "local",
            role: .embedding,
            localPath: "/tmp/vectors.gguf"
        )

        let snapshot = LumenModelFleetResolver.resolveV1(
            activeChatModelID: chat.id.uuidString,
            activeEmbeddingModelID: nil,
            storedModels: [chat, customEmbedding]
        )

        #expect(snapshot.assignment(for: .embedding)?.modelID == customEmbedding.id)
        #expect(!snapshot.missingSlots.contains(.embedding))
    }

    @Test @MainActor func v1ResolverPrefersRoleSpecificModelWhenAvailableButMarksPendingRuntimeSeparately() async throws {
        let general = StoredModel(
            name: "General Mouth Model",
            repoId: "HuggingFaceTB/SmolLM2-1.7B-Instruct-GGUF",
            fileName: "SmolLM2-1.7B-Instruct-Q4_K_M.gguf",
            sizeBytes: 1,
            quantization: "Q4_K_M",
            parameters: "1.7B",
            role: .chat,
            localPath: "/tmp/smollm.gguf"
        )
        let coder = StoredModel(
            name: "Qwen Coder Model",
            repoId: "Qwen/Qwen2.5-Coder-0.5B-Instruct-GGUF",
            fileName: "qwen2.5-coder-0.5b-instruct-q4_k_m.gguf",
            sizeBytes: 1,
            quantization: "Q4_K_M",
            parameters: "0.5B",
            role: .chat,
            localPath: "/tmp/coder.gguf"
        )
        let cortex = StoredModel(
            name: "Fleet v1 Cortex — Qwen Coder 1.5B",
            repoId: "Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF",
            fileName: "qwen2.5-coder-1.5b-instruct-q4_k_m.gguf",
            sizeBytes: 1,
            quantization: "Q4_K_M",
            parameters: "1.5B",
            role: .chat,
            localPath: "/tmp/cortex.gguf"
        )

        let snapshot = LumenModelFleetResolver.resolveV1(
            activeChatModelID: general.id.uuidString,
            activeEmbeddingModelID: nil,
            storedModels: [general, coder, cortex]
        )

        #expect(snapshot.mode == .v1MultiResidentPlanned)
        #expect(snapshot.assignment(for: .cortex)?.modelID == cortex.id)
        #expect(snapshot.assignment(for: .executor)?.modelID == coder.id)
        #expect(snapshot.assignment(for: .rem)?.modelID == general.id)
        #expect(snapshot.targetResidentSlots.contains(.cortex))
        #expect(snapshot.targetResidentSlots.contains(.executor))
        #expect(snapshot.runtimeResidentSlots.contains(.cortex))
        #expect(!snapshot.runtimeResidentSlots.contains(.executor))
    }
}
