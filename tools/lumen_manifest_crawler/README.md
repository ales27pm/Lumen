# Lumen Manifest Crawler

The Lumen Manifest Crawler is the deterministic bridge between the Swift runtime and the model fine-tuning pipeline.

It extracts the real source-of-truth from the Lumen / monGARS codebase and writes an `AgentBehaviorManifest.json` plus role-specific and compiled JSONL datasets for:

- Cortex
- Tool Executor
- Mouth
- Mimicry
- REM
- SFT train / validation
- DPO preference pairs
- eval scenarios
- runtime audit repair records

## Why this exists

LLM agents drift when they are trained on stale examples, invented tool names, outdated memory scopes, or synthetic schemas that no longer match the app. This crawler prevents that by deriving the training source from Swift files that actually define the runtime.

The pipeline now combines two truth sources:

1. **Static Swift source analysis** from the repository.
2. **In-app runtime audit JSON** exported from `RuntimeManifestAuditor`, when provided.

That means the dataset can train models not only on what the source says should exist, but also on real shipped-app drift reports such as missing live tools, mismatched arguments, approval-boundary bugs, and permission-state mismatches.

## What it extracts

- model fleet slots and role contracts
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

## Include in-app runtime audit data

Export one or more `RuntimeAgentManifestAuditReport` JSON files from the iPhone app, then pass each file or a directory containing JSON reports:

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

The compiler only ingests explicit audit JSON files. It does not scrape free-form user logs, conversations, private text, photos, contacts, or calendar content.

## Determinism

By default, generated timestamps and splits are deterministic so CI can detect drift cleanly. For local exploratory builds, use:

```bash
python -m lumen_manifest_crawler generate --root . --output generated/agent_manifest --non-deterministic
```

## Output

```text
generated/agent_manifest/
├── AgentBehaviorManifest.json
├── AgentBehaviorManifest.pretty.json
├── AgentBehaviorManifest.sha256
├── manifest_validation_report.json
├── dataset_manifest.json
├── dataset_index.csv
├── routing_matrix.csv
├── tool_registry.csv
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

## CI drift prevention

The GitHub Action regenerates the manifest and fails if generated files differ from the committed version. This forces every tool, intent, memory, fleet, runtime-audit repair, or dataset-schema change to update the model grounding source.

## Adding a new tool safely

1. Add the Swift tool definition to `ToolDefinition.swift`.
2. Include a stable tool ID.
3. Include explicit argument names and JSON-compatible types.
4. Set `requiresApproval` correctly.
5. Add `permissionKey` when touching iOS permissions.
6. Run the crawler.
7. Commit generated manifest/dataset changes.

## Adding a new intent safely

1. Add the `UserIntent` case.
2. Add deterministic routing to valid tool IDs.
3. Run the crawler.
4. Check `routing_matrix.csv`.
5. Commit the updated manifest/datasets.

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
