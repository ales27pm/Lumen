# ModelContext Injection Audit

## Interactive generation call sites

| File / function | Has `@Environment(\.modelContext)` | Explicitly passed to service | SharedContainer fallback used | Degraded fallback possible | Status |
|---|---:|---:|---:|---:|---|
| `ChatView.runAgent(...)` | yes | yes (`LegacyAgentRunOptions.modelContext`) | yes (provider fallback if nil) | yes | migrated |
| `VoiceModeView.runAgent(...)` | yes | yes (`LegacyAgentRunOptions.modelContext`) | yes | yes | migrated |
| `TriggersView.runNow(...)` manual trigger | yes | yes (direct `context:` to scheduler/runner path) | n/a | no (context is explicit) | migrated |
| `AgentRunner.runHeadless(...)` | caller-provided | yes (`context` param) | no | no | migrated |
| `RootView` direct generation launch | n/a | n/a | n/a | n/a | no direct launch path |

## Notes
- Interactive legacy services retain safe degraded behavior when model context cannot be resolved.
- Primary path now prefers direct context from UI where available.
