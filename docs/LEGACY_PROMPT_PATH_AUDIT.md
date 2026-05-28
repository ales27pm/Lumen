# Legacy Prompt Path Audit

| Path | Mode | Coordinator | Assembler | Bounded | Secure Executor | Status |
|---|---|---|---|---|---|---|
| `AgentRunner.runHeadless` | headless | yes | yes | yes | yes | fully migrated |
| `AgentService.run` | interactive | partial (no ModelContext-bound coordinator call in-service) | yes | yes | yes | partially migrated |
| `SlotAgentService.run` | slot | partial (no ModelContext-bound coordinator call in-service) | yes | yes | yes | partially migrated |
| `RolePipelineAgentService.run` | role-pipeline | partial (no ModelContext-bound coordinator call in-service) | yes | yes | yes | partially migrated |

## Why partial remains
These services receive prebuilt `AgentRequest` and currently do not own a `ModelContext` at the run boundary. They now enforce a single bounded grounding assembly pass internally, but full in-service coordinator invocation needs model-context plumbing through call sites.
