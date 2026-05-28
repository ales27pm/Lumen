# RAG Engine

Phase 6 adds `RAGEngine` and `RAGIndexer` wrappers around `RAGStore`/`RAGChunk`.

- Retrieval: semantic-first through existing `RAGStore.search`, with lexical fallback behavior preserved.
- Deduplication: by source+excerpt hash.
- Context builder applies strict char budgets.
- Chunking strategy supports plain text, markdown, and code-oriented splits.
- Maintenance hook exists for background orchestration.

No fake embeddings are generated: embedding calls rely on existing local runtime (`AppLlamaService.embed`).
