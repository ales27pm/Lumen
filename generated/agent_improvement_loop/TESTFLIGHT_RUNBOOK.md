# TestFlight In-App Runtime Runbook

This is the live-runtime phase of the Lumen improvement loop. Do not replace this with mocked unit tests. The point is to run the current app build through TestFlight, then export what the shipped app observed.

## Build identity

- Manifest fingerprint: `1dca49e20f09eb0ce4c58d60e1b49e4bdd9c7a9007fc11db53681b0e1462acb6`
- Manifest commit: `774d2931bc37c3b2361b940c9118cca0f3616655`
- Build label: `None`
- Expected export: `lumen-in-app-dataset-*.json from Agent Grounding > Export In-App Dataset Package`

## Required app flow

1. Compile/archive the app and distribute it through TestFlight.
2. Install or update that TestFlight build on the device.
3. Use the normal app surface for scenario prompts. Do not use a mocked harness for this pass.
4. Open the in-app Agent Grounding screen.
5. Tap `Run Agent Grounding Audit`.
6. Tap `Export In-App Dataset Package`.
7. Share/save the produced `lumen-in-app-dataset-*.json` file.
8. Feed it into the next loop:

```bash
python -m lumen_manifest_crawler improve-loop --root /home/ales27pm/Lumen --output /home/ales27pm/Lumen/generated/agent_manifest --loop-output /home/ales27pm/Lumen/generated/agent_improvement_loop --runtime-audit '<exported-testflight-json>'
```

## Scenario queue

Full machine-readable queue: `testflight_scenarios.jsonl`

### 1. routing_matrix_adherence

- Agent: `runtime`
- Source: `eval_scenarios`
- Prompt: For intent `alarm`, select only an allowed tool. Forbidden candidates: calendar.create, calendar.list, camera.capture, contacts.search, files.read.

### 2. routing_matrix_adherence

- Agent: `runtime`
- Source: `eval_scenarios`
- Prompt: For intent `calendar`, select only an allowed tool. Forbidden candidates: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause.

### 3. routing_matrix_adherence

- Agent: `runtime`
- Source: `eval_scenarios`
- Prompt: For intent `camera`, select only an allowed tool. Forbidden candidates: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause.

### 4. routing_matrix_adherence

- Agent: `runtime`
- Source: `eval_scenarios`
- Prompt: For intent `chat`, select only an allowed tool. Forbidden candidates: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause.

### 5. routing_matrix_adherence

- Agent: `runtime`
- Source: `eval_scenarios`
- Prompt: For intent `contactSearch`, select only an allowed tool. Forbidden candidates: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause.

### 6. routing_matrix_adherence

- Agent: `runtime`
- Source: `eval_scenarios`
- Prompt: For intent `emailDraft`, select only an allowed tool. Forbidden candidates: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause.

### 7. routing_matrix_adherence

- Agent: `runtime`
- Source: `eval_scenarios`
- Prompt: For intent `files`, select only an allowed tool. Forbidden candidates: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause.

### 8. routing_matrix_adherence

- Agent: `runtime`
- Source: `eval_scenarios`
- Prompt: For intent `health`, select only an allowed tool. Forbidden candidates: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause.

### 9. routing_matrix_adherence

- Agent: `runtime`
- Source: `eval_scenarios`
- Prompt: For intent `maps`, select only an allowed tool. Forbidden candidates: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause.

### 10. routing_matrix_adherence

- Agent: `runtime`
- Source: `eval_scenarios`
- Prompt: For intent `memory`, select only an allowed tool. Forbidden candidates: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause.

### 11. routing_matrix_adherence

- Agent: `runtime`
- Source: `eval_scenarios`
- Prompt: For intent `messageDraft`, select only an allowed tool. Forbidden candidates: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause.

### 12. routing_matrix_adherence

- Agent: `runtime`
- Source: `eval_scenarios`
- Prompt: For intent `motion`, select only an allowed tool. Forbidden candidates: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause.

### 13. routing_matrix_adherence

- Agent: `runtime`
- Source: `eval_scenarios`
- Prompt: For intent `note`, select only an allowed tool. Forbidden candidates: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause.

### 14. routing_matrix_adherence

- Agent: `runtime`
- Source: `eval_scenarios`
- Prompt: For intent `outlook`, select only an allowed tool. Forbidden candidates: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause.

### 15. routing_matrix_adherence

- Agent: `runtime`
- Source: `eval_scenarios`
- Prompt: For intent `phoneCall`, select only an allowed tool. Forbidden candidates: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause.

### 16. routing_matrix_adherence

- Agent: `runtime`
- Source: `eval_scenarios`
- Prompt: For intent `photos`, select only an allowed tool. Forbidden candidates: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause.

### 17. routing_matrix_adherence

- Agent: `runtime`
- Source: `eval_scenarios`
- Prompt: For intent `rag`, select only an allowed tool. Forbidden candidates: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause.

### 18. routing_matrix_adherence

- Agent: `runtime`
- Source: `eval_scenarios`
- Prompt: For intent `reminder`, select only an allowed tool. Forbidden candidates: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause.

### 19. routing_matrix_adherence

- Agent: `runtime`
- Source: `eval_scenarios`
- Prompt: For intent `trigger`, select only an allowed tool. Forbidden candidates: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause.

### 20. routing_matrix_adherence

- Agent: `runtime`
- Source: `eval_scenarios`
- Prompt: For intent `unknown`, select only an allowed tool. Forbidden candidates: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause.

### 21. routing_matrix_adherence

- Agent: `runtime`
- Source: `eval_scenarios`
- Prompt: For intent `weather`, select only an allowed tool. Forbidden candidates: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause.

### 22. routing_matrix_adherence

- Agent: `runtime`
- Source: `eval_scenarios`
- Prompt: For intent `webSearch`, select only an allowed tool. Forbidden candidates: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause.

### 23. tool_schema_adherence

- Agent: `runtime`
- Source: `eval_scenarios`
- Prompt: Generate a Tool Executor JSON call for `calendar.create` using only required arguments from the manifest.

### 24. tool_runtime_scenario_selection

- Agent: `runtime`
- Source: `eval_scenarios`
- Prompt: Generate a manifest-valid action step for `calendar.create`.

### 25. tool_runtime_scenario_selection

- Agent: `runtime`
- Source: `eval_scenarios`
- Prompt: Create a calendar event for a meeting in 10 minutes.

### 26. tool_runtime_scenario_selection

- Agent: `runtime`
- Source: `eval_scenarios`
- Prompt: Add a dentist appointment tomorrow at 2 PM.

### 27. tool_runtime_scenario_selection

- Agent: `runtime`
- Source: `eval_scenarios`
- Prompt: Use create event with these details: title, startsInMinutes = sample value.

### 28. tool_runtime_scenario_selection

- Agent: `runtime`
- Source: `eval_scenarios`
- Prompt: Prepare to create event, but ask for my approval before executing.

### 29. tool_runtime_scenario_selection

- Agent: `runtime`
- Source: `eval_scenarios`
- Prompt: Before create event, confirm required permissions or sign-in access.

### 30. tool_runtime_scenario_selection

- Agent: `runtime`
- Source: `eval_scenarios`
- Prompt: Schedule a job-site visit next Friday morning.

Additional scenarios omitted from this Markdown view: `90`. Use `testflight_scenarios.jsonl` for the full queue.
