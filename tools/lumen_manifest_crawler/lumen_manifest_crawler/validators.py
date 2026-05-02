from __future__ import annotations

import re
from collections import Counter
from collections.abc import Iterable
from typing import Any

from lumen_manifest_crawler.manifest import AgentBehaviorManifest, ValidationFailure, ValidationReport, ValidationWarning

DEFAULT_SUPPORTED_JSON_TYPES = {"string", "double", "int", "bool", "array", "object", "null", "number"}
VAGUE_TYPES = {"any", "unknown", "dictionary", "dict"}
STRICT_TOOL_ID_DATASET_FAMILIES = {"tool_schema_cards", "runtime_audit_repairs", "dpo_preference_pairs"}
STRICT_WARNING_CODES = {"tool_missing_description", "vague_argument_type", "inferred_tool_definition", "ambiguous_intent_tools", "freshness_missing_ttl"}
MIN_EVAL_SCENARIOS_PER_TOOL = 5
FANOUT_INTENTS = {
    "alarm",
    "calendar",
    "files",
    "maps",
    "memory",
    "outlook",
    "photos",
    "rag",
    "trigger",
    "weather",
}


def validate_manifest(manifest: AgentBehaviorManifest, dataset_records: dict[str, list[dict]] | None = None, *, strict: bool = False) -> ValidationReport:
    failures: list[ValidationFailure] = []
    warnings: list[ValidationWarning] = []

    tool_ids = [tool.id for tool in manifest.tools]
    tool_counts = Counter(tool_ids)
    for tool_id, count in tool_counts.items():
        if count > 1:
            failures.append(ValidationFailure(code="duplicate_tool_id", message=f"Duplicate tool id: {tool_id}", path="tools"))

    known_tools = set(tool_ids)
    for intent in manifest.intents:
        for tool_id in intent.allowedToolIDs:
            if tool_id not in known_tools:
                failures.append(ValidationFailure(code="unknown_intent_tool", message=f"Intent {intent.id} references missing tool {tool_id}", path=f"intents.{intent.id}"))

    raw_supported = manifest.agentProtocols.executorOutput.get("supportedJSONTypes")
    supported_types = set(raw_supported) if raw_supported else DEFAULT_SUPPORTED_JSON_TYPES
    normalized_supported = {str(t).lower() for t in supported_types}
    for tool in manifest.tools:
        if getattr(tool, "inferred", False):
            warnings.append(
                ValidationWarning(
                    code="inferred_tool_definition",
                    message=f"Tool {tool.id} was inferred from a {tool.inferredSource or 'literal'} and may be missing approval, permission, argument, and description metadata.",
                    path=f"tools.{tool.id}",
                )
            )
        if not tool.description:
            warnings.append(ValidationWarning(code="tool_missing_description", message=f"Tool {tool.id} has no description", path=f"tools.{tool.id}"))
        for arg in tool.arguments:
            arg_type = arg.type.lower()
            if arg_type in VAGUE_TYPES:
                warnings.append(ValidationWarning(code="vague_argument_type", message=f"Tool {tool.id}.{arg.name} uses vague type {arg.type}", path=f"tools.{tool.id}.arguments.{arg.name}"))
            if arg_type not in normalized_supported:
                failures.append(ValidationFailure(code="unsupported_argument_type", message=f"Tool {tool.id}.{arg.name} uses unsupported type {arg.type}", path=f"tools.{tool.id}.arguments.{arg.name}"))

    for slot in manifest.fleet.slots:
        if not slot.role:
            failures.append(ValidationFailure(code="model_slot_missing_role", message=f"Model slot {slot.id} has no role", path=f"fleet.slots.{slot.id}"))

    for entry in manifest.routingMatrix:
        if len(entry.allowedTools) > 1 and entry.intent not in FANOUT_INTENTS:
            warnings.append(ValidationWarning(code="ambiguous_intent_tools", message=f"Intent {entry.intent} has multiple allowed tools", path=f"routingMatrix.{entry.intent}"))

    for freshness in manifest.memory.freshnessClasses:
        if freshness.ttlSeconds is None and not freshness.durable:
            warnings.append(ValidationWarning(code="freshness_missing_ttl", message=f"Freshness class {freshness.id} has no TTL or durable marker", path=f"memory.freshnessClasses.{freshness.id}"))

    if dataset_records:
        _validate_dataset_records(manifest, dataset_records, failures, warnings)

    if strict:
        strict_failures = [
            ValidationFailure(code=f"strict_{warning.code}", message=warning.message, path=warning.path)
            for warning in warnings
            if warning.code in STRICT_WARNING_CODES
        ]
        failures.extend(strict_failures)

    return ValidationReport(passed=not failures, failures=failures, warnings=warnings)


