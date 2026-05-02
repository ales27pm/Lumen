from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

SUPPORTED_TEXT_REPORT_SUFFIXES = {".txt", ".md", ".markdown", ".log"}
REPORT_FIELD_HEADERS = {"Prompt", "Intent", "Failures", "Final"}


def load_runtime_audit_reports(paths: list[Path] | None) -> list[dict[str, Any]]:
    reports: list[dict[str, Any]] = []
    for path in paths or []:
        candidates = _candidate_report_files(path)
        for candidate in candidates:
            try:
                text = candidate.read_text(encoding="utf-8")
            except OSError:
                continue
            reports.extend(_load_report_text(text, source=str(candidate)))
    return reports


def _candidate_report_files(path: Path) -> list[Path]:
    if path.is_dir():
        return sorted(
            candidate
            for candidate in path.rglob("*")
            if candidate.is_file() and (candidate.suffix.casefold() == ".json" or candidate.suffix.casefold() in SUPPORTED_TEXT_REPORT_SUFFIXES)
        )
    return [path]


def _load_report_text(text: str, *, source: str) -> list[dict[str, Any]]:
    try:
        value = json.loads(text)
    except json.JSONDecodeError:
        parsed = _parse_e2e_text_report(text, source=source)
        return [parsed] if parsed is not None else []
    return _normalize_payload(value, source=source)


def _normalize_payload(value: Any, *, source: str) -> list[dict[str, Any]]:
    if isinstance(value, list):
        out: list[dict[str, Any]] = []
        for index, item in enumerate(value):
            out.extend(_normalize_payload(item, source=f"{source}#{index}"))
        return out
    if not isinstance(value, dict):
        return []
    if _is_in_app_package(value):
        return [_flatten_in_app_package(value, source=source)]
    if _is_e2e_json_report(value):
        return [_flatten_e2e_json_report(value, source=source)]
    if isinstance(value.get("failures"), list):
        return [{**value, "_source": source, "_sourceFormat": "runtime_manifest_audit"}]
    if isinstance(value.get("violations"), list) or isinstance(value.get("repairSamples"), list):
        return [_flatten_behavior_audit(value, source=source)]
    return []


def _is_in_app_package(value: dict[str, Any]) -> bool:
    return (
        value.get("schemaVersion") == "1.0.0"
        and "exportPolicy" in value
        and any(key in value for key in ("runtimeManifestAudit", "behaviorAudit", "scenarioResults", "recentTraces"))
    )


def _is_e2e_json_report(value: dict[str, Any]) -> bool:
    return (
        value.get("kind") in {"lumen_e2e_test_report", "e2e_test_report"}
        or isinstance(value.get("trainingSignals"), list)
        or isinstance(value.get("scenarios"), list) and {"passed", "failed"}.intersection(value.keys())
    )


