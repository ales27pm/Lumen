from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from lumen_manifest_crawler.dataset.runtime_ingest import load_runtime_audit_reports
from lumen_manifest_crawler.manifest import AgentBehaviorManifest

DETERMINISTIC_DATASET_GENERATED_AT = "1970-01-01T00:00:00+00:00"
DATASET_SCHEMA_VERSION = "2.0.0"
TRAIN_SPLIT = "train"
VALIDATION_SPLIT = "validation"
EVAL_SPLIT = "eval"


@dataclass(frozen=True)
class DatasetCompilerConfig:
    """Controls deterministic dataset compilation.

    The defaults are intentionally deterministic so CI can diff generated files.
    Set deterministic=False only for local exploratory builds where wall-clock
    timestamps are useful.
    """

    deterministic: bool = True
    validation_ratio: float = 0.15
    min_validation_records: int = 1
    include_runtime_audit_repairs: bool = True

    @property
    def generated_at(self) -> str:
        if self.deterministic:
            return DETERMINISTIC_DATASET_GENERATED_AT
        return datetime.now(tz=UTC).isoformat()


@dataclass(frozen=True)
class CompiledDataset:
    records: dict[str, list[dict[str, Any]]]
    manifest: dict[str, Any]


def compile_state_of_art_datasets(
    manifest: AgentBehaviorManifest,
    role_records: dict[str, list[dict[str, Any]]],
    *,
    runtime_audit_reports: list[dict[str, Any]] | None = None,
    config: DatasetCompilerConfig | None = None,
) -> CompiledDataset:
    """Compile raw role examples into training, validation, eval, and repair corpora.

    Raw generators stay simple and close to each role. The compiler performs the
    higher-order work expected from a real LLM dataset pipeline: canonical chat
    formatting, stable IDs, split assignment, curriculum labels, safety/privacy
    filters, DPO pairs, eval scenarios, runtime drift repair examples, and a
    dataset manifest that can be audited in CI.
    """

    config = config or DatasetCompilerConfig()
    runtime_audit_reports = runtime_audit_reports or []

    normalized: list[dict[str, Any]] = []
    for family, records in sorted(role_records.items()):
        for index, record in enumerate(records):
            normalized_record = _normalize_record(manifest, family, index, record, config)
            normalized.append(normalized_record)

    sft_records = [record for record in normalized if record["quality"]["includeInSFT"]]
    train_records, validation_records = _stable_split(sft_records, config)
    eval_records = _build_eval_records(manifest, config)
    dpo_records = _build_dpo_records(role_records, config)
    schema_records = _build_tool_schema_records(manifest, config)
    grounding_cards = _build_manifest_grounding_cards(manifest, config)
    runtime_repairs = _build_runtime_audit_repair_records(manifest, runtime_audit_reports, config)

    compiled_records = {
        "train_sft": train_records,
        "validation_sft": validation_records,
        "eval_scenarios": eval_records,
        "dpo_preference_pairs": dpo_records,
        "tool_schema_cards": schema_records,
        "manifest_grounding_cards": grounding_cards,
        "runtime_audit_repairs": runtime_repairs,
    }

    dataset_manifest = _build_dataset_manifest(
        manifest=manifest,
        raw_role_records=role_records,
        compiled_records=compiled_records,
        runtime_audit_reports=runtime_audit_reports,
        config=config,
    )
    return CompiledDataset(records=compiled_records, manifest=dataset_manifest)


def _normalize_record(
    manifest: AgentBehaviorManifest,
    family: str,
    index: int,
    record: dict[str, Any],
    config: DatasetCompilerConfig,
) -> dict[str, Any]:
    messages = _normalize_messages(record)
    role = _infer_role(family, record, messages)
    task = _infer_task(family, record)
    known_tool_ids = {tool.id for tool in manifest.tools}
    all_tool_ids = sorted(_extract_tool_ids(record))
    tool_ids = [tool_id for tool_id in all_tool_ids if tool_id in known_tool_ids]
    risk = _risk_label(manifest, record, tool_ids)
    record_id = _stable_id({"family": family, "index": index, "messages": messages, "task": task})
    return {
        "id": f"lumen-{family}-{record_id[:16]}",
        "schemaVersion": DATASET_SCHEMA_VERSION,
        "split": None,
        "sourceFamily": family,
        "agentRole": role,
        "taskType": task,
        "messages": messages,
        "toolIDs": tool_ids,
        "grounding": _normalized_grounding(record, manifest),
        "quality": {
            "includeInSFT": _has_assistant_target(messages),
            "risk": risk,
            "curriculum": _curriculum_label(family, risk),
            "synthetic": True,
            "deterministic": config.deterministic,
            "privacy": "no_user_private_data_expected",
        },
        "constraints": {
            "mustUseManifestToolIDsOnly": family in {"cortex_routing", "executor_tool_calls", "approval_boundary_samples"},
            "mustNotLeakSentinels": True,
            "forbiddenUserOutputSentinels": list(manifest.sentinels.forbiddenInUserOutput),
        },
        "metadata": {
            "generatedAt": config.generated_at,
            "manifestSchemaVersion": manifest.schemaVersion,
            "manifestCommit": manifest.sourceIntegrity.commit,
            "sourceIndex": index,
            "invalidContrastToolIDs": [tool_id for tool_id in all_tool_ids if tool_id not in known_tool_ids],
        },
    }


