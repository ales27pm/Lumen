from __future__ import annotations

import hashlib
import json
import subprocess
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

from lumen_manifest_crawler.crawler import generate_manifest
from lumen_manifest_crawler.dataset import generate_all_datasets
from lumen_manifest_crawler.dataset.fine_tuning import compile_agent_fine_tuning_datasets
from lumen_manifest_crawler.dataset.runtime_ingest import load_runtime_audit_reports
from lumen_manifest_crawler.fleet_artifacts import generate_fleet_artifacts
from lumen_manifest_crawler.output.writer import write_outputs
from lumen_manifest_crawler.validators import validate_agent_fine_tuning_datasets, validate_manifest

DETERMINISTIC_LOOP_TIMESTAMP = "1970-01-01T00:00:00+00:00"
LOOP_SCHEMA_VERSION = "1.0.0"
DEFAULT_LOOP_DIR = Path("generated/agent_improvement_loop")


@dataclass(frozen=True)
class LoopCommandResult:
    name: str
    command: list[str]
    cwd: str
    returncode: int
    stdout_tail: str
    stderr_tail: str

    @property
    def passed(self) -> bool:
        return self.returncode == 0

    def output_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "command": self.command,
            "cwd": self.cwd,
            "returncode": self.returncode,
            "passed": self.passed,
            "stdoutTail": self.stdout_tail,
            "stderrTail": self.stderr_tail,
        }


@dataclass(frozen=True)
class AgentImprovementLoopConfig:
    root: Path
    output: Path
    loop_output: Path = DEFAULT_LOOP_DIR
    runtime_audit_paths: tuple[Path, ...] = ()
    deterministic: bool = True
    pretty: bool = True
    strict: bool = True
    generate_system_prompts: bool = True
    generate_agent_fine_tuning: bool = True
    fine_tuning_output: Path | None = None
    cross_model_train_dir: Path | None = None
    build_command: tuple[str, ...] = ()
    test_command: tuple[str, ...] = ()
    train_command: tuple[str, ...] = ()
    max_tail_chars: int = 12000
    fail_on_validation: bool = False
    dry_run_commands: bool = False


@dataclass(frozen=True)
class AgentImprovementLoopResult:
    state: dict[str, Any]
    gaps: list[dict[str, Any]]
    next_prompts: list[dict[str, Any]]
    command_results: list[LoopCommandResult]

    @property
    def passed(self) -> bool:
        hard_gaps = [gap for gap in self.gaps if gap.get("severity") in {"critical", "error"}]
        failed_commands = [result for result in self.command_results if not result.passed]
        return not hard_gaps and not failed_commands