def _flatten_in_app_package(package: dict[str, Any], *, source: str) -> dict[str, Any]:
    failures: list[dict[str, Any]] = []
    runtime_audit = package.get("runtimeManifestAudit")
    if isinstance(runtime_audit, dict):
        for failure in runtime_audit.get("failures", []) or []:
            if isinstance(failure, dict):
                failures.append({**failure, "sourceLayer": "runtimeManifestAudit"})

    behavior_audit = package.get("behaviorAudit")
    if isinstance(behavior_audit, dict):
        failures.extend(_behavior_failures(behavior_audit))

    for scenario_result in package.get("scenarioResults", []) or []:
        if not isinstance(scenario_result, dict):
            continue
        for failure in scenario_result.get("failures", []) or []:
            if isinstance(failure, dict):
                failures.append({**failure, "sourceLayer": "runtimeScenarioRunner"})

    for trace in package.get("recentTraces", []) or []:
        if not isinstance(trace, dict):
            continue
        parse_error = trace.get("parseError")
        selected_tool_id = trace.get("selectedToolID")
        allowed_tool_ids = trace.get("allowedToolIDs") if isinstance(trace.get("allowedToolIDs"), list) else []
        if parse_error:
            failures.append({
                "type": "trace_parse_error",
                "agent": trace.get("slot") or trace.get("stage") or "unknown",
                "expected": ["strict manifest-valid structured output"],
                "actual": str(parse_error),
                "scenario": trace.get("promptPrefix"),
                "problem": "A recorded in-app model trace contained a parse error.",
                "sourceLayer": "agentBehaviorTraceRecorder",
            })
        if selected_tool_id and not allowed_tool_ids:
            failures.append({
                "type": "trace_tool_without_allowed_set",
                "agent": trace.get("slot") or "cortex",
                "expected": ["non-empty allowedToolIDs for tool-selection traces"],
                "actual": selected_tool_id,
                "scenario": trace.get("promptPrefix"),
                "problem": "A recorded in-app trace selected a tool while the trace carried no allowed tool set for validation.",
                "sourceLayer": "agentBehaviorTraceRecorder",
            })
        elif selected_tool_id and selected_tool_id not in allowed_tool_ids:
            failures.append({
                "type": "trace_tool_outside_allowed_set",
                "agent": trace.get("slot") or "cortex",
                "expected": allowed_tool_ids,
                "actual": selected_tool_id,
                "scenario": trace.get("promptPrefix"),
                "problem": "A recorded in-app trace selected a tool outside its allowed tool set.",
                "sourceLayer": "agentBehaviorTraceRecorder",
            })

    return {
        "_source": source,
        "_sourceFormat": "lumen_in_app_dataset_package",
        "generatedAt": package.get("generatedAt"),
        "manifestSource": package.get("manifestSource"),
        "usedRuntimeFallback": package.get("usedRuntimeFallback"),
        "exportPolicy": package.get("exportPolicy"),
        "failures": failures,
    }


def _flatten_behavior_audit(value: dict[str, Any], *, source: str) -> dict[str, Any]:
    return {
        "_source": source,
        "_sourceFormat": "agent_behavior_audit",
        "generatedAt": value.get("generatedAt"),
        "failures": _behavior_failures(value),
    }


def _behavior_failures(behavior_audit: dict[str, Any]) -> list[dict[str, Any]]:
    failures: list[dict[str, Any]] = []
    repair_samples = behavior_audit.get("repairSamples")
    if isinstance(repair_samples, list):
        for sample in repair_samples:
            if not isinstance(sample, dict):
                continue
            failures.append({
                "type": sample.get("violationCode") or "behavior_repair_sample",
                "agent": sample.get("agent"),
                "expected": [str(sample.get("correctedOutput") or sample.get("expected") or "")],
                "actual": sample.get("badOutput"),
                "scenario": sample.get("promptPrefix"),
                "problem": sample.get("lesson") or "In-app model behavior audit generated a repair sample.",
                "repairSample": sample,
                "sourceLayer": "agentModelBehaviorAuditor.repairSamples",
            })
        return failures

    for violation in behavior_audit.get("violations", []) or []:
        if not isinstance(violation, dict):
            continue
        failures.append({
            "type": violation.get("code") or "behavior_violation",
            "agent": violation.get("agent"),
            "expected": [str(violation.get("expected") or "")],
            "actual": violation.get("actual"),
            "scenario": violation.get("promptPrefix"),
            "problem": violation.get("problem") or "In-app model behavior violated manifest constraints.",
            "sourceLayer": "agentModelBehaviorAuditor.violations",
        })
    return failures


def _flatten_e2e_json_report(value: dict[str, Any], *, source: str) -> dict[str, Any]:
    scenarios = value.get("scenarios") if isinstance(value.get("scenarios"), list) else []
    failures: list[dict[str, Any]] = []
    for scenario in scenarios:
        if not isinstance(scenario, dict) or scenario.get("passed") is True:
            continue
        failures.append(_e2e_failure_from_scenario(scenario, source_layer="e2eTestReport.json"))
    return {
        "_source": source,
        "_sourceFormat": "lumen_e2e_test_report",
        "passed": value.get("passed"),
        "failed": value.get("failed"),
        "trainingSignals": value.get("trainingSignals") or value.get("training_signals") or [],
        "failures": failures,
    }


