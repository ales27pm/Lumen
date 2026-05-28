# Tool Security Model

New local tool framework enforces:
- typed tool definitions and invocation sources,
- deterministic approval policy,
- permission checks before execution,
- bounded tool output via `SafeToolOutputLimiter`,
- tool execution metrics via `RuntimeMetricsStore` without raw private payload logging.

Sensitive actions return `requiresApproval` unless user-initiated.
Background invocations deny sensitive/destructive actions by default.
