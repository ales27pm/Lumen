from __future__ import annotations

import json
from pathlib import Path
from typing import Any


def load_runtime_audit_reports(paths: list[Path] | None) -> list[dict[str, Any]]:
    reports: list[dict[str, Any]] = []
    for path in paths or []:
        candidates = sorted(path.rglob("*.json")) if path.is_dir() else [path]
        for candidate in candidates:
            try:
                value = json.loads(candidate.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            reports.extend(_normalize_payload(value, source=str(candidate)))
    return reports


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
        if selected_tool_id and allowed_tool_ids and selected_tool_id not in allowed_tool_ids:
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