def run_agent_improvement_loop(config: AgentImprovementLoopConfig) -> AgentImprovementLoopResult:
    """Run one closed-loop improvement pass.

    The loop intentionally performs one deterministic iteration, not an actual
    infinite process. External automation can repeat this command forever. This
    keeps every cycle auditable, diffable, and safe to stop or roll back.
    """
    root = config.root.resolve()
    output = config.output.resolve()
    loop_output = config.loop_output.resolve()
    loop_output.mkdir(parents=True, exist_ok=True)

    started_at = DETERMINISTIC_LOOP_TIMESTAMP if config.deterministic else datetime.now(timezone.utc).isoformat()
    command_results: list[LoopCommandResult] = []

    command_results.append(_run_optional_command("pre_generation_tests", config.test_command, root, config))

    manifest = generate_manifest(root)
    runtime_reports = load_runtime_audit_reports(list(config.runtime_audit_paths))
    datasets = generate_all_datasets(
        manifest,
        runtime_audit_paths=list(config.runtime_audit_paths) if config.runtime_audit_paths else None,
        deterministic=config.deterministic,
    )
    validation_report = validate_manifest(manifest, datasets, strict=config.strict)
    fleet_artifacts = generate_fleet_artifacts(manifest) if config.generate_system_prompts else None

    fine_tuning_datasets = None
    if config.generate_agent_fine_tuning:
        fine_tuning_datasets = compile_agent_fine_tuning_datasets(
            manifest,
            datasets,
            fleet_artifacts=fleet_artifacts,
            runtime_audit_reports=runtime_reports,
        )
        ft_failures = validate_agent_fine_tuning_datasets(
            manifest,
            fine_tuning_datasets,
            runtime_audit_reports=runtime_reports,
        )
        for failure in ft_failures:
            validation_report.failures.append(failure)

    write_outputs(
        output,
        manifest,
        validation_report,
        datasets,
        pretty=config.pretty,
        fleet_artifacts=fleet_artifacts,
        cross_model_train_dir=config.cross_model_train_dir,
        incremental_fingerprint=_manifest_fingerprint(manifest),
        fine_tuning_datasets=fine_tuning_datasets,
        fine_tuning_output_dir=config.fine_tuning_output,
    )

    command_results.append(_run_optional_command("build", config.build_command, root, config))
    command_results.append(_run_optional_command("train", config.train_command, root, config))

    dataset_summary = _dataset_summary(datasets, fine_tuning_datasets)
    runtime_summary = _runtime_summary(runtime_reports)
    command_summary = [result.output_dict() for result in command_results if result.command]
    gaps = _build_gap_report(
        manifest=manifest,
        validation_report=validation_report,
        datasets=datasets,
        fine_tuning_datasets=fine_tuning_datasets,
        runtime_reports=runtime_reports,
        command_results=command_results,
    )
    next_prompts = _build_next_action_prompts(gaps, runtime_reports, command_results)

    state = {
        "schemaVersion": LOOP_SCHEMA_VERSION,
        "startedAt": started_at,
        "completedAt": DETERMINISTIC_LOOP_TIMESTAMP if config.deterministic else datetime.now(timezone.utc).isoformat(),
        "root": str(root),
        "output": str(output),
        "runtimeAuditInputs": [str(path) for path in config.runtime_audit_paths],
        "manifest": {
            "commit": manifest.sourceIntegrity.commit,
            "fingerprint": _manifest_fingerprint(manifest),
            "toolCount": len(manifest.tools),
            "intentCount": len(manifest.intents),
            "modelSlotCount": len(manifest.fleet.slots),
            "routingEntryCount": len(manifest.routingMatrix),
        },
        "dataset": dataset_summary,
        "runtime": runtime_summary,
        "validation": {
            "failureCount": len(validation_report.failures),
            "warningCount": len(validation_report.warnings),
            "failures": [_model_dump(failure) for failure in validation_report.failures],
            "warnings": [_model_dump(warning) for warning in validation_report.warnings],
        },
        "commands": command_summary,
        "gapCount": len(gaps),
        "criticalGapCount": sum(1 for gap in gaps if gap.get("severity") == "critical"),
        "errorGapCount": sum(1 for gap in gaps if gap.get("severity") == "error"),
        "passed": not any(gap.get("severity") in {"critical", "error"} for gap in gaps) and all(result.passed for result in command_results),
        "nextActionPromptCount": len(next_prompts),
    }

    _write_json(loop_output / "loop_state.json", state)
    _write_json(loop_output / "loop_gaps.json", {"gaps": gaps})
    _write_jsonl(loop_output / "next_action_prompts.jsonl", next_prompts)
    _write_markdown_report(loop_output / "LOOP_REPORT.md", state, gaps, next_prompts)

    result = AgentImprovementLoopResult(
        state=state,
        gaps=gaps,
        next_prompts=next_prompts,
        command_results=command_results,
    )
    if config.fail_on_validation and not result.passed:
        raise RuntimeError(f"Agent improvement loop failed with {len(gaps)} gap(s). See {loop_output}")
    return result