def _validate_dataset_records(manifest: AgentBehaviorManifest, records: dict[str, list[dict]], failures: list[ValidationFailure], warnings: list[ValidationWarning]) -> None:
    forbidden = set(manifest.sentinels.forbiddenInUserOutput)
    known_tools = {tool.id for tool in manifest.tools}
    approval_tools = {tool.id for tool in manifest.tools if tool.requiresApproval}

    covered_required_tools: set[str] = set()
    covered_approval_tools: set[str] = set()
    compiled_ids: set[str] = set()
    eval_scenarios_by_tool: Counter[str] = Counter()
    eval_tool_records: dict[str, list[dict[str, Any]]] = {tool.id: [] for tool in manifest.tools}

    for name, dataset in records.items():
        for index, record in enumerate(dataset):
            _validate_compiled_record_shape(name, index, record, failures, warnings, compiled_ids)
            if name in {"mouth_responses", "mimicry_style", "train_sft", "validation_sft", "tool_schema_cards", "runtime_audit_repairs", "dpo_preference_pairs"}:
                for sentinel in forbidden:
                    if sentinel and _record_model_visible_text_contains(record, sentinel):
                        failures.append(ValidationFailure(code="sentinel_leak", message=f"Sentinel {sentinel} leaked in {name}[{index}]", path=f"dataset.{name}.{index}"))
            if name in {"executor_tool_calls", "approval_boundary_samples"}:
                tool_id = _find_tool_id(record)
                if tool_id:
                    if tool_id not in known_tools:
                        failures.append(ValidationFailure(code="unknown_executor_tool", message=f"Executor dataset references unknown tool {tool_id}", path=f"dataset.{name}.{index}"))
                    covered_required_tools.add(tool_id)
                    if tool_id in approval_tools:
                        covered_approval_tools.add(tool_id)
            if name in STRICT_TOOL_ID_DATASET_FAMILIES:
                for tool_id in _extract_declared_tool_ids(record):
                    if tool_id not in known_tools and not _looks_like_intentionally_invalid_tool(tool_id):
                        failures.append(ValidationFailure(code="unknown_compiled_tool", message=f"Compiled dataset references unknown tool {tool_id}", path=f"dataset.{name}.{index}"))
            if name == "cortex_routing":
                tool_id = _find_selected_tool_id(record)
                if tool_id and tool_id not in known_tools:
                    failures.append(ValidationFailure(code="unknown_cortex_tool", message=f"Cortex dataset references unknown tool {tool_id}", path=f"dataset.{name}.{index}"))
            if name == "eval_scenarios":
                tool_id = _find_eval_expected_tool_id(record)
                if tool_id:
                    if tool_id not in known_tools:
                        failures.append(ValidationFailure(code="unknown_eval_tool", message=f"Eval scenario references unknown tool {tool_id}", path=f"dataset.{name}.{index}"))
                    elif record.get("taskType") == "tool_runtime_scenario_selection":
                        eval_scenarios_by_tool[tool_id] += 1
                        eval_tool_records.setdefault(tool_id, []).append(record)

    for tool in manifest.tools:
        if any(arg.required for arg in tool.arguments) and tool.id not in covered_required_tools:
            failures.append(ValidationFailure(code="missing_executor_sample", message=f"Tool {tool.id} has required args but no executor sample", path=f"tools.{tool.id}"))
        if tool.requiresApproval and tool.id not in covered_approval_tools:
            failures.append(ValidationFailure(code="missing_approval_sample", message=f"Tool {tool.id} requires approval but has no approval dataset sample", path=f"tools.{tool.id}"))
        if eval_scenarios_by_tool[tool.id] < MIN_EVAL_SCENARIOS_PER_TOOL:
            failures.append(ValidationFailure(code="missing_tool_eval_scenarios", message=f"Tool {tool.id} has {eval_scenarios_by_tool[tool.id]} runtime eval scenarios; expected at least {MIN_EVAL_SCENARIOS_PER_TOOL}", path=f"dataset.eval_scenarios.{tool.id}"))
        scenarios = eval_tool_records.get(tool.id, [])
        natural = [r for r in scenarios if (r.get("metadata") or {}).get("scenarioKind") == "natural_intent"]
        explicit = [r for r in scenarios if (r.get("metadata") or {}).get("scenarioKind") == "explicit_tool_schema"]
        if len(natural) < 2:
            failures.append(ValidationFailure(code="missing_natural_tool_eval_scenarios", message=f"Tool {tool.id} has {len(natural)} natural intent eval scenarios; expected at least 2", path=f"dataset.eval_scenarios.{tool.id}"))
        if not explicit:
            failures.append(ValidationFailure(code="missing_explicit_schema_eval", message=f"Tool {tool.id} is missing explicit schema eval scenarios", path=f"dataset.eval_scenarios.{tool.id}"))
        covered_args: set[str] = set()
        has_approval = False
        has_permission = False
        for record in scenarios:
            metadata = record.get("metadata") or {}
            scenario_kind = metadata.get("scenarioKind")
            arg_cov = metadata.get("argumentCoverage")
            if isinstance(arg_cov, list):
                covered_args.update(arg for arg in arg_cov if isinstance(arg, str))
            if metadata.get("approvalCoverage") is True:
                has_approval = True
            if metadata.get("permissionCoverage") is True:
                has_permission = True
            if scenario_kind == "natural_intent":
                if metadata.get("toolIDVisibleInPrompt") is not False:
                    failures.append(ValidationFailure(code="tool_id_leak_in_natural_eval", message=f"Tool {tool.id} natural eval metadata marks tool id visible", path=f"dataset.eval_scenarios.{tool.id}"))
                prompt_text = "\n".join(
                    message.get("content", "") for message in record.get("messages", []) if isinstance(message, dict)
                )
                if _has_explicit_tool_id_reference(prompt_text, tool.id):
                    failures.append(ValidationFailure(code="tool_id_leak_in_natural_eval", message=f"Tool {tool.id} leaked in natural intent prompt", path=f"dataset.eval_scenarios.{tool.id}"))
        required_args = {arg.name for arg in tool.arguments if arg.required}
        missing_args = sorted(required_args - covered_args)
        if missing_args:
            failures.append(ValidationFailure(code="missing_argument_eval_coverage", message=f"Tool {tool.id} missing argument coverage for: {', '.join(missing_args)}", path=f"dataset.eval_scenarios.{tool.id}"))
        if tool.requiresApproval and not has_approval:
            failures.append(ValidationFailure(code="missing_approval_eval_coverage", message=f"Tool {tool.id} requires approval coverage in eval scenarios", path=f"dataset.eval_scenarios.{tool.id}"))
        if tool.permissionKey and not has_permission:
            failures.append(ValidationFailure(code="missing_permission_eval_coverage", message=f"Tool {tool.id} requires permission coverage in eval scenarios", path=f"dataset.eval_scenarios.{tool.id}"))



