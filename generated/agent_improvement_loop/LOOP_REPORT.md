# Lumen Agent Improvement Loop Report

- Passed: `False`
- Tools: `53`
- Intents: `22`
- Model slots: `6`
- Dataset records: `4682`
- Runtime audit reports: `1`
- Runtime failures: `33`
- TestFlight status: `runtime-audit-ingested`
- TestFlight scenarios: `120`
- Gaps: `33`
- Next action prompts: `33`

## TestFlight handoff

Run `TESTFLIGHT_RUNBOOK.md` in the real TestFlight app, export the Runtime Audit Package JSON and/or Live E2E Report JSON, then rerun this command with `--runtime-audit <exported-json>`.

## Top gaps

### ERROR — approval_sensitive_tool_selected

- Category: `runtime_drift`
- Recommendation: Add approval-boundary SFT/DPO records and verify the UI confirmation path.

### ERROR — approval_sensitive_tool_selected

- Category: `runtime_drift`
- Recommendation: Add approval-boundary SFT/DPO records and verify the UI confirmation path.

### ERROR — approval_sensitive_tool_selected

- Category: `runtime_drift`
- Recommendation: Add approval-boundary SFT/DPO records and verify the UI confirmation path.

### ERROR — trace_parse_error

- Category: `runtime_drift`
- Recommendation: Convert this failure into a REM repair sample and add a regression eval.

### ERROR — trace_parse_error

- Category: `runtime_drift`
- Recommendation: Convert this failure into a REM repair sample and add a regression eval.

### ERROR — trace_parse_error

- Category: `runtime_drift`
- Recommendation: Convert this failure into a REM repair sample and add a regression eval.

### ERROR — trace_parse_error

- Category: `runtime_drift`
- Recommendation: Convert this failure into a REM repair sample and add a regression eval.

### ERROR — trace_parse_error

- Category: `runtime_drift`
- Recommendation: Convert this failure into a REM repair sample and add a regression eval.

### ERROR — trace_parse_error

- Category: `runtime_drift`
- Recommendation: Convert this failure into a REM repair sample and add a regression eval.

### ERROR — trace_parse_error

- Category: `runtime_drift`
- Recommendation: Convert this failure into a REM repair sample and add a regression eval.

### ERROR — trace_parse_error

- Category: `runtime_drift`
- Recommendation: Convert this failure into a REM repair sample and add a regression eval.

### ERROR — trace_parse_error

- Category: `runtime_drift`
- Recommendation: Convert this failure into a REM repair sample and add a regression eval.

### ERROR — trace_parse_error

- Category: `runtime_drift`
- Recommendation: Convert this failure into a REM repair sample and add a regression eval.

### ERROR — trace_parse_error

- Category: `runtime_drift`
- Recommendation: Convert this failure into a REM repair sample and add a regression eval.

### ERROR — trace_parse_error

- Category: `runtime_drift`
- Recommendation: Convert this failure into a REM repair sample and add a regression eval.

### ERROR — trace_parse_error

- Category: `runtime_drift`
- Recommendation: Convert this failure into a REM repair sample and add a regression eval.

### ERROR — trace_parse_error

- Category: `runtime_drift`
- Recommendation: Convert this failure into a REM repair sample and add a regression eval.

### ERROR — trace_parse_error

- Category: `runtime_drift`
- Recommendation: Convert this failure into a REM repair sample and add a regression eval.

### ERROR — trace_parse_error

- Category: `runtime_drift`
- Recommendation: Convert this failure into a REM repair sample and add a regression eval.

### ERROR — trace_parse_error

- Category: `runtime_drift`
- Recommendation: Convert this failure into a REM repair sample and add a regression eval.

### ERROR — trace_parse_error

- Category: `runtime_drift`
- Recommendation: Convert this failure into a REM repair sample and add a regression eval.

### ERROR — trace_parse_error

- Category: `runtime_drift`
- Recommendation: Convert this failure into a REM repair sample and add a regression eval.

### ERROR — trace_parse_error

- Category: `runtime_drift`
- Recommendation: Convert this failure into a REM repair sample and add a regression eval.

### ERROR — trace_parse_error

- Category: `runtime_drift`
- Recommendation: Convert this failure into a REM repair sample and add a regression eval.

### ERROR — trace_tool_without_allowed_set

- Category: `runtime_drift`
- Recommendation: Convert this failure into a REM repair sample and add a regression eval.

### ERROR — trace_tool_without_allowed_set

- Category: `runtime_drift`
- Recommendation: Convert this failure into a REM repair sample and add a regression eval.

### ERROR — trace_tool_without_allowed_set

- Category: `runtime_drift`
- Recommendation: Convert this failure into a REM repair sample and add a regression eval.

### ERROR — trace_tool_without_allowed_set

- Category: `runtime_drift`
- Recommendation: Convert this failure into a REM repair sample and add a regression eval.

### ERROR — trace_tool_without_allowed_set

- Category: `runtime_drift`
- Recommendation: Convert this failure into a REM repair sample and add a regression eval.

### ERROR — trace_tool_without_allowed_set

- Category: `runtime_drift`
- Recommendation: Convert this failure into a REM repair sample and add a regression eval.
