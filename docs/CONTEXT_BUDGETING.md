# Context Budgeting

`ContextBudgetAllocator` provides deterministic section budgets (char-based):
- system
- short-term history
- memories
- RAG
- tools
- runtime policy

`AssistantKernel.buildGroundingContext` uses Memory + RAG context builders and available secure tool definitions, then records compact counts/char totals in `AssistantGroundingContext`.