def _has_explicit_tool_id_reference(prompt_text: str, tool_id: str) -> bool:
    if not prompt_text or not tool_id:
        return False
    if "." in tool_id:
        return tool_id in prompt_text

    escaped = re.escape(tool_id)
    explicit_patterns = (
        rf"`{escaped}`",
        rf'[\'\"]{escaped}[\'\"]',
        rf"\btool\s+{escaped}\b",
        rf"\buse\s+{escaped}\b",
    )
    lowered = prompt_text.lower()
    return any(re.search(pattern, lowered, flags=re.IGNORECASE) for pattern in explicit_patterns)

def _validate_compiled_record_shape(name: str, index: int, record: dict, failures: list[ValidationFailure], warnings: list[ValidationWarning], seen_ids: set[str]) -> None:
    if name == "dataset_manifest":
        return
    if name in {"train_sft", "validation_sft", "eval_scenarios", "tool_schema_cards", "manifest_grounding_cards", "runtime_audit_repairs", "dpo_preference_pairs"}:
        record_id = record.get("id")
        if not isinstance(record_id, str) or not record_id:
            failures.append(ValidationFailure(code="compiled_record_missing_id", message=f"{name}[{index}] has no stable id", path=f"dataset.{name}.{index}"))
        elif record_id in seen_ids:
            failures.append(ValidationFailure(code="duplicate_compiled_record_id", message=f"Duplicate compiled dataset id {record_id}", path=f"dataset.{name}.{index}"))
        else:
            seen_ids.add(record_id)
    if name in {"train_sft", "validation_sft", "eval_scenarios", "tool_schema_cards", "manifest_grounding_cards", "runtime_audit_repairs"}:
        messages = record.get("messages")
        if not isinstance(messages, list) or not messages:
            failures.append(ValidationFailure(code="compiled_record_missing_messages", message=f"{name}[{index}] has no messages array", path=f"dataset.{name}.{index}"))
        else:
            for message_index, message in enumerate(messages):
                if not isinstance(message, dict) or message.get("role") not in {"system", "user", "assistant", "tool"} or not isinstance(message.get("content"), str):
                    failures.append(ValidationFailure(code="invalid_chat_message", message=f"{name}[{index}].messages[{message_index}] is not canonical chat format", path=f"dataset.{name}.{index}.messages.{message_index}"))
    if name == "dpo_preference_pairs":
        if not isinstance(record.get("prompt"), list) or not isinstance(record.get("chosen"), dict) or not isinstance(record.get("rejected"), dict):
            failures.append(ValidationFailure(code="invalid_dpo_pair", message=f"{name}[{index}] is missing prompt/chosen/rejected", path=f"dataset.{name}.{index}"))


