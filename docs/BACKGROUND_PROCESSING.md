# Background Processing

Lumen retains existing `TriggerScheduler` identifiers:
- `com.27pm.lumen.agent.refresh`
- `com.27pm.lumen.agent.process`

`BackgroundOrchestrator` is additive and wraps scheduling/handling:
- `register()` and `schedule()` delegate to `TriggerScheduler`.
- `runTriggerScan()` delegates to `TriggerScheduler.fireDueTriggers`.
- Non-existent workloads (memory consolidation/RAG maintenance/model housekeeping) record explicit `not_available` metrics instead of fake success.

`BackgroundExecutionLease` prevents concurrent workloads by category and auto-expires stale leases.