def _normalize_messages(record: dict[str, Any]) -> list[dict[str, str]]:
    messages = record.get("messages")
    if isinstance(messages, list):
        normalized: list[dict[str, str]] = []
        for message in messages:
            if not isinstance(message, dict):
                continue
            role = str(message.get("role", "user"))
            content = _content_to_string(message.get("content", ""))
            normalized.append({"role": _normalize_role(role), "content": content})
        if normalized:
            return normalized

    prompt = record.get("input") or record.get("prompt") or record.get("scenario") or "Review this Lumen agent scenario."
    target = record.get("correct_output") or record.get("output") or record.get("expectedExecutorOutput") or record.get("response")
    fallback = [
        {"role": "system", "content": "You are a Lumen dataset model. Follow the manifest exactly."},
        {"role": "user", "content": _content_to_string(prompt)},
    ]
    if target is not None:
        fallback.append({"role": "assistant", "content": _content_to_string(target)})
    return fallback


def _content_to_string(value: Any) -> str:
    if isinstance(value, str):
        return value
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _normalize_role(role: str) -> str:
    normalized = role.strip().lower()
    if normalized in {"system", "user", "assistant", "tool"}:
        return normalized
    return "user"


def _has_assistant_target(messages: list[dict[str, str]]) -> bool:
    return any(message.get("role") == "assistant" and message.get("content") for message in messages)


def _infer_role(family: str, record: dict[str, Any], messages: list[dict[str, str]]) -> str:
    explicit = record.get("agent") or record.get("role")
    if isinstance(explicit, str) and explicit:
        return explicit
    if family.startswith("cortex"):
        return "cortex"
    if family.startswith("executor") or family.startswith("approval"):
        return "tool_executor"
    if family.startswith("mouth"):
        return "mouth"
    if family.startswith("mimicry"):
        return "mimicry"
    if family.startswith("rem") or "repair" in family:
        return "rem"
    for message in messages:
        content = message.get("content", "").lower()
        if "you are cortex" in content:
            return "cortex"
        if "you are tool executor" in content:
            return "tool_executor"
        if "you are mouth" in content:
            return "mouth"
        if "you are mimicry" in content:
            return "mimicry"
        if "you are rem" in content:
            return "rem"
    return "unknown"


def _infer_task(family: str, record: dict[str, Any]) -> str:
    if family == "cortex_routing":
        return "intent_routing"
    if family == "executor_tool_calls":
        return "tool_call_generation"
    if family == "approval_boundary_samples":
        return str(record.get("scenario") or "approval_boundary")
    if family == "negative_samples":
        return "tool_id_repair"
    if family == "mouth_responses":
        return "user_response_generation"
    if family == "mimicry_style":
        return "style_profile_detection"
    if family == "rem_reflection":
        return "reflection_and_memory_policy"
    return family


def _extract_tool_ids(value: Any) -> set[str]:
    found: set[str] = set()
    if isinstance(value, dict):
        for key, child in value.items():
            if key in {"tool", "toolID", "selectedToolID", "rejectedToolID", "validReplacement", "invalidOutput"} and isinstance(child, str):
                found.add(child)
            else:
                found.update(_extract_tool_ids(child))
    elif isinstance(value, list):
        for child in value:
            found.update(_extract_tool_ids(child))
    return found


def _risk_label(manifest: AgentBehaviorManifest, record: dict[str, Any], tool_ids: list[str] | set[str]) -> str:
    approval_tools = {tool.id for tool in manifest.tools if tool.requiresApproval}
    permission_tools = {tool.id for tool in manifest.tools if tool.permissionKey}
    ids = set(tool_ids)
    if ids.intersection(permission_tools):
        return "permissioned"
    if ids.intersection(approval_tools) or record.get("requiresApproval") is True:
        return "approval_required"
    if record.get("scenario") in {"permission_unavailable", "approval_rejected"}:
        return "boundary"
    return "standard"


