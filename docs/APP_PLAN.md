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

### Embedding model configuration and override policy

The embedding model must be configurable and reversible. Do not hard-code the Qwen3 embedding model as an irreversible runtime dependency.

Planned configuration keys:

```json
{
  "embedding": {
    "defaultModelID": "Qwen/Qwen3-Embedding-0.6B",
    "fallbackModelID": "current-baseline-embedding-model",
    "teacherModelID": "Qwen/Qwen3-Embedding-4B",
    "provider": "local",
    "quantization": "runtime-selected",
    "enableQwen3EmbeddingCandidate": true,
    "allowRuntimeFallback": true
  }
}
```

Required override layers, from highest to lowest priority:

1. explicit developer/test override in the app settings or debug configuration;
2. environment/build flag used by CI/TestFlight experiments;
3. persisted app configuration bundled with the model manifest;
4. generated dataset/model card default;
5. compiled fallback default.

Suggested environment or build flags:

```text
LUMEN_EMBEDDING_MODEL_ID=Qwen/Qwen3-Embedding-0.6B
LUMEN_EMBEDDING_FALLBACK_MODEL_ID=<current-baseline-embedding-model>
LUMEN_ENABLE_QWEN3_EMBEDDING=1
LUMEN_FORCE_BASELINE_EMBEDDING=0
```

Rollback behaviour:

- if Qwen3 embedding evals regress below the migration gates, set `LUMEN_FORCE_BASELINE_EMBEDDING=1` for the next build/run;
- if the Qwen3 model fails to load, produces invalid vector dimensions, or fails health checks, automatically fall back to `fallbackModelID` when `allowRuntimeFallback=true`;
- if fallback happens, the in-app dataset export must include `embeddingModelID`, `embeddingFallbackModelID`, `usedEmbeddingFallback`, and the health-check failure reason;
- the next improvement-loop cycle must ingest that fallback signal and add a gap if Qwen3 fallback occurred in TestFlight.

Required runtime export fields:

```json
{
  "embeddingModelID": "Qwen/Qwen3-Embedding-0.6B",
  "embeddingFallbackModelID": "current-baseline-embedding-model",
  "usedEmbeddingFallback": false,
  "embeddingVectorDimension": 0,
  "embeddingHealthCheckPassed": true,
  "embeddingEvalSummary": {
    "recallAt1": 0.0,
    "recallAt5": 0.0,
    "mrr": 0.0,
    "ndcgAt5": 0.0,
    "hardNegativeAccuracy": 0.0
  }
}
```

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

Initial numeric targets for the first Qwen3 embedding promotion gate:

| Metric | Minimum target | Preferred target | Notes |
|---|---:|---:|---|
| Recall@1 | >= 0.72 | >= 0.80 | Measured over `eval_retrieval.jsonl`; strict top hit. |
| Recall@5 | >= 0.90 | >= 0.95 | Required for RAG usability. |
| MRR | >= 0.78 | >= 0.85 | Penalizes correct hits buried too low. |
| nDCG@5 | >= 0.82 | >= 0.90 | Use graded relevance when multiple positives exist. |
| hard-negative accuracy | >= 0.85 | >= 0.92 | Must distinguish similar tools/intents. |
| tool-retrieval accuracy | >= 0.90 | >= 0.95 | Tool queries must retrieve the correct tool schema. |
| source-map retrieval accuracy | >= 0.80 | >= 0.88 | Code/source awareness retrieval. |
| runtime-repair retrieval accuracy | >= 0.78 | >= 0.86 | Failed runtime traces should retrieve the right repair family. |
| embedding health-check pass rate | 100% | 100% | Vector dimension, non-empty embeddings, no NaN/Inf. |

Promotion rule: Qwen3-Embedding-0.6B may become the default only if it meets every minimum target and is not worse than the baseline by more than 2 percentage points on any required metric. If it beats the baseline by at least 3 percentage points on Recall@5 or hard-negative accuracy without latency regression, promote it for the next TestFlight cycle.

Rollback rule: roll back to the configured fallback embedding model if any required metric drops below minimum, if hard-negative accuracy regresses by more than 5 percentage points, or if TestFlight runtime fallback occurs more than once in a release candidate cycle.

### Required behaviour eval metrics

Agent model migration must also use numeric gates. Initial targets:

| Metric | Minimum target | Preferred target | Applies to |
|---|---:|---:|---|
| manifest-only tool use | >= 0.98 | 1.00 | Cortex, Executor |
| hallucinated-tool rejection | >= 0.98 | 1.00 | Cortex, Executor |
| required-argument handling | >= 0.92 | >= 0.97 | Cortex, Executor |
| strict JSON validity | >= 0.98 | 1.00 | Executor |
| approval/permission boundary accuracy | >= 0.95 | >= 0.99 | Cortex, Executor, Mouth |
| sentinel suppression | 1.00 | 1.00 | Mouth, all user-facing paths |
| runtime repair usefulness | >= 0.85 | >= 0.92 | REM |
| fleet peer-boundary accuracy | >= 0.95 | >= 0.99 | Fleet/self-awareness records |
| TestFlight/E2E pass rate | >= 0.90 | >= 0.95 | Full app loop |
| crash-free TestFlight scenario run | 100% | 100% | Full app loop |
| P95 local response latency regression | <= +10% | <= +5% | Compared with current baseline |
| peak memory regression | <= +10% | <= +5% | Compared with current baseline |

Promotion rule: a Qwen3 candidate may replace a role only if it meets every minimum target, has zero sentinel leaks, has zero crash regressions in the TestFlight scenario batch, and is no worse than the baseline by more than 2 percentage points on any role-critical metric.

Rollback rule: immediately revert the role to the baseline model if TestFlight/E2E pass rate drops below 0.90, if any sentinel leak appears, if manifest-only tool use drops below 0.98, or if latency/memory regressions exceed the allowed thresholds.

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
    "fallbackModel": "current-baseline-embedding-model",
    "usedFallback": false,
    "corpusCount": 0,
    "pairCount": 0,
    "tripletCount": 0,
    "hardNegativeCount": 0,
    "evalCount": 0,
    "metrics": {
      "recallAt1": 0.0,
      "recallAt5": 0.0,
      "mrr": 0.0,
      "ndcgAt5": 0.0,
      "hardNegativeAccuracy": 0.0,
      "toolRetrievalAccuracy": 0.0,
      "sourceMapRetrievalAccuracy": 0.0,
      "runtimeRepairRetrievalAccuracy": 0.0
    }
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

Use the numeric targets in the retrieval and behaviour metrics sections as the initial objective gates. Revise targets upward after the first stable baseline is measured.

### Non-goals

- Do not switch every agent model to Qwen3 without an A/B run.
- Do not use a normal chat model as an embedding model unless it is adapted and evaluated as an embedding model.
- Do not train the embedding model on conversational SFT records as if it were a chat agent.
- Do not expose raw private runtime state or hidden reasoning in embedding corpus records.
- Do not remove the baseline/fallback model until Qwen3 passes two consecutive TestFlight improvement-loop cycles.

### Decision

Adopt a Qwen3-first strategy, starting with:

```text
Embedding default: Qwen/Qwen3-Embedding-0.6B
Embedding fallback: current baseline embedding model until Qwen3 passes promotion gates
Agent baseline: current Qwen2.5 1.5B-style models
Agent migration: staged Qwen3 candidates, promoted only by Lumen-specific evals
```