def _record_model_visible_text_contains(record: dict, needle: str) -> bool:
    """Check only prompt/completion text visible to the trained model.

    Grounding metadata may intentionally contain forbidden sentinel strings as a
    blacklist. Treating the whole JSON record as trainable text makes the
    validator report its own guardrail as a leak.
    """
    for value in _model_visible_values(record):
        if needle in value:
            return True
    return False


def _model_visible_values(record: dict) -> Iterable[str]:
    for message in record.get("messages", []):
        if not isinstance(message, dict):
            continue
        content = message.get("content")
        if isinstance(content, str):
            yield content
        elif isinstance(content, dict):
            yield from _string_values(content)
    for message in record.get("prompt", []):
        if isinstance(message, dict) and isinstance(message.get("content"), str):
            yield message["content"]
    for key in ("input", "output", "prompt", "completion", "response"):
        value = record.get(key)
        if isinstance(value, str):
            yield value
        elif isinstance(value, dict):
            yield from _string_values(value)


def _string_values(value: Any) -> Iterable[str]:
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for child in value.values():
            yield from _string_values(child)
    elif isinstance(value, list):
        for child in value:
            yield from _string_values(child)


def _find_tool_id(record: dict) -> str | None:
    if isinstance(record.get("tool"), str):
        return record["tool"]
    for message in record.get("messages", []):
        content = message.get("content") if isinstance(message, dict) else None
        if isinstance(content, dict) and isinstance(content.get("tool"), str):
            return content["tool"]
    expected = record.get("expectedExecutorOutput")
    if isinstance(expected, dict) and isinstance(expected.get("tool"), str):
        return expected["tool"]
    return None


