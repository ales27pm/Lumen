# Runtime Audit and E2E Boundaries

This document prevents the improve-loop from mixing three different evidence layers.

## 1. Agent Grounding runtime audit

Owned by:

```text
ios/Lumen/Services/AgentGrounding/AgentGroundingAuditView.swift
ios/Lumen/Services/AgentGrounding/InAppDatasetPackageExporter.swift
```

Default export filename:

```text
lumen-agent-grounding-audit-*.json
```

Default schema:

```json
{
  "schemaVersion": "1.1.0",
  "exportPolicy": {
    "format": "agent-grounding-runtime-json-package",
    "sourceLayer": "agentGroundingRuntimeAudit",
    "ownsLiveE2EScenarios": false,
    "includesDeterministicStaticScenarios": false
  }
}
```

Agent Grounding is allowed to export:

- runtime manifest audit failures;
- model behaviour audit violations from persisted/recent app messages;
- bounded `AgentBehaviorTraceRecorder` traces;
- trace counters such as `traceSelectedToolAllowedCount` and `traceParseErrorCount`.

Agent Grounding must not be treated as the owner of live E2E scenario results.

Static manifest scenario checks may be displayed in the UI, but they are omitted from the dataset export by default. If included explicitly, they must remain marked as deterministic static checks and not as proof of model execution.

## 2. E2E live model execution

Owned by:

```text
ios/Lumen/Services/E2ETestRunner.swift
ios/Lumen/Views/SettingsView.swift
```

E2E scenarios are the only layer that should claim a real model scenario passed or failed.

A scenario marked `requiresAgentRun=true` must execute the actual loaded chat model path through `SlotAgentService`. If the report contains text such as:

```text
No model loaded; routing-only checks completed.
```

then the improve-loop ingester treats that scenario as invalid E2E evidence and converts it into a repair/gap signal.

## 3. Deterministic static scenario checks

Owned by:

```text
ios/Lumen/Services/AgentGrounding/RuntimeScenarioRunner.swift
```

`RuntimeScenarioRunner.validateStaticScenarios(...)` does not run models. It only verifies deterministic manifest consistency, such as:

- expected tool exists in the bundled manifest;
- generated prompts do not contain forbidden sentinels.

These checks are useful for UI diagnostics and manifest sanity, but they must not be mixed into E2E training records as live model failures.

## Python ingestion rules

Owned by:

```text
tools/lumen_manifest_crawler/lumen_manifest_crawler/dataset/runtime_ingest.py
tools/lumen_manifest_crawler/lumen_manifest_crawler/dataset/e2e_report_normalizer.py
```

Rules:

1. `agent-grounding-runtime-json-package` is flattened as `lumen_in_app_dataset_package` with `_sourceLayer=agentGroundingRuntimeAudit`.
2. Agent Grounding `scenarioResults` are ignored unless `exportPolicy.ownsLiveE2EScenarios=true`.
3. Ignored Agent Grounding scenario results are counted as `ignoredScenarioResultCount`.
4. E2E-owned scenario results may be ingested only when the package explicitly says `ownsLiveE2EScenarios=true`.
5. E2E reports that claim success while saying `No model loaded` or `routing-only checks completed` are forced into the failure path.
6. Empty Agent Grounding trace exports emit `agent_grounding_no_recent_model_traces` so the loop cannot silently accept a package that did not capture live model/tool traces.

## Required next hardening

The remaining critical implementation target is to ensure `AgentBehaviorTraceRecorder.record(...)` is wired into the live `SlotAgentService` model path for:

- structured Cortex turns;
- parse errors;
- selected actions;
- blocked tool attempts;
- final Mouth turns;
- direct chat turns.

Until that is fully wired, the loop may correctly flag:

```text
agent_grounding_no_recent_model_traces
```

That gap is intentional. It prevents a visually successful export from being mistaken for complete runtime evidence.
