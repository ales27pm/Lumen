# Tool Security Model

Implemented secure tools:
- device.status
- memory.search
- rag.search.secure
- calendar.read
- contacts.lookup
- location.snapshot
- notify.local
- open.url

Rules enforced:
- Deterministic `ToolApprovalPolicy` decides allow/deny/requiresApproval.
- Permission-read tools gate through `PermissionRegistry` + `PermissionGate`.
- Sensitive/user-visible actions return `requiresApproval` for model-proposed invocations.
- Background tool visibility is restricted to read-only safe tools (device.status, memory.search, rag.search.secure with lightweight limits).
- Output is bounded by `SafeToolOutputLimiter`.
- Tool metrics are recorded to `RuntimeMetricsStore` without raw payload logging.

Legacy bridge:
- Legacy `Services/ToolExecutor.swift` remains active for existing agent pipelines.
- New `ToolRegistry` is integrated through `AssistantKernel.executeTool(...)` as the migration path.
- No silent schema divergence: mapping remains explicit by tool IDs while migration proceeds.

Deferred tools:
- camera/microphone capture and file-import tools are intentionally deferred until explicit foreground user flows + approval UI integration are completed.
