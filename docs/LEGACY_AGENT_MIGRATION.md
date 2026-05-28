# Legacy Agent Migration

Phase 7 introduces `LegacyGroundingBridge` for legacy agent/headless paths.

## Now using bridge
- `AgentRunner` headless path builds bounded grounding sections and secure-tool availability before constructing `AgentRequest`.

## Still legacy
- `AgentService`, `SlotAgentService`, and `RolePipelineAgentService` still execute through legacy planning/execution loops and legacy `ToolExecutor`.
- Migration is additive; behavior is preserved.

## Tool schema bridge
- `LegacyToolSchemaBridge` maps secure tool definitions into legacy `ToolDefinition` shape.
- New secure tools remain available via `AssistantKernel.executeTool(...)` and are surfaced to headless through mapped definitions.

## Risks remaining
- Some legacy-only tools continue to bypass new approval policy unless routed through secure invocation path.
- Full per-stage grounding reuse in role pipeline is pending deeper integration.
