# Legacy Prompt Path Audit

| File / Function | Mode | Uses Coordinator | Bounded Injection | Secure Tools | Secure Executor | Notes |
|---|---|---:|---:|---:|---:|---|
| `Services/AgentRunner.runHeadless` | headless | yes | yes (`LegacyPromptAssembler`) | yes (bridged) | yes | migrated |
| `Services/AgentService` (main loops) | foreground | partial | partial | partial | yes | request construction still legacy-heavy |
| `Services/SlotAgentService` | slot | partial | partial | partial | yes | migrated execution wrapper, prompt path partial |
| `Services/RolePipelineAgentService` | role pipeline | partial | partial | partial | yes | migrated execution wrapper, prompt path partial |

## Remaining risk
- Full request-construction migration in Agent/Slot/Role services is still partial.
- Some legacy-only tools remain allowlist/wrapper based.
