# Lumen Manifest Crawler

The Lumen Manifest Crawler is the deterministic bridge between the Swift runtime and the model fine-tuning pipeline.

It extracts the real source-of-truth from the Lumen / monGARS codebase and writes an `AgentBehaviorManifest.json` plus role-specific JSONL datasets for:

- Cortex
- Tool Executor
- Mouth
- Mimicry
- REM

## Why this exists

LLM agents drift when they are trained on stale examples, invented tool names, outdated memory scopes, or synthetic schemas that no longer match the app. This crawler prevents that by deriving the training source from Swift files that actually define the runtime.

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

## Output

```text
generated/agent_manifest/
├── AgentBehaviorManifest.json
├── AgentBehaviorManifest.pretty.json
├── AgentBehaviorManifest.sha256
├── manifest_validation_report.json
├── routing_matrix.csv
├── tool_registry.csv
└── dataset/
    ├── cortex_routing.jsonl
    ├── executor_tool_calls.jsonl
    ├── mouth_responses.jsonl
    ├── mimicry_style.jsonl
    ├── rem_reflection.jsonl
    ├── negative_samples.jsonl
    └── approval_boundary_samples.jsonl
```

## CI drift prevention

The GitHub Action regenerates the manifest and fails if generated files differ from the committed version. This forces every tool, intent, memory, or fleet change to update the model grounding source.

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

## Validation behaviour

Hard failures block generation when the manifest would train agents on impossible behaviour. Examples:

- duplicate tool IDs
- intent references unknown tool
- unsupported JSON argument type
- approval-required tool without approval samples
- sentinel leak in user-facing dataset
- executor dataset references unknown tool

Warnings flag quality issues that should be cleaned up, such as missing descriptions or ambiguous intent routing.
