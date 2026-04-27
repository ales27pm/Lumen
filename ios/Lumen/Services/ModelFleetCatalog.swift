import Foundation

nonisolated enum LumenModelFleetCatalog {
    static let v0Recommended: [CatalogModel] = [
        CatalogModel(
            id: "fleet-v0-qwen-coder-0.5b-q4",
            name: "Fleet v0 Core — Qwen Coder 0.5B",
            repoId: "Qwen/Qwen2.5-Coder-0.5B-Instruct-GGUF",
            fileName: "qwen2.5-coder-0.5b-instruct-q4_k_m.gguf",
            parameters: "0.5B",
            quantization: "Q4_K_M",
            sizeBytes: 397_000_000,
            role: .chat,
            description: "Tiny code-aware base for Cortex and the structured action layer in v0.",
            tags: ["fleet-v0", "cortex", "structured", "tiny"]
        ),
        CatalogModel(
            id: "fleet-v0-qwen-0.5b-q4",
            name: "Fleet v0 Voice — Qwen 0.5B",
            repoId: "Qwen/Qwen2.5-0.5B-Instruct-GGUF",
            fileName: "qwen2.5-0.5b-instruct-q4_k_m.gguf",
            parameters: "0.5B",
            quantization: "Q4_K_M",
            sizeBytes: 397_000_000,
            role: .chat,
            description: "Small response and tone base for Mouth and Mimicry in v0.",
            tags: ["fleet-v0", "mouth", "mimicry", "fast"]
        ),
        CatalogModel(
            id: "fleet-v0-smollm2-1.7b-q4",
            name: "Fleet v0 REM — SmolLM2 1.7B",
            repoId: "HuggingFaceTB/SmolLM2-1.7B-Instruct-GGUF",
            fileName: "smollm2-1.7b-instruct-q4_k_m.gguf",
            parameters: "1.7B",
            quantization: "Q4_K_M",
            sizeBytes: 1_120_000_000,
            role: .chat,
            description: "Idle-cycle reflection base for summarizing traces and preparing training records.",
            tags: ["fleet-v0", "rem", "idle", "apache-2.0"]
        ),
        CatalogModel(
            id: "fleet-v0-nomic-embed-q4",
            name: "Fleet Memory — Nomic Embed v1.5",
            repoId: "nomic-ai/nomic-embed-text-v1.5-GGUF",
            fileName: "nomic-embed-text-v1.5.Q4_K_M.gguf",
            parameters: "137M",
            quantization: "Q4_K_M",
            sizeBytes: 85_000_000,
            role: .embedding,
            description: "Tiny semantic memory model for recall and codebase knowledge chunks.",
            tags: ["memory", "embedding", "tiny"]
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
            description: "Recommended dedicated v1 orchestrator once the v0 loop is stable.",
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

    static var allFleetModels: [CatalogModel] { v0Recommended + v1Candidates }
}