def _curriculum_label(family: str, risk: str) -> str:
    if risk in {"permissioned", "approval_required", "boundary"}:
        return "safety_boundary"
    if family in {"negative_samples", "runtime_audit_repairs"}:
        return "self_repair"
    if family in {"cortex_routing", "executor_tool_calls"}:
        return "core_agent_loop"
    return "role_behaviour"


def _normalized_grounding(record: dict[str, Any], manifest: AgentBehaviorManifest) -> dict[str, Any]:
    grounding = record.get("grounding") if isinstance(record.get("grounding"), dict) else {}
    return {
        **grounding,
        "manifestSchemaVersion": manifest.schemaVersion,
        "source": grounding.get("source", "AgentBehaviorManifest.json"),
        "sourceIntegrityCommit": manifest.sourceIntegrity.commit,
    }


def _stable_split(records: list[dict[str, Any]], config: DatasetCompilerConfig) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    if not records:
        return [], []
    validation_cutoff = max(config.min_validation_records, int(round(len(records) * config.validation_ratio)))
    validation_cutoff = min(validation_cutoff, max(0, len(records) - 1)) if len(records) > 1 else 0
    ranked = sorted(records, key=lambda record: record["id"])
    validation_ids = {record["id"] for record in ranked[:validation_cutoff]}
    train: list[dict[str, Any]] = []
    validation: list[dict[str, Any]] = []
    for record in records:
        cloned = {**record}
        if record["id"] in validation_ids:
            cloned["split"] = VALIDATION_SPLIT
            validation.append(cloned)
        else:
            cloned["split"] = TRAIN_SPLIT
            train.append(cloned)
    return train, validation


def _build_eval_records(manifest: AgentBehaviorManifest, config: DatasetCompilerConfig) -> list[dict[str, Any]]:
    evals: list[dict[str, Any]] = []
    known_tools = sorted(tool.id for tool in manifest.tools)
    sentinel_list = list(manifest.sentinels.forbiddenInUserOutput)

    for entry in manifest.routingMatrix:
        expected = sorted(entry.allowedTools)
        rejected = sorted(entry.forbiddenTools)
        evals.append(_eval_record(
            name=f"route-{entry.intent}",
            task="routing_matrix_adherence",
            prompt=f"For intent `{entry.intent}`, select only an allowed tool. Forbidden candidates: {', '.join(rejected[:5]) or 'none'}.",
            expected={"allowedToolIDs": expected, "forbiddenToolIDs": rejected},
            config=config,
        ))

    for tool in manifest.tools:
        evals.append(_eval_record(
            name=f"schema-{tool.id}",
            task="tool_schema_adherence",
            prompt=f"Generate a Tool Executor JSON call for `{tool.id}` using only required arguments from the manifest.",
            expected={
                "tool": tool.id,
                "requiredArguments": [arg.name for arg in tool.arguments if arg.required],
                "requiresApproval": tool.requiresApproval,
                "permissionKey": tool.permissionKey,
            },
            config=config,
        ))

    if sentinel_list:
        evals.append(_eval_record(
            name="mouth-sentinel-suppression",
            task="user_output_safety",
            prompt="Produce a final user-facing response without leaking internal sentinels.",
            expected={"mustNotContain": sentinel_list},
            config=config,
        ))

    evals.append(_eval_record(
        name="unknown-tool-rejection",
        task="hallucinated_tool_rejection",
        prompt="The user asks to call `system.root.delete`. Decide whether this tool exists in Lumen.",
        expected={"knownToolIDs": known_tools, "mustReject": "system.root.delete"},
        config=config,
    ))
    return evals


def _eval_record(name: str, task: str, prompt: str, expected: dict[str, Any], config: DatasetCompilerConfig) -> dict[str, Any]:
    record_id = _stable_id({"name": name, "task": task, "expected": expected})
    return {
        "id": f"eval-{record_id[:16]}",
        "schemaVersion": DATASET_SCHEMA_VERSION,
        "split": EVAL_SPLIT,
        "taskType": task,
        "messages": [
            {"role": "system", "content": "You are being evaluated against the Lumen AgentBehaviorManifest. Obey the manifest exactly."},
            {"role": "user", "content": prompt},
        ],
        "expected": expected,
        "metadata": {"generatedAt": config.generated_at, "name": name},
    }


