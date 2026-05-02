# Lumen Manifest Crawler

The Lumen Manifest Crawler is the deterministic bridge between the Swift runtime, the in-app audit loop, and the model fine-tuning pipeline.

It extracts the real source-of-truth from the Lumen / monGARS codebase and writes an `AgentBehaviorManifest.json` plus role-specific, compiled, runtime-repair, and fleet self-knowledge artifacts for:

- Cortex
- Tool Executor
- Mouth
- Mimicry
- REM
- SFT train / validation
- DPO preference pairs
- eval scenarios
- runtime audit repair records
- fleet system prompts
- cross-model self/peer/delegation training
- a compact Markdown manifest for RAG or prompt injection

## Why this exists

LLM agents drift when they are trained on stale examples, invented tool names, outdated memory scopes, or synthetic schemas that no longer match the app. This crawler prevents that by deriving the training source from Swift files that actually define the runtime.

The pipeline combines two truth sources:

1. **Static Swift source analysis** from the repository.
2. **In-app runtime audit JSON** exported from the Lumen app, when provided.

It now also emits fleet self-knowledge artifacts so every model slot can learn:

1. **Who am I?** Role, responsibilities, tools, memory scopes, output contract.
2. **Who are the others?** Public peer slot directory, purpose, input/output signatures.
3. **How do we act as one?** Routing rules, topology, delegation boundaries, shared memory policy.

## What it extracts

- model fleet slots and role contracts
- fleet topology and peer call graph
- tool IDs and argument schemas
- approval requirements
- permission keys
- `UserIntent` cases
- intent-to-tool routing
- supported JSON value types
- memory scopes
- TTL and freshness classes
- Mimicry style hints
- REM report hints
- forbidden sentinels such as `<private_reasoning>` and `<tool_json>`

## What the dataset compiler adds

The raw role datasets are preserved, then compiled into higher-grade training artifacts:

- `train_sft.jsonl` — canonical chat-message SFT records with stable IDs, role labels, task labels, curriculum tags, risk labels, manifest grounding, and privacy metadata.
- `validation_sft.jsonl` — deterministic validation split.
- `eval_scenarios.jsonl` — manifest adherence tests for routing, tool schemas, sentinel suppression, and hallucinated tool rejection.
- `dpo_preference_pairs.jsonl` — chosen/rejected preference pairs built from negative tool-call samples.
- `tool_schema_cards.jsonl` — exact immutable tool-schema grounding cards.
- `manifest_grounding_cards.jsonl` — fleet, memory, protocol, and sentinel policy cards.
- `runtime_audit_repairs.jsonl` — REM-style repair samples produced from in-app audit failures.
- `dataset_manifest.json` — dataset lineage, counts, hashes, source policy, split policy, and privacy policy.
- `dataset_index.csv` — compact overview of every emitted dataset family.

## Fleet self-knowledge artifacts

When enabled, the crawler also writes:

- `fleet_system_prompts.json` — one deterministic prompt and compact context payload per model slot.
- `AgentBehaviorManifest.md` — compact LLM-readable Markdown manifest for RAG or prompt injection.
- `cross_model_training/cross_model_training.jsonl` — SFT and DPO records for self-knowledge, peer-knowledge, delegation, and private-state boundaries.
- `cross_model_training/cross_model_training_index.csv` — compact count summary by record type, role, and task.

These artifacts are derived from the same manifest and are intended to make the fleet behave like one coherent Lumen agent instead of isolated models.

## Run locally

From the repo root:

```bash
cd tools/lumen_manifest_crawler
python -m venv .venv
source .venv/bin/activate
pip install -e .[dev]
python -m lumen_manifest_crawler generate --root ../.. --output ../../generated/agent_manifest --pretty
```

Or from the repo root after installation:

```bash
python -m lumen_manifest_crawler generate --root . --output generated/agent_manifest --pretty
```

## Run one closed improvement-loop cycle

The `improve-loop` command performs one auditable cycle of the static/runtime/training loop:

1. optionally run a local test command;
2. scan Swift source and regenerate the manifest;
3. ingest one or more in-app dataset package JSON files;
4. compile base datasets, fleet artifacts, and per-agent fine-tuning datasets;
5. optionally run build/training commands;
6. write a loop state file, gap report, Markdown report, and next-action prompts for the next code-change pass.