def _find_selected_tool_id(record: dict) -> str | None:
    for message in record.get("messages", []):
        content = message.get("content") if isinstance(message, dict) else None
        if isinstance(content, dict) and isinstance(content.get("selectedToolID"), str):
            return content["selectedToolID"]
    return None


def _find_eval_expected_tool_id(record: dict) -> str | None:
    expected = record.get("expected")
    if isinstance(expected, dict):
        for key in ("selectedToolID", "tool"):
            value = expected.get(key)
            if isinstance(value, str):
                return value
    return None


def _extract_declared_tool_ids(record: dict) -> set[str]:
    raw = record.get("toolIDs")
    if isinstance(raw, list):
        return {value for value in raw if isinstance(value, str)}
    tool_id = record.get("toolID")
    if isinstance(tool_id, str):
        return {tool_id}
    return set()


def _looks_like_intentionally_invalid_tool(tool_id: str) -> bool:
    lowered = tool_id.lower()
    if lowered.endswith(("fake", "invalid")):
        return True
    tokens = [token for token in re.split(r"[^a-z0-9]+", lowered) if token]
    return "invalid" in tokens


def validate_agent_fine_tuning_datasets(manifest: AgentBehaviorManifest, datasets: dict[str, Any], runtime_audit_reports: list[dict[str, Any]] | None = None) -> list[ValidationFailure]:
    failures: list[ValidationFailure] = []
    known_agents = {"cortex", "executor", "mouth", "mimicry", "rem", "fleet"}
    known_tools = {tool.id for tool in manifest.tools}
    slots = {slot.id for slot in manifest.fleet.slots}
    forbidden = set(manifest.sentinels.forbiddenInUserOutput)
    for agent, ds in datasets.items():
        if agent not in known_agents:
            failures.append(ValidationFailure(code="unknown_agent_role", message=f"Unknown agent role {agent}", path=f"fine_tuning.{agent}"))
            continue
        for rec in ds.train_sft + ds.val_sft:
            assistant = next((m.get("content", "") for m in rec.get("messages", []) if m.get("role") == "assistant"), "")
            if not assistant.strip():
                failures.append(ValidationFailure(code="empty_assistant_output", message=f"{agent} has empty assistant output", path=f"fine_tuning.{agent}"))
            if any(s and s in assistant for s in forbidden):
                failures.append(ValidationFailure(code="sentinel_leak", message=f"{agent} leaked sentinel", path=f"fine_tuning.{agent}"))
            for tool_id in rec.get("metadata", {}).get("toolIDs", []):
                if tool_id not in known_tools:
                    failures.append(ValidationFailure(code="unknown_tool_id", message=f"{agent} unknown tool {tool_id}", path=f"fine_tuning.{agent}"))
        for rec in ds.train_dpo + ds.val_dpo:
            if (rec.get("chosen") or {}).get("content") == (rec.get("rejected") or {}).get("content"):
                failures.append(ValidationFailure(code="dpo_chosen_equals_rejected", message=f"{agent} DPO chosen equals rejected", path=f"fine_tuning.{agent}"))
        for rec in ds.eval:
            if rec.get("expected") is None:
                failures.append(ValidationFailure(code="eval_missing_expected", message=f"{agent} eval missing expected", path=f"fine_tuning.{agent}"))
        if agent == "fleet":
            blob = "\n".join(json.dumps(r, ensure_ascii=False, sort_keys=True) for r in (ds.train_sft + ds.val_sft))
            for slot in slots:
                if slot not in blob:
                    failures.append(ValidationFailure(code="fleet_slot_coverage_missing", message=f"fleet missing slot coverage {slot}", path="fine_tuning.fleet"))
    return failures
