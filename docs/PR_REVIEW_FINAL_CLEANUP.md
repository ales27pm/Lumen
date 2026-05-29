# PR #232 Final Review Cleanup

## Current state
- Starting HEAD before this cleanup: `4a8df6838aa78b0d2519f71c05c0061e8ed1220d`.
- Live GitHub review threads were not accessible in this runner because the GitHub CLI is unavailable; this pass used the remaining unresolved-comment checklist plus current source inspection.

## Checked unresolved comments

| Area | Action taken | Validation |
| --- | --- | --- |
| Audit docs still listed delivered runtime work as gaps. | Updated `CODEX_NATIVE_ASSISTANT_AUDIT.md` to separate delivered scope from remaining integration risk and to describe AssistantKernel as staged/available rather than fully wired. | Static doc review |
| ModelContext actor isolation and Sendable misuse. | Made the staged AssistantKernel `@MainActor` for ModelContext grounding/tool methods and removed `Sendable` from `LegacyAgentRunOptions`. | `rg -n "struct LegacyAgentRunOptions.*Sendable|struct ToolExecutionContext.*Sendable|ModelContext.*Sendable|@unchecked Sendable" ios/Lumen || true` |
| BackgroundOrchestrator / MemoryPressureMonitor dead-code concerns. | Verified `MemoryPressureMonitor.shared` is used by metrics paths. Left `BackgroundOrchestrator` staged and documented rather than adding duplicate launch registration without Xcode validation. | `rg -n "BackgroundOrchestrator|MemoryPressureMonitor\.shared" ios/Lumen docs` |
| Contacts provider errors were conflated with invalid arguments. | Split parse/validation failures from provider/runtime failures and added focused tests. | Contacts tests pending Xcode; static inspection |
| RAGIndexer fresh semantic index append. | Appends non-empty embeddings to `RAGVectorIndex` after `context.save()` so loaded indexes see new chunks immediately; unloaded indexes still load from SwiftData on first search. | Static inspection |
| Legacy grounding duplicate/role/idempotency/estimated-char comments. | Routed AgentRunner through `LegacyTurnGroundingCoordinator`, used role metadata in coordinator/assembler, fixed single-header ambiguity, strips earliest generated header, and replaced escaped interpolation/zero estimates in legacy service assembly helpers. | Static grep commands listed below |
| Brittle source-reading tests and weak policy tests. | Replaced source-reading tests with behavior checks, strengthened contacts/RAG/legacy options/tool diagnostics/add-memory policy tests. | Tests pending Xcode |
| Readiness script `rg` under `set -e`. | AppIntents and Info.plist scans now warn instead of terminating unexpectedly on no-match. | `./scripts/check-ios-build-readiness.sh` |

## Skipped / already resolved
- Manual PBX source membership changes remain skipped because the project uses `PBXFileSystemSynchronizedRootGroup`.
- Live review-thread reconciliation remains skipped because review APIs/CLI are unavailable in this environment.
- Full macOS/Xcode build and AppIntents/SwiftData concurrency validation remain unverified here because `xcodebuild` is unavailable.

## Validation run
- `command -v xcodebuild || true`
- `xcodebuild -version || true`
- `./scripts/check-ios-build-readiness.sh`
- repository marker scan command from the PR prompt
- `rg -n "try\\?|String\\(describing: error\\)|return \\[\\]|request.prompt|hashValue|createFile" ios/Lumen || true`
- `rg -n "\\\\\\\\\\(\\$0\\.(content|id|description)\\)" ios/Lumen/Services || true`
- `rg -n "struct LegacyAgentRunOptions.*Sendable|struct ToolExecutionContext.*Sendable|ModelContext.*Sendable|@unchecked Sendable" ios/Lumen || true`
- `git diff --check`