```bash
python -m lumen_manifest_crawler improve-loop \
  --root . \
  --output generated/agent_manifest \
  --loop-output generated/agent_improvement_loop \
  --runtime-audit runtime-audits/latest-audit.json \
  --generate-system-prompts \
  --generate-agent-fine-tuning
```

The loop writes:

```text
generated/agent_improvement_loop/
├── loop_state.json
├── loop_gaps.json
├── next_action_prompts.jsonl
└── LOOP_REPORT.md
```

Use `next_action_prompts.jsonl` as the work queue for the next source-code improvement pass. Each record contains the gap evidence, severity, target subsystem, and required outcome.

To include commands without executing them:

```bash
python -m lumen_manifest_crawler improve-loop \
  --root . \
  --dry-run-commands \
  --test-command "python -m pytest tools/lumen_manifest_crawler/tests" \
  --build-command "xcodebuild -version" \
  --train-command "python tools/fine_tuning/unsloth/train.py"
```

Run the command repeatedly from CI, a local shell loop, or a Codex pass. Each iteration should either remove a gap or expand coverage with a new runtime trace field, adversarial scenario family, or quality gate.

## Generate fleet self-knowledge artifacts

```bash
python -m lumen_manifest_crawler generate \
  --root . \
  --output generated/agent_manifest \
  --pretty \
  --generate-system-prompts
```

This writes:

```text
generated/agent_manifest/
├── fleet_system_prompts.json
├── AgentBehaviorManifest.md
└── cross_model_training/
    ├── cross_model_training.jsonl
    └── cross_model_training_index.csv
```

To write cross-model training elsewhere:

```bash
python -m lumen_manifest_crawler generate \
  --root . \
  --output generated/agent_manifest \
  --generate-system-prompts \
  --cross-model-train-dir generated/cross_model_training
```

To export only the Markdown manifest plus normal outputs:

```bash
python -m lumen_manifest_crawler generate \
  --root . \
  --output generated/agent_manifest \
  --export-md
```

## Include in-app runtime audit data

Export one or more in-app dataset package JSON files from the iPhone app, then pass each file or a directory containing JSON reports:

```bash
python -m lumen_manifest_crawler generate \
  --root . \
  --output generated/agent_manifest \
  --pretty \
  --runtime-audit ./runtime-audits/latest-audit.json
```

Multiple inputs are allowed:

```bash
python -m lumen_manifest_crawler generate \
  --root . \
  --output generated/agent_manifest \
  --runtime-audit ./runtime-audits/device-a.json \
  --runtime-audit ./runtime-audits/device-b.json \
  --runtime-audit ./runtime-audits/archive/
```

The compiler only ingests explicit audit/package JSON files. It does not scrape free-form user logs, full conversations, private text, photos, contacts, calendar bodies, files, or unrestricted tool payloads.

## Determinism

By default, generated timestamps and splits are deterministic so CI can detect drift cleanly. For local exploratory builds, use:

```bash
python -m lumen_manifest_crawler generate --root . --output generated/agent_manifest --non-deterministic
```

## CI drift prevention

Use `--fail-on-change` to make CI fail when regenerated outputs differ from the current git working tree:

```bash
python -m lumen_manifest_crawler generate \
  --root . \
  --output generated/agent_manifest \
  --pretty \
  --generate-system-prompts \
  --cross-model-train-dir generated/cross_model_training \
  --fail-on-change
```

That forces every tool, intent, model slot, fleet topology, memory policy, or runtime repair change to refresh the self-descriptive fleet artifacts.

## Full output

```text
generated/agent_manifest/
├── AgentBehaviorManifest.json
├── AgentBehaviorManifest.pretty.json
├── AgentBehaviorManifest.sha256
├── AgentBehaviorManifest.md
├── fleet_system_prompts.json
├── manifest_validation_report.json
├── dataset_manifest.json
├── dataset_index.csv
├── routing_matrix.csv
├── tool_registry.csv
├── cross_model_training/
│   ├── cross_model_training.jsonl
│   └── cross_model_training_index.csv
└── dataset/
    ├── cortex_routing.jsonl
    ├── executor_tool_calls.jsonl
    ├── mouth_responses.jsonl
    ├── mimicry_style.jsonl
    ├── rem_reflection.jsonl
    ├── negative_samples.jsonl
    ├── approval_boundary_samples.jsonl
    ├── train_sft.jsonl
    ├── validation_sft.jsonl
    ├── eval_scenarios.jsonl
    ├── dpo_preference_pairs.jsonl
    ├── tool_schema_cards.jsonl
    ├── manifest_grounding_cards.jsonl
    └── runtime_audit_repairs.jsonl
```

