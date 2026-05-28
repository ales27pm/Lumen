# CODEX Native Assistant Audit (Phase 1)

## Date
- 2026-05-28

## Build System
- Native iOS app at `ios/Lumen.xcodeproj`.
- SwiftUI + SwiftData app lifecycle.
- Unit tests under `ios/LumenTests`.

## Current Startup / Lifecycle
- `LumenApp` uses staged startup through `AppStartupCoordinator` with explicit stages: container, bootstrap, grounding resources, model loader, triggers, REM cycle.
- `LumenAppDelegate` handles MSAL URL callbacks and memory warnings, delegating memory cleanup to `FleetRuntimeCleanup.unloadOptionalChatSlots()`.

## Model Runtime Baseline
- `ModelLoader` already performs assignment-first slot fleet setup and lazy role loading through `SlotModelRuntimeCoordinator`.
- `ModelRuntimeController` supports loaded path refresh, load/unload/reload for chat/embedding models.
- `AppLlamaService` provides llama.cpp / SwiftLlama-backed generation and embeddings with diagnostics.
- `SlotModelRuntimeCoordinator` manages slot assignments (`cortex`, `executor`, `mouth`, `mimicry`, `rem`) and runtime readiness.

## Agent / Trigger Baseline
- Agent services exist: `AgentService`, `RolePipelineAgentService`, `SlotAgentService`, `AgentRunner`.
- Background scheduling exists in `TriggerScheduler` and is registered at launch.

## Memory / RAG Baseline
- Data models and stores exist for memory and RAG (`MemoryStore`, `RAGStore`, `VectorIndex`, `MemoryItem`, `RAGChunk`).

## Tooling / Permissions / Voice Baseline
- Existing tool execution framework exists in `ToolExecutor` + `Services/Tools/*`.
- Permission center exists (`PermissionsCenter`).
- Voice integration exists (`VoiceService`).

## Gaps for Target Architecture
1. No consolidated `AssistantKernel` orchestration boundary yet.
2. No protocol-driven runtime abstraction that isolates FoundationModels/CoreML/llama fallback routing.
3. No unified runtime router policy object for task-scoped runtime decisions.
4. Hardware/power/thermal policy currently spread across services and needs centralization.

## Phase 2 Scope Implemented Next
- Add Assistant runtime protocols.
- Add `AssistantRuntimeRouter` with task policy decisions.
- Add runtime adapters:
  - FoundationModels (availability guarded)
  - CoreML runtime wrapper with typed errors and shape validation
  - Llama runtime adapter over current services
  - Deterministic fallback runtime
- Add tests for runtime router selection policy.

## Phase 3/4 Foundation Update (this change)
- Added system capability snapshot/profiler with public API-only hardware/runtime capability inspection.
- Added thermal, power, and memory pressure monitors plus memory-pressure metrics emission.
- Added JSONL-backed runtime metrics store (`Application Support/Lumen/runtime-metrics.jsonl`).
- Added deterministic background policy and background execution lease actor.
- Added background orchestrator wrapper that preserves existing TriggerScheduler behavior and identifiers.
- Added entitlement validator for BG task IDs and usage description keys with non-fatal warnings.