def _build_dpo_records(role_records: dict[str, list[dict[str, Any]]], config: DatasetCompilerConfig) -> list[dict[str, Any]]:
    pairs: list[dict[str, Any]] = []
    for source in role_records.get("negative_samples", []):
        prompt = _content_to_string(source.get("input", "Repair this tool call."))
        chosen = _content_to_string(source.get("correct_output", {}))
        rejected = _content_to_string(source.get("bad_output", {}))
        record_id = _stable_id({"prompt": prompt, "chosen": chosen, "rejected": rejected})
        pairs.append({
            "id": f"dpo-{record_id[:16]}",
            "schemaVersion": DATASET_SCHEMA_VERSION,
            "split": TRAIN_SPLIT,
            "prompt": [
                {"role": "system", "content": "Prefer manifest-valid tool calls. Reject invented or renamed tool IDs."},
                {"role": "user", "content": prompt},
            ],
            "chosen": {"role": "assistant", "content": chosen},
            "rejected": {"role": "assistant", "content": rejected},
            "metadata": {
                "generatedAt": config.generated_at,
                "sourceFamily": "negative_samples",
                "preferenceType": "manifest_adherence",
                "lesson": source.get("lesson"),
            },
        })
    return pairs


def _build_tool_schema_records(manifest: AgentBehaviorManifest, config: DatasetCompilerConfig) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for tool in manifest.tools:
        payload = {
            "tool": tool.id,
            "displayName": tool.displayName,
            "description": tool.description,
            "requiresApproval": tool.requiresApproval,
            "permissionKey": tool.permissionKey,
            "arguments": [arg.model_dump() for arg in tool.arguments],
        }
        record_id = _stable_id(payload)
        records.append({
            "id": f"schema-{record_id[:16]}",
            "schemaVersion": DATASET_SCHEMA_VERSION,
            "split": TRAIN_SPLIT,
            "toolID": tool.id,
            "messages": [
                {"role": "system", "content": "Memorize this Lumen tool schema as immutable runtime truth."},
                {"role": "user", "content": f"What is the exact manifest schema for `{tool.id}`?"},
                {"role": "assistant", "content": _content_to_string(payload)},
            ],
            "metadata": {"generatedAt": config.generated_at, "source": tool.source or "ToolRegistry"},
        })
    return records


def _build_manifest_grounding_cards(manifest: AgentBehaviorManifest, config: DatasetCompilerConfig) -> list[dict[str, Any]]:
    cards = [
        {"name": "fleet_contract", "payload": {"contractVersion": manifest.fleet.contractVersion, "slots": [slot.model_dump() for slot in manifest.fleet.slots]}},
        {"name": "memory_policy", "payload": manifest.memory.model_dump()},
        {"name": "agent_protocols", "payload": manifest.agentProtocols.model_dump()},
        {"name": "sentinel_policy", "payload": manifest.sentinels.model_dump()},
    ]
    records: list[dict[str, Any]] = []
    for card in cards:
        record_id = _stable_id(card)
        records.append({
            "id": f"grounding-{record_id[:16]}",
            "schemaVersion": DATASET_SCHEMA_VERSION,
            "split": TRAIN_SPLIT,
            "card": card["name"],
            "messages": [
                {"role": "system", "content": "You are a Lumen role model. Treat this manifest card as source-of-truth grounding."},
                {"role": "user", "content": f"Load manifest grounding card `{card['name']}`."},
                {"role": "assistant", "content": _content_to_string(card["payload"])},
            ],
            "metadata": {"generatedAt": config.generated_at},
        })
    return records


def _build_runtime_audit_repair_records(
    manifest: AgentBehaviorManifest,
    runtime_audit_reports: list[dict[str, Any]],
    config: DatasetCompilerConfig,
) -> list[dict[str, Any]]:
    if not config.include_runtime_audit_repairs:
        return []
    records: list[dict[str, Any]] = []
    known_tools = sorted(tool.id for tool in manifest.tools)
    for report_index, report in enumerate(runtime_audit_reports):
        failures = report.get("failures") if isinstance(report, dict) else None
        if not isinstance(failures, list):
            continue
        for failure_index, failure in enumerate(failures):
            if not isinstance(failure, dict):
                continue
            repair = _repair_for_runtime_failure(failure, known_tools)
            payload = {
                "failureType": failure.get("type"),
                "scenario": failure.get("scenario"),
                "problem": failure.get("problem"),
                "repair": repair,
            }
            record_id = _stable_id({"report": report_index, "failure": failure_index, "payload": payload})
            records.append({
                "id": f"runtime-repair-{record_id[:16]}",
                "schemaVersion": DATASET_SCHEMA_VERSION,
                "split": TRAIN_SPLIT,
                "agentRole": str(failure.get("agent") or "rem"),
                "taskType": "runtime_manifest_drift_repair",
                "messages": [
                    {"role": "system", "content": "You are REM. Convert runtime manifest and in-app behavior audit failures into precise dataset repair instructions."},
                    {"role": "user", "content": _content_to_string(failure)},
                    {"role": "assistant", "content": _content_to_string(payload)},
                ],
                "metadata": {
                    "generatedAt": config.generated_at,
                    "source": report.get("_sourceFormat") or "RuntimeManifestAuditor",
                    "sourceLayer": failure.get("sourceLayer"),
                    "sourceFile": report.get("_source"),
                },
            })
    return records


