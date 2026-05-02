import Foundation

nonisolated enum LumenModelFleetCatalog {
    static let v1FineTunedMerged: [CatalogModel] = [
        CatalogModel(
            id: "fleet-v1-ft-cortex-qwen1.5b-q4",
            name: "Fleet v1 FT Cortex — Qwen 1.5B",
            repoId: "ales27pm/lumen-fleet-gguf",
            fileName: "lumen-cortex-merged-q4_k_m.gguf",
            parameters: "1.5B",
            quantization: "Q4_K_M",
            sizeBytes: 1_150_000_000,
            role: .chat,
            description: "Merged fine-tuned Cortex slot model for routing and planning.",
            tags: ["fleet-v1", "finetuned", "merged-gguf", "cortex"]
        ),
        CatalogModel(
            id: "fleet-v1-ft-executor-qwen1.5b-q4",
            name: "Fleet v1 FT Executor — Qwen 1.5B",
            repoId: "ales27pm/lumen-fleet-gguf",
            fileName: "lumen-executor-merged-q4_k_m.gguf",
            parameters: "1.5B",
            quantization: "Q4_K_M",
            sizeBytes: 1_150_000_000,
            role: .chat,
            description: "Merged fine-tuned Executor slot model for strict tool JSON.",
            tags: ["fleet-v1", "finetuned", "merged-gguf", "executor", "structured"]
        ),
        CatalogModel(
            id: "fleet-v1-ft-mouth-qwen1.5b-q4",
            name: "Fleet v1 FT Mouth — Qwen 1.5B",
            repoId: "ales27pm/lumen-fleet-gguf",
            fileName: "lumen-mouth-merged-q4_k_m.gguf",
            parameters: "1.5B",
            quantization: "Q4_K_M",
            sizeBytes: 1_150_000_000,
            role: .chat,
            description: "Merged fine-tuned Mouth slot model for user-facing responses.",
            tags: ["fleet-v1", "finetuned", "merged-gguf", "mouth"]
        ),
        CatalogModel(
            id: "fleet-v1-ft-mimicry-qwen1.5b-q4",
            name: "Fleet v1 FT Mimicry — Qwen 1.5B",
            repoId: "ales27pm/lumen-fleet-gguf",
            fileName: "lumen-mimicry-merged-q4_k_m.gguf",
            parameters: "1.5B",
            quantization: "Q4_K_M",
            sizeBytes: 1_150_000_000,
            role: .chat,
            description: "Merged fine-tuned Mimicry slot model for safe style adaptation.",
            tags: ["fleet-v1", "finetuned", "merged-gguf", "mimicry"]
        ),
        CatalogModel(
            id: "fleet-v1-ft-rem-qwen1.5b-q4",
            name: "Fleet v1 FT REM — Qwen 1.5B",
            repoId: "ales27pm/lumen-fleet-gguf",
            fileName: "lumen-rem-merged-q4_k_m.gguf",
            parameters: "1.5B",
            quantization: "Q4_K_M",
            sizeBytes: 1_150_000_000,
            role: .chat,
            description: "Merged fine-tuned REM slot model for reflection and repair.",
            tags: ["fleet-v1", "finetuned", "merged-gguf", "rem", "idle"]
        ),
    ]

    static let v1Recommended: [CatalogModel] = [
        CatalogModel(
            id: "fleet-v1-core-qwen-coder-0.5b-q4",
            name: "Fleet v1 Core — Qwen Coder 0.5B",
            repoId: "Qwen/Qwen2.5-Coder-0.5B-Instruct-GGUF",
            fileName: "qwen2.5-coder-0.5b-instruct-q4_k_m.gguf",
            parameters: "0.5B",
            quantization: "Q4_K_M",
            sizeBytes: 397_000_000,
            role: .chat,
            description: "Tiny code-aware base for Cortex and structured coordination in v1.",
            tags: ["fleet-v1", "cortex", "structured", "tiny"]
        ),
        CatalogModel(
            id: "fleet-v1-voice-qwen-0.5b-q4",
            name: "Fleet v1 Voice — Qwen 0.5B",
            repoId: "Qwen/Qwen2.5-0.5B-Instruct-GGUF",
            fileName: "qwen2.5-0.5b-instruct-q4_k_m.gguf",
            parameters: "0.5B",
            quantization: "Q4_K_M",
            sizeBytes: 397_000_000,
            role: .chat,
            description: "Small response and tone base for Mouth and Mimicry in v1.",
            tags: ["fleet-v1", "mouth", "mimicry", "fast"]
        ),
        CatalogModel(
            id: "fleet-v1-rem-smollm2-1.7b-q4",
            name: "Fleet v1 REM — SmolLM2 1.7B",
            repoId: "HuggingFaceTB/SmolLM2-1.7B-Instruct-GGUF",
            fileName: "smollm2-1.7b-instruct-q4_k_m.gguf",
            parameters: "1.7B",
            quantization: "Q4_K_M",
            sizeBytes: 1_120_000_000,
            role: .chat,
            description: "Idle-cycle reflection base for summarizing traces and preparing training records.",
            tags: ["fleet-v1", "rem", "idle", "apache-2.0"]
        ),
        CatalogModel(
            id: "fleet-v1-nomic-embed-q4",
            name: "Fleet v1 Memory — Nomic Embed v1.5",
            repoId: "nomic-ai/nomic-embed-text-v1.5-GGUF",
            fileName: "nomic-embed-text-v1.5.Q4_K_M.gguf",
            parameters: "137M",
            quantization: "Q4_K_M",
            sizeBytes: 85_000_000,
            role: .embedding,
            description: "Semantic memory model for recall and codebase knowledge chunks.",
            tags: ["fleet-v1", "memory", "embedding", "tiny"]
        )
    ]

    static let v1Candidates: [CatalogModel] = [
        CatalogModel(
            id: "fleet-v1-qwen-coder-1.5b-q4",
            name: "Fleet v1 Cortex — Qwen Coder 1.5B",
            repoId: "Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF",
            fileName: "qwen2.5-coder-1.5b-instruct-q4_k_m.gguf",
            parameters: "1.5B",
            quantization: "Q4_K_M",
            sizeBytes: 1_117_000_000,
            role: .chat,
            description: "Recommended dedicated v1 orchestrator.",
            tags: ["fleet-v1", "cortex", "coder"]
        ),
        CatalogModel(
            id: "fleet-v1-phi3.5-mini-q4",
            name: "Fleet v1 REM — Phi 3.5 Mini",
            repoId: "bartowski/Phi-3.5-mini-instruct-GGUF",
            fileName: "Phi-3.5-mini-instruct-Q4_K_M.gguf",
            parameters: "3.8B",
            quantization: "Q4_K_M",
            sizeBytes: 2_390_000_000,
            role: .chat,
            description: "Heavier idle-only reasoning model for advanced self-improvement cycles.",
            tags: ["fleet-v1", "rem", "idle-only"]
        )
    ]

    static var allFleetModels: [CatalogModel] { v1FineTunedMerged + v1Recommended + v1Candidates }
}
