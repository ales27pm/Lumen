# Lumen App Plan

This document tracks strategic implementation work for Lumen that should survive beyond one generated dataset cycle.

## Qwen3-first model migration plan

### Goal

Move Lumen toward a Qwen3-first model stack while preserving the current Qwen2.5-based agent models as the baseline until the app-specific evaluation loop proves that Qwen3 is better for Lumen's real runtime behaviour.

The target is not a blind model swap. The target is a measured migration where each model role improves on:

- manifest obedience;
- tool-routing accuracy;
- strict JSON/tool-call discipline;
- source-code and fleet self-awareness;
- runtime repair quality;
- RAG/memory retrieval quality;
- TestFlight/E2E behaviour;
- latency, memory, battery, and thermal behaviour.

### Recommended baseline

Keep the current Qwen2.5 1.5B-style agent models as the benchmark baseline until Qwen3 candidates beat them on Lumen-specific evals.

### Immediate model addition

Add the official Qwen3 embedding model as the default embedding candidate:

```text
Qwen/Qwen3-Embedding-0.6B
```

Use it for:

- source-code manifest retrieval;
- tool schema retrieval;
- routing rule retrieval;
- fleet/peer role retrieval;
- memory and RAG retrieval;
- runtime audit failure clustering;
- E2E failure to repair-sample retrieval;
- source map and code-domain retrieval.

Reasoning: Qwen3-Embedding-0.6B is official, embedding-native, Qwen-family, sentence-transformers compatible, and much more appropriate than low-adoption Qwen2.5 community embedding conversions for Lumen's core retrieval layer.

### Optional benchmark model

Track this as a heavier local/server benchmark, not the default mobile/runtime embedding model:

```text
Qwen/Qwen3-Embedding-4B
```

Use it to compare retrieval quality, generate teacher labels, or benchmark whether larger embedding capacity improves Lumen's retrieval tasks enough to justify the cost.

### Candidate migration order

Do not migrate every role at once. Add Qwen3 candidates in this order:

1. **Embedding** — safest and highest-confidence improvement.
2. **Cortex** — routing and tool-selection accuracy are easy to measure.
3. **REM** — runtime repair quality is structured and can be evaluated without high user-facing risk.
4. **Executor** — migrate only after strict JSON/tool-call evals pass.
5. **Mouth** — migrate after sentinel suppression, failure summaries, and user-facing quality are stable.
6. **Mimicry** — migrate after style adaptation preserves facts and safety boundaries.
7. **Fleet/self-awareness** — migrate after source-map and peer-boundary evals are stable.

### Required generated embedding datasets

Add a first-class embedding dataset generator to the improvement loop. The embedding model should not be trained on chat SFT records. It needs retrieval, similarity, ranking, and hard-negative data.

Planned output directory:

```text
generated/agent_manifest/embedding/
├── corpus.jsonl
├── train_pairs.jsonl
├── val_pairs.jsonl
├── train_triplets.jsonl
├── val_triplets.jsonl
├── hard_negatives.jsonl
├── eval_retrieval.jsonl
└── dataset_card.json
```

Required corpus object types:

- tool schema;
- intent;
- routing rule;
- source-file summary;
- fleet slot;
- peer boundary;
- memory scope;
- runtime failure;
- repair sample;
- eval scenario;
- manifest grounding card;
- source-code map entry.

Required pair/triplet families:

- natural user query → relevant tool schema;
- natural user query → relevant intent/routing rule;
- runtime failure → repair sample;
- E2E failure → corrected runtime repair;
- tool ID → source file and tool contract;
- source file → extracted manifest concept;
- agent role question → fleet slot / peer boundary;
- memory/RAG query → relevant memory or RAG chunk;
- permission/approval request → boundary rule;
- code-domain query → source-code map entry.

Required hard-negative families:

- `mail.draft` vs `outlook.draft.create`;
- `web.search` vs `web.fetch`;
- `memory.save` vs `memory.recall`;
- `calendar.create` vs `reminders.create`;
- `maps.search` vs `maps.directions`;
- `trigger.create` vs `reminders.create`;
- tool schema vs similarly named but wrong tool;
- runtime repair sample vs unrelated repair sample;
- fleet peer role vs wrong peer role.

### Required retrieval eval metrics

The loop should emit retrieval evals and track:

- Recall@1;
- Recall@5;
- MRR;
- nDCG;
- hard-negative accuracy;
- tool-retrieval accuracy;
- source-map retrieval accuracy;
- runtime-repair retrieval accuracy.

### Improvement-loop integration

Add the embedding generator to:

- `tools/lumen_manifest_crawler/lumen_manifest_crawler/dataset/embedding.py`;
- `tools/lumen_manifest_crawler/lumen_manifest_crawler/dataset/__init__.py`;
- `tools/lumen_manifest_crawler/lumen_manifest_crawler/output/writer.py`;
- `tools/lumen_manifest_crawler/lumen_manifest_crawler/improvement_loop.py`;
- validators/tests;
- generated dataset cards and loop summaries.

The loop summary should include:

```json
{
  "embedding": {
    "model": "Qwen/Qwen3-Embedding-0.6B",
    "corpusCount": 0,
    "pairCount": 0,
    "tripletCount": 0,
    "hardNegativeCount": 0,
    "evalCount": 0
  }
}
```

Counts should become non-zero once implementation is complete.

### Migration gates

A Qwen3 candidate may replace an existing model role only if it beats or matches the current Qwen2.5 baseline on:

- manifest-only tool use;
- hallucinated-tool rejection;
- required argument handling;
- approval/permission boundary behaviour;
- sentinel suppression;
- runtime repair quality;
- TestFlight/E2E pass rate;
- latency/memory budget;
- deterministic dataset validation.

### Non-goals

- Do not switch every agent model to Qwen3 without an A/B run.
- Do not use a normal chat model as an embedding model unless it is adapted and evaluated as an embedding model.
- Do not train the embedding model on conversational SFT records as if it were a chat agent.
- Do not expose raw private runtime state or hidden reasoning in embedding corpus records.

### Decision

Adopt a Qwen3-first strategy, starting with:

```text
Embedding default: Qwen/Qwen3-Embedding-0.6B
Agent baseline: current Qwen2.5 1.5B-style models
Agent migration: staged Qwen3 candidates, promoted only by Lumen-specific evals
```