def _run_optional_command(name: str, command: tuple[str, ...], cwd: Path, config: AgentImprovementLoopConfig) -> LoopCommandResult:
    if not command:
        return LoopCommandResult(name=name, command=[], cwd=str(cwd), returncode=0, stdout_tail="", stderr_tail="")
    if config.dry_run_commands:
        return LoopCommandResult(
            name=name,
            command=list(command),
            cwd=str(cwd),
            returncode=0,
            stdout_tail="dry-run: command not executed",
            stderr_tail="",
        )
    completed = subprocess.run(
        list(command),
        cwd=cwd,
        text=True,
        capture_output=True,
        timeout=None,
    )
    return LoopCommandResult(
        name=name,
        command=list(command),
        cwd=str(cwd),
        returncode=completed.returncode,
        stdout_tail=_tail(completed.stdout, config.max_tail_chars),
        stderr_tail=_tail(completed.stderr, config.max_tail_chars),
    )


def _tail(text: str, max_chars: int) -> str:
    if len(text) <= max_chars:
        return text
    return text[-max_chars:]


def _manifest_fingerprint(manifest: Any) -> str:
    payload = json.dumps(manifest.output_dict(), ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def _dataset_summary(datasets: dict[str, list[dict[str, Any]]], fine_tuning_datasets: Any) -> dict[str, Any]:
    families = {
        name: len(records)
        for name, records in sorted(datasets.items())
        if name != "dataset_manifest"
    }
    out: dict[str, Any] = {
        "familyCount": len(families),
        "recordCount": sum(families.values()),
        "families": families,
    }
    if fine_tuning_datasets:
        out["agentFineTuning"] = {
            agent: {
                "trainSFT": len(dataset.train_sft),
                "valSFT": len(dataset.val_sft),
                "trainDPO": len(dataset.train_dpo),
                "valDPO": len(dataset.val_dpo),
                "eval": len(dataset.eval),
            }
            for agent, dataset in sorted(fine_tuning_datasets.items())
        }
    return out


def _runtime_summary(runtime_reports: list[dict[str, Any]]) -> dict[str, Any]:
    failures = [failure for report in runtime_reports for failure in report.get("failures", []) if isinstance(failure, dict)]
    by_type: dict[str, int] = {}
    by_layer: dict[str, int] = {}
    for failure in failures:
        by_type[str(failure.get("type") or "unknown")] = by_type.get(str(failure.get("type") or "unknown"), 0) + 1
        by_layer[str(failure.get("sourceLayer") or "unknown")] = by_layer.get(str(failure.get("sourceLayer") or "unknown"), 0) + 1
    return {
        "reportCount": len(runtime_reports),
        "failureCount": len(failures),
        "failureTypes": dict(sorted(by_type.items())),
        "sourceLayers": dict(sorted(by_layer.items())),
    }


def _build_gap_report(
    *,
    manifest: Any,
    validation_report: Any,
    datasets: dict[str, list[dict[str, Any]]],
    fine_tuning_datasets: Any,
    runtime_reports: list[dict[str, Any]],
    command_results: list[LoopCommandResult],
) -> list[dict[str, Any]]:
    gaps: list[dict[str, Any]] = []

    for failure in validation_report.failures:
        dumped = _model_dump(failure)
        gaps.append({
            "id": _stable_id("validation", dumped),
            "severity": "error",
            "category": "validation",
            "title": dumped.get("code") or "validation_failure",
            "evidence": dumped,
            "recommendedAction": "Fix source extraction or dataset generation until manifest validation is clean.",
        })

    for warning in validation_report.warnings:
        dumped = _model_dump(warning)
        gaps.append({
            "id": _stable_id("warning", dumped),
            "severity": "warning",
            "category": "validation_warning",
            "title": dumped.get("code") or "validation_warning",
            "evidence": dumped,
            "recommendedAction": "Review warning and either improve extraction coverage or intentionally document the exception.",
        })

    for result in command_results:
        if result.command and not result.passed:
            gaps.append({
                "id": _stable_id("command", result.output_dict()),
                "severity": "critical",
                "category": "command_failure",
                "title": f"{result.name} command failed",
                "evidence": result.output_dict(),
                "recommendedAction": "Fix the failing command before trusting this loop iteration.",
            })

    runtime_failures = [failure for report in runtime_reports for failure in report.get("failures", []) if isinstance(failure, dict)]
    for failure in runtime_failures[:200]:
        failure_type = str(failure.get("type") or "runtime_failure")
        severity = "critical" if any(token in failure_type for token in ["unknown_tool", "sentinel", "not_allowed"]) else "error"
        gaps.append({
            "id": _stable_id("runtime", failure),
            "severity": severity,
            "category": "runtime_drift",
            "title": failure_type,
            "evidence": failure,
            "recommendedAction": _runtime_recommendation(failure_type),
        })

    required_families = {
        "train_sft",
        "validation_sft",
        "eval_scenarios",
        "dpo_preference_pairs",
        "tool_schema_cards",
        "manifest_grounding_cards",
        "runtime_audit_repairs",
    }
    for family in sorted(required_families):
        if len(datasets.get(family, [])) == 0:
            gaps.append({
                "id": _stable_id("empty_family", family),
                "severity": "error" if family != "runtime_audit_repairs" else "warning",
                "category": "dataset_coverage",
                "title": f"Empty dataset family: {family}",
                "evidence": {"family": family},
                "recommendedAction": f"Add generators or runtime inputs that produce {family} records.",
            })

    if fine_tuning_datasets:
        for agent, dataset in sorted(fine_tuning_datasets.items()):
            if not dataset.train_sft:
                gaps.append({
                    "id": _stable_id("agent_empty_sft", agent),
                    "severity": "error",
                    "category": "agent_fine_tuning_coverage",
                    "title": f"No SFT records for {agent}",
                    "evidence": {"agent": agent},
                    "recommendedAction": f"Add or route role-specific examples for the {agent} agent.",
                })
            if not dataset.eval:
                gaps.append({
                    "id": _stable_id("agent_empty_eval", agent),
                    "severity": "warning",
                    "category": "agent_eval_coverage",
                    "title": f"No eval records for {agent}",
                    "evidence": {"agent": agent},
                    "recommendedAction": f"Add must-pass eval scenarios for the {agent} agent.",
                })

    tool_count = len(manifest.tools)
    eval_count = len(datasets.get("eval_scenarios", []))
    if tool_count and eval_count < tool_count * 5:
        gaps.append({
            "id": _stable_id("eval_coverage", {"toolCount": tool_count, "evalCount": eval_count}),
            "severity": "warning",
            "category": "eval_coverage",
            "title": "Eval scenario coverage is below five records per tool",
            "evidence": {"toolCount": tool_count, "evalScenarioCount": eval_count, "minimumExpected": tool_count * 5},
            "recommendedAction": "Expand natural, argument, approval, permission, and adversarial scenario generation per tool.",
        })

    return sorted(gaps, key=lambda gap: (str(gap.get("severity")), str(gap.get("category")), str(gap.get("title"))))


def _runtime_recommendation(failure_type: str) -> str:
    if "unknown_tool" in failure_type or "unmanifested" in failure_type or "missing_live_tool" in failure_type:
        return "Regenerate the manifest from Swift source, then add unknown-tool DPO contrast samples."
    if "argument" in failure_type:
        return "Regenerate executor schema cards and add missing-argument clarification examples."
    if "approval" in failure_type:
        return "Add approval-boundary SFT/DPO records and verify the UI confirmation path."
    if "sentinel" in failure_type:
        return "Add Mouth sanitizer and persisted-step sentinel suppression regression samples."
    if "not_allowed" in failure_type or "routing" in failure_type:
        return "Add Cortex routing contrast samples for the violated intent/tool pair."
    return "Convert this failure into a REM repair sample and add a regression eval."


def _build_next_action_prompts(
    gaps: list[dict[str, Any]],
    runtime_reports: list[dict[str, Any]],
    command_results: list[LoopCommandResult],
) -> list[dict[str, Any]]:
    prompts: list[dict[str, Any]] = []
    for gap in gaps[:80]:
        prompts.append({
            "id": _stable_id("prompt", gap),
            "taskType": "codebase_improvement",
            "priority": _priority_for_gap(gap),
            "messages": [
                {
                    "role": "system",
                    "content": "You are improving the Lumen agent dataset loop. Make real source changes only. Do not invent tool IDs, do not weaken privacy policy, and keep generated artifacts deterministic.",
                },
                {
                    "role": "user",
                    "content": _gap_prompt(gap),
                },
            ],
            "metadata": {
                "gapID": gap.get("id"),
                "category": gap.get("category"),
                "severity": gap.get("severity"),
                "runtimeReportCount": len(runtime_reports),
                "failedCommandCount": sum(1 for result in command_results if result.command and not result.passed),
            },
        })
    if not prompts:
        prompts.append({
            "id": _stable_id("prompt", "expand_next_loop"),
            "taskType": "loop_expansion",
            "priority": "medium",
            "messages": [
                {"role": "system", "content": "You are improving the Lumen agent dataset loop."},
                {"role": "user", "content": "No blocking gaps were detected. Expand the next loop by adding one new adversarial scenario family, one runtime trace field, and one dataset quality gate while preserving deterministic output."},
            ],
            "metadata": {"category": "continuous_expansion"},
        })
    return prompts


def _priority_for_gap(gap: dict[str, Any]) -> str:
    return {
        "critical": "highest",
        "error": "high",
        "warning": "medium",
    }.get(str(gap.get("severity")), "low")


def _gap_prompt(gap: dict[str, Any]) -> str:
    return (
        "Fix or expand the Lumen agent improvement loop for this gap.\n\n"
        f"Severity: {gap.get('severity')}\n"
        f"Category: {gap.get('category')}\n"
        f"Title: {gap.get('title')}\n"
        f"Recommended action: {gap.get('recommendedAction')}\n\n"
        "Evidence JSON:\n"
        f"{json.dumps(gap.get('evidence'), ensure_ascii=False, indent=2, sort_keys=True)}\n\n"
        "Required outcome: modify the crawler, in-app audit, runtime trace schema, dataset compiler, tests, or workflow scripts so the next loop iteration has stronger coverage or removes the drift."
    )


def _model_dump(value: Any) -> dict[str, Any]:
    if hasattr(value, "model_dump"):
        return value.model_dump()
    if isinstance(value, dict):
        return value
    return {"value": str(value)}


def _stable_id(*parts: Any) -> str:
    payload = json.dumps(parts, ensure_ascii=False, sort_keys=True, default=str, separators=(",", ":"))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()[:24]


def _write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def _write_jsonl(path: Path, records: Iterable[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for record in records:
            handle.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")


def _write_markdown_report(path: Path, state: dict[str, Any], gaps: list[dict[str, Any]], prompts: list[dict[str, Any]]) -> None:
    lines = [
        "# Lumen Agent Improvement Loop Report",
        "",
        f"- Passed: `{state['passed']}`",
        f"- Tools: `{state['manifest']['toolCount']}`",
        f"- Intents: `{state['manifest']['intentCount']}`",
        f"- Model slots: `{state['manifest']['modelSlotCount']}`",
        f"- Dataset records: `{state['dataset']['recordCount']}`",
        f"- Runtime audit reports: `{state['runtime']['reportCount']}`",
        f"- Runtime failures: `{state['runtime']['failureCount']}`",
        f"- Gaps: `{len(gaps)}`",
        f"- Next action prompts: `{len(prompts)}`",
        "",
        "## Top gaps",
        "",
    ]
    for gap in gaps[:30]:
        lines.extend([
            f"### {gap.get('severity', 'unknown').upper()} — {gap.get('title')}",
            "",
            f"- Category: `{gap.get('category')}`",
            f"- Recommendation: {gap.get('recommendedAction')}",
            "",
        ])
    if not gaps:
        lines.append("No blocking gaps detected. The next loop should expand coverage.")
    path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