def _parse_e2e_text_report(text: str, *, source: str) -> dict[str, Any] | None:
    normalized = text.replace("\r\n", "\n")
    if "E2E Test Report" not in normalized and "Training eval:" not in normalized:
        return None

    passed = _extract_int(normalized, r"^Passed:\s*(\d+)", default=None)
    failed = _extract_int(normalized, r"^Failed:\s*(\d+)", default=None)
    training_signals = _extract_training_signals(normalized)
    scenarios = _extract_e2e_scenarios(normalized)
    failures = [
        _e2e_failure_from_scenario(scenario, source_layer="e2eTextReport")
        for scenario in scenarios
        if not scenario.get("passed")
    ]
    return {
        "_source": source,
        "_sourceFormat": "lumen_e2e_text_report",
        "passed": passed,
        "failed": failed,
        "trainingSignals": training_signals,
        "scenarioCount": len(scenarios),
        "failures": failures,
        "scenarios": scenarios,
    }


def _extract_e2e_scenarios(text: str) -> list[dict[str, Any]]:
    pattern = re.compile(r"(?m)^([✅❌])\s+Training eval:\s*(.+)$")
    matches = list(pattern.finditer(text))
    scenarios: list[dict[str, Any]] = []
    for index, match in enumerate(matches):
        start = match.end()
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        body = text[start:end].strip()
        scenarios.append(_parse_scenario_block(match.group(1), match.group(2).strip(), body))
    return scenarios


def _parse_scenario_block(status: str, name: str, body: str) -> dict[str, Any]:
    prompt = _extract_field(body, "Prompt")
    intent_line = _extract_field(body, "Intent")
    failures_line = _extract_field(body, "Failures")
    final = _extract_multiline_field(body, "Final")
    intent, expected_intent = _parse_intent_line(intent_line)
    return {
        "name": name,
        "passed": status == "✅",
        "prompt": prompt,
        "intent": intent,
        "expectedIntent": expected_intent,
        "failures": failures_line,
        "final": final,
    }


def _e2e_failure_from_scenario(scenario: dict[str, Any], *, source_layer: str) -> dict[str, Any]:
    failure_text = str(scenario.get("failures") or "E2E scenario failed.").strip()
    prompt = str(scenario.get("prompt") or "").strip()
    final = str(scenario.get("final") or "").strip()
    intent = str(scenario.get("intent") or "unknown").strip() or "unknown"
    required_hint = _extract_required_hint(failure_text)
    expected = _expected_for_e2e_failure(scenario, required_hint)
    corrected = _corrected_output_for_e2e_failure(scenario, required_hint)
    return {
        "type": _e2e_failure_type(scenario, required_hint),
        "agent": _agent_for_e2e_intent(intent),
        "expected": [expected],
        "actual": final,
        "scenario": prompt,
        "problem": failure_text,
        "sourceLayer": source_layer,
        "e2eScenario": {
            "name": scenario.get("name"),
            "intent": intent,
            "expectedIntent": scenario.get("expectedIntent"),
            "prompt": prompt,
            "final": final,
            "requiredHint": required_hint,
        },
        "repairSample": {
            "agent": _agent_for_e2e_intent(intent),
            "violationCode": _e2e_failure_type(scenario, required_hint),
            "promptPrefix": prompt[:500],
            "expected": expected,
            "badOutput": final[:1000],
            "correctedOutput": corrected,
            "lesson": _lesson_for_e2e_failure(scenario, required_hint),
            "curriculum": _curriculum_for_e2e_intent(intent),
        },
    }


def _expected_for_e2e_failure(scenario: dict[str, Any], required_hint: str | None) -> str:
    if required_hint:
        return f"Final answer must include the required hint `{required_hint}` while preserving the requested intent and user-visible usefulness."
    expected_intent = scenario.get("expectedIntent") or scenario.get("intent") or "expected intent"
    return f"Final answer must satisfy the `{expected_intent}` eval contract without violating tool boundaries."


def _corrected_output_for_e2e_failure(scenario: dict[str, Any], required_hint: str | None) -> str:
    prompt = str(scenario.get("prompt") or "").strip()
    final = str(scenario.get("final") or "").strip()
    intent = str(scenario.get("intent") or "unknown").strip()
    if required_hint and intent == "memory":
        remembered = _derive_memory_content_from_prompt(prompt)
        base = final if _is_useful_final(final, intent=intent) else f"Remembered: {remembered}."
        return _ensure_required_hint(base, required_hint)
    if required_hint and intent in {"emailDraft", "email", "mailDraft"}:
        draft = _derive_email_draft_from_prompt(prompt, final)
        return _ensure_required_hint(draft, required_hint)
    if required_hint:
        base = final if _is_useful_final(final, intent=intent) else _generic_corrected_output_from_prompt(prompt, intent)
        return _ensure_required_hint(base, required_hint)
    return final or f"Ask a clarification or produce a manifest-compliant final answer for: {prompt}"


