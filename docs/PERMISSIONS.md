# Permissions

Phase 5 introduces a centralized `PermissionRegistry` with explicit status and request APIs by domain.

- Permissions are never requested at startup.
- Background/headless flows are blocked from prompt-requiring permission escalation.
- `networkAccess` is an app-controlled setting (disabled by default), not an iOS runtime permission.