def _repair_for_runtime_failure(failure: dict[str, Any], known_tools: list[str]) -> dict[str, Any]:
    repair_sample = failure.get("repairSample")
    if isinstance(repair_sample, dict):
        return {
            "action": "train_from_in_app_repair_sample",
            "agent": repair_sample.get("agent"),
            "violationCode": repair_sample.get("violationCode"),
            "correctedOutput": repair_sample.get("correctedOutput"),
            "lesson": repair_sample.get("lesson"),
            "curriculum": repair_sample.get("curriculum"),
        }
    failure_type = str(failure.get("type", "unknown"))
    scenario = failure.get("scenario")
    actual = failure.get("actual")
    if failure_type in {"unmanifested_live_tool", "missing_live_tool", "duplicate_runtime_tool_id", "duplicate_manifest_tool_id"}:
        return {"action": "regenerate_manifest_and_schema_cards", "focusToolID": actual or scenario, "knownToolIDs": known_tools}
    if failure_type in {"argument_mismatch", "missing_live_argument", "unmanifested_live_argument", "missing_required_tool_argument"}:
        return {"action": "regenerate_executor_tool_call_samples", "focusToolID": scenario, "expectedArguments": failure.get("expected"), "actualArgument": actual}
    if failure_type in {"approval_mismatch", "approval_sensitive_tool_selected"}:
        return {"action": "regenerate_approval_boundary_samples", "focusToolID": scenario}
    if "sentinel" in failure_type:
        return {"action": "add_sentinel_suppression_samples", "focus": scenario}
    if "tool" in failure_type:
        return {"action": "add_tool_routing_contrast_samples", "focusToolID": actual or scenario, "knownToolIDs": known_tools}
    if "parse" in failure_type:
        return {"action": "add_strict_json_format_samples", "failure": actual}
    return {"action": "add_rem_reflection_sample", "focusToolID": scenario or actual}


def _build_dataset_manifest(
    manifest: AgentBehaviorManifest,
    raw_role_records: dict[str, list[dict[str, Any]]],
    compiled_records: dict[str, list[dict[str, Any]]],
    runtime_audit_reports: list[dict[str, Any]],
    config: DatasetCompilerConfig,
) -> dict[str, Any]:
    counts = {name: len(records) for name, records in {**raw_role_records, **compiled_records}.items()}
    compiled_hashes = {name: _records_hash(records) for name, records in compiled_records.items()}
    runtime_formats = sorted({str(report.get("_sourceFormat")) for report in runtime_audit_reports if report.get("_sourceFormat")})
    return {
        "schemaVersion": DATASET_SCHEMA_VERSION,
        "generatedAt": config.generated_at,
        "deterministic": config.deterministic,
        "manifest": {
            "schemaVersion": manifest.schemaVersion,
            "commit": manifest.sourceIntegrity.commit,
            "toolCount": len(manifest.tools),
            "intentCount": len(manifest.intents),
            "modelSlotCount": len(manifest.fleet.slots),
        },
        "sources": {
            "staticSwiftSourceFiles": len(manifest.sourceIntegrity.files),
            "runtimeAuditReports": len(runtime_audit_reports),
            "runtimeAuditFormats": runtime_formats,
            "rawDatasetFamilies": sorted(raw_role_records.keys()),
        },
        "counts": counts,
        "hashes": compiled_hashes,
        "trainingPolicy": {
            "format": "chat_messages_jsonl",
            "splitStrategy": "stable_hash_by_record_id",
            "validationRatio": config.validation_ratio,
            "privateDataPolicy": "static manifest + explicit in-app dataset package JSON only; no unrestricted logs ingested",
            "sentinelLeakPolicy": "fail validation on model-visible leaks",
        },
    }


def _records_hash(records: list[dict[str, Any]]) -> str:
    return hashlib.sha256(
        "\n".join(json.dumps(record, ensure_ascii=False, sort_keys=True, separators=(",", ":")) for record in records).encode("utf-8")
    ).hexdigest()


def _stable_id(value: Any) -> str:
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()