def _derive_memory_content_from_prompt(prompt: str) -> str:
    clean = _clean_prompt(prompt)
    patterns = [
        r"\bremember\s+that\s+(.+?)(?:,?\s+then\b|\s+and\s+(?:tell|confirm|say)\b|[.!?]?$)",
        r"\bremember\s+(.+?)(?:,?\s+then\b|\s+and\s+(?:tell|confirm|say)\b|[.!?]?$)",
        r"\bkeep\s+this\s+in\s+mind\s*:?\s*(.+?)(?:,?\s+then\b|[.!?]?$)",
        r"\bsave\s+(?:this|that)?\s*(?:as\s+)?(?:a\s+)?(?:preference|memory|note)?\s*:?\s*(.+?)(?:,?\s+then\b|[.!?]?$)",
    ]
    for pattern in patterns:
        match = re.search(pattern, clean, flags=re.IGNORECASE)
        if match:
            candidate = _clean_derived_fragment(match.group(1))
            if candidate:
                return candidate
    return clean or "the requested memory"


def _derive_email_draft_from_prompt(prompt: str, final: str) -> str:
    if _looks_like_email_draft(final):
        return final.strip()
    clean = _clean_prompt(prompt)
    recipient = _extract_recipient(clean)
    subject_hint = _extract_subject_hint(clean)
    question = _derive_clarifying_question(clean)
    greeting = f"Hi {recipient}," if recipient else "Hi,"
    subject = f"Subject: {subject_hint}" if subject_hint else "Subject: Professional update"
    body = _derive_email_body_sentence(clean)
    return "\n".join([
        subject,
        "",
        greeting,
        "",
        body,
        "",
        question,
    ]).strip()


def _derive_email_body_sentence(prompt: str) -> str:
    lower = prompt.casefold()
    if "professional update" in lower:
        return "Here is a professional update on the current work: progress is moving forward, and I will share the next concrete milestone once the remaining details are confirmed."
    if "update" in lower:
        return "Here is the requested update: progress is moving forward, and I will confirm the next concrete details as soon as they are available."
    if "draft" in lower or "email" in lower:
        return "I wanted to send a clear professional note and confirm the next detail before moving forward."
    return f"I am following up about: {prompt}"


def _derive_clarifying_question(prompt: str) -> str:
    if re.search(r"\b(one|1)\s+clarifying\s+question\b", prompt, flags=re.IGNORECASE):
        return "One clarifying question: what specific deadline, priority, or next step should I align this update with?"
    if re.search(r"\bask\b.*\bquestion\b", prompt, flags=re.IGNORECASE):
        return "Question: what specific detail should I confirm before sending this?"
    return "Question: what detail should I confirm before sending this?"


def _extract_recipient(prompt: str) -> str | None:
    match = re.search(r"\b(?:to|for)\s+([A-Z][A-Za-z0-9_.-]*)\b", prompt)
    if match:
        return match.group(1).strip()
    return None


def _extract_subject_hint(prompt: str) -> str | None:
    match = re.search(r"\babout\s+(.+?)(?:\s+and\s+ask\b|\s+with\b|[.!?]?$)", prompt, flags=re.IGNORECASE)
    if not match:
        return None
    candidate = _clean_derived_fragment(match.group(1))
    if not candidate:
        return None
    return candidate[:1].upper() + candidate[1:]


def _looks_like_email_draft(value: str) -> bool:
    text = value.strip()
    if not text:
        return False
    lowered = text.casefold()
    has_greeting = bool(re.search(r"(?m)^\s*(hi|hello|dear)\b", lowered))
    has_subject = bool(re.search(r"(?m)^\s*subject\s*:", lowered))
    has_question = "?" in text or "question" in lowered
    return (has_greeting or has_subject) and has_question


def _generic_corrected_output_from_prompt(prompt: str, intent: str) -> str:
    clean = _clean_prompt(prompt)
    if clean:
        return f"I handled this `{intent}` request in a manifest-compliant way: {clean}"
    return f"I handled this `{intent}` request in a manifest-compliant way."