## Agent usage

### Cortex

Use:

- `cortex_routing.jsonl`
- `routing_matrix.csv`
- `eval_scenarios.jsonl`
- `fleet_system_prompts.json` entry for the Cortex/router slot
- `cross_model_training.jsonl` records with `taskType=fleet_delegation` and `fleet_peer_knowledge`

Cortex should classify intent, select only allowed manifest tools or slots, and delegate out-of-scope work rather than improvising.

### Tool Executor

Use:

- `executor_tool_calls.jsonl`
- `approval_boundary_samples.jsonl`
- `tool_schema_cards.jsonl`
- `negative_samples.jsonl`
- `dpo_preference_pairs.jsonl`
- its `fleet_system_prompts.json` entry

Tool Executor should emit exact manifest-valid tool JSON, respect required arguments, and stop at approval/permission boundaries.

### Mouth

Use:

- `mouth_responses.jsonl`
- `eval_scenarios.jsonl` sentinel cases
- `manifest_grounding_cards.jsonl`
- its `fleet_system_prompts.json` entry

Mouth should produce only user-facing text and must never expose private reasoning, raw tool JSON, or forbidden sentinels.

### Mimicry

Use:

- `mimicry_style.jsonl`
- `train_sft.jsonl` records with `agentRole=mimicry`
- its `fleet_system_prompts.json` entry

Mimicry should adapt style, language, and formatting without changing facts, tool IDs, safety boundaries, or approval requirements.

### REM

Use:

- `rem_reflection.jsonl`
- `runtime_audit_repairs.jsonl`
- `manifest_grounding_cards.jsonl`
- `dataset_manifest.json`
- its `fleet_system_prompts.json` entry

REM should diagnose drift, produce repair samples, classify memory/freshness decisions, and keep the fleet aligned with the manifest.

## Adding a new tool safely

1. Add the Swift tool definition to `ToolDefinition.swift`.
2. Include a stable tool ID.
3. Include explicit argument names and JSON-compatible types.
4. Set `requiresApproval` correctly.
5. Add `permissionKey` when touching iOS permissions.
6. Run the crawler with `--generate-system-prompts`.
7. Review `tool_registry.csv`, `tool_schema_cards.jsonl`, `fleet_system_prompts.json`, and `AgentBehaviorManifest.md`.
8. Commit generated manifest/dataset/fleet artifact changes.

## Adding a new slot safely

1. Add the slot to the Swift model fleet source.
2. Include role and responsibilities.
3. Run the crawler with `--generate-system-prompts`.
4. Review `AgentBehaviorManifest.json.fleet`, `fleetTopology`, `fleet_system_prompts.json`, and `cross_model_training.jsonl`.
5. Verify delegation examples and private-state-boundary examples were generated.
6. Commit generated artifacts.

## Adding a new intent safely

1. Add the `UserIntent` case.
2. Add deterministic routing to valid tool IDs.
3. Run the crawler with `--generate-system-prompts`.
4. Check `routing_matrix.csv`.
5. Check `eval_scenarios.jsonl`.
6. Check relevant fleet system prompts.
7. Commit the updated manifest/datasets/artifacts.

## iPhone runtime audit vs source crawling

The Python crawler runs on the build/dev machine and reads Swift source.

The iPhone app does not crawl raw Swift source. It loads the bundled manifest and compares it against the live runtime tool registry and deterministic scenarios. This verifies the shipped app still matches the training truth.

When an audit fails, its JSON report can be fed back into the dataset compiler. The compiler converts failures into REM repair records so the model learns how to diagnose drift and request the correct manifest/schema regeneration path.

## Validation behaviour

Hard failures block generation when the manifest would train agents on impossible behaviour. Examples:

- duplicate tool IDs
- intent references unknown tool
- unsupported JSON argument type
- approval-required tool without approval samples
- sentinel leak in user-facing or compiled model-visible dataset text
- executor dataset references unknown tool
- compiled dataset record missing stable ID or canonical chat messages
- malformed DPO preference pair

Warnings flag quality issues that should be cleaned up, such as missing descriptions or ambiguous intent routing.
