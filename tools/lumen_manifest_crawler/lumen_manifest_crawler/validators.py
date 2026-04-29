from __future__ import annotations

import json
from collections import Counter

from lumen_manifest_crawler.manifest import AgentBehaviorManifest, ValidationFailure, ValidationReport, ValidationWarning

DEFAULT_SUPPORTED_JSON_TYPES = {"string", "double", "int", "bool", "array", "object", "null", "number"}
VAGUE_TYPES = {"any", "unknown", "dictionary", "dict"}


def validate_manifest(manifest: AgentBehaviorManifest, dataset_records: dict[str, list[dict]] | None = None) -> ValidationReport:
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

    supported_types = set(manifest.agentProtocols.executorOutput.get("supportedJSONTypes", [])) or DEFAULT_SUPPORTED_JSON_TYPES
    normalized_supported = {str(t).lower() for t in supported_types}.union(DEFAULT_SUPPORTED_JSON_TYPES)
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
        if len(entry.allowedTools) > 1:
            warnings.append(ValidationWarning(code="ambiguous_intent_tools", message=f"Intent {entry.intent} has multiple allowed tools", path=f"routingMatrix.{entry.intent}"))

    for freshness in manifest.memory.freshnessClasses:
        if freshness.ttlSeconds is None and not freshness.durable:
            warnings.append(ValidationWarning(code="freshness_missing_ttl", message=f"Freshness class {freshness.id} has no TTL or durable marker", path=f"memory.freshnessClasses.{freshness.id}"))

    if dataset_records:
        _validate_dataset_records(manifest, dataset_records, failures, warnings)

    return ValidationReport(passed=not failures, failures=failures, warnings=warnings)


def _validate_dataset_records(manifest: AgentBehaviorManifest, records: dict[str, list[dict]], failures: list[ValidationFailure], warnings: list[ValidationWarning]) -> None:
    forbidden = set(manifest.sentinels.forbiddenInUserOutput)
    known_tools = {tool.id for tool in manifest.tools}
    approval_tools = {tool.id for tool in manifest.tools if tool.requiresApproval}

    covered_required_tools: set[str] = set()
    covered_approval_tools: set[str] = set()

    for name, dataset in records.items():
        for index, record in enumerate(dataset):
            dumped = json.dumps(record, ensure_ascii=False)
            if name in {"mouth_responses", "mimicry_style"}:
                for sentinel in forbidden:
                    if sentinel and sentinel in dumped:
                        failures.append(ValidationFailure(code="sentinel_leak", message=f"Sentinel {sentinel} leaked in {name}[{index}]", path=f"dataset.{name}.{index}"))
            if name in {"executor_tool_calls", "approval_boundary_samples"}:
                tool_id = _find_tool_id(record)
                if tool_id:
                    if tool_id not in known_tools:
                        failures.append(ValidationFailure(code="unknown_executor_tool", message=f"Executor dataset references unknown tool {tool_id}", path=f"dataset.{name}.{index}"))
                    covered_required_tools.add(tool_id)
                    if tool_id in approval_tools:
                        covered_approval_tools.add(tool_id)
            if name == "cortex_routing":
                tool_id = _find_selected_tool_id(record)
                if tool_id and tool_id not in known_tools:
                    failures.append(ValidationFailure(code="unknown_cortex_tool", message=f"Cortex dataset references unknown tool {tool_id}", path=f"dataset.{name}.{index}"))

    for tool in manifest.tools:
        if any(arg.required for arg in tool.arguments) and tool.id not in covered_required_tools:
            failures.append(ValidationFailure(code="missing_executor_sample", message=f"Tool {tool.id} has required args but no executor sample", path=f"tools.{tool.id}"))
        if tool.requiresApproval and tool.id not in covered_approval_tools:
            failures.append(ValidationFailure(code="missing_approval_sample", message=f"Tool {tool.id} requires approval but has no approval dataset sample", path=f"tools.{tool.id}"))


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