def _ensure_required_hint(text: str, required_hint: str | None) -> str:
    cleaned = text.strip()
    if not required_hint:
        return cleaned
    if required_hint.casefold() in cleaned.casefold():
        return cleaned
    if required_hint.casefold() == "question":
        return f"{cleaned}\n\nQuestion: what detail should I confirm before proceeding?"
    return f"{cleaned}\n\n{required_hint}"


def _is_useful_final(final: str, *, intent: str) -> bool:
    stripped = final.strip()
    if not stripped:
        return False
    if stripped.casefold() == intent.casefold():
        return False
    return len(stripped.split()) >= 3


def _clean_prompt(prompt: str) -> str:
    return " ".join(str(prompt or "").strip().split())


def _clean_derived_fragment(value: str) -> str:
    cleaned = _clean_prompt(value).strip(" ,.;:!?\"'")
    cleaned = re.sub(r"\bthen\s+(?:tell|confirm|say)\b.*$", "", cleaned, flags=re.IGNORECASE).strip(" ,.;:!?\"'")
    return cleaned


def _lesson_for_e2e_failure(scenario: dict[str, Any], required_hint: str | None) -> str:
    intent = str(scenario.get("intent") or "unknown")
    if required_hint:
        return f"For `{intent}` E2E evals, the final answer must include required hint `{required_hint}` while remaining natural and useful."
    return f"Use failed `{intent}` E2E prompts and final outputs as next-cycle fine-tuning repair examples."


def _curriculum_for_e2e_intent(intent: str) -> str:
    if intent in {"memory", "rag"}:
        return "grounded_response_quality"
    if intent in {"emailDraft", "trigger", "tool", "webSearch"}:
        return "tool_boundary_response_quality"
    return "response_quality"


def _agent_for_e2e_intent(intent: str) -> str:
    if intent in {"emailDraft", "chat", "memory", "rag", "webSearch", "weather", "trigger"}:
        return "mouth"
    return "cortex"


def _e2e_failure_type(scenario: dict[str, Any], required_hint: str | None) -> str:
    if required_hint:
        safe_hint = re.sub(r"[^a-z0-9_]+", "_", required_hint.casefold()).strip("_") or "required_hint"
        return f"e2e_missing_required_final_hint_{safe_hint}"
    intent = str(scenario.get("intent") or "unknown").casefold()
    return f"e2e_response_quality_{re.sub(r'[^a-z0-9_]+', '_', intent).strip('_') or 'unknown'}"


def _extract_required_hint(text: str) -> str | None:
    match = re.search(r"Required final hint missing:\s*`?([^`\n.]+)`?", text, flags=re.IGNORECASE)
    if not match:
        return None
    return match.group(1).strip().strip("`'\"") or None


def _extract_training_signals(text: str) -> list[str]:
    signals: list[str] = []
    capture = False
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("Training signals for next run"):
            capture = True
            continue
        if capture and re.match(r"^[✅❌]\s+Training eval:", stripped):
            break
        if capture and stripped.startswith("•"):
            signals.append(stripped.lstrip("•").strip())
    return signals


def _extract_int(text: str, pattern: str, *, default: int | None) -> int | None:
    match = re.search(pattern, text, flags=re.MULTILINE)
    if not match:
        return default
    try:
        return int(match.group(1))
    except ValueError:
        return default


def _extract_field(body: str, field: str) -> str:
    match = re.search(rf"(?m)^{re.escape(field)}:\s*(.*)$", body)
    return match.group(1).strip() if match else ""


def _extract_multiline_field(body: str, field: str) -> str:
    match = re.search(rf"(?ms)^{re.escape(field)}:\s*(.*)$", body)
    if not match:
        return ""
    value = match.group(1).strip()
    header_alternation = "|".join(re.escape(header) for header in sorted(REPORT_FIELD_HEADERS - {field}))
    stop = re.search(rf"(?m)^({header_alternation}):\s*", value) if header_alternation else None
    return value[: stop.start()].strip() if stop else value


def _parse_intent_line(value: str) -> tuple[str, str | None]:
    if not value:
        return "unknown", None
    parts = [part.strip() for part in value.split("/ expected ", 1)]
    return parts[0], parts[1] if len(parts) > 1 else None
