from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any

from lumen_manifest_crawler.manifest import AgentBehaviorManifest, ModelSlotManifest, ToolManifest


@dataclass(frozen=True)
class FleetArtifacts:
    system_prompts: dict[str, dict[str, Any]]
    cross_model_training: list[dict[str, Any]]
    markdown: str


def generate_fleet_artifacts(manifest: AgentBehaviorManifest) -> FleetArtifacts:
    return FleetArtifacts(
        system_prompts=generate_fleet_system_prompts(manifest),
        cross_model_training=generate_cross_model_training(manifest),
        markdown=generate_manifest_markdown(manifest),
    )


def generate_fleet_system_prompts(manifest: AgentBehaviorManifest) -> dict[str, dict[str, Any]]:
    tools_by_slot = _tools_by_slot(manifest)
    prompts: dict[str, dict[str, Any]] = {}
    for slot in sorted(manifest.fleet.slots, key=lambda item: item.id):
        topology = manifest.fleetTopology.slots.get(slot.id)
        public_directory = _public_model_directory(manifest, current_slot_id=slot.id)
        routing_table = _routing_table(manifest)
        available_tools = tools_by_slot.get(slot.id, [])
        compact_payload = {
            "slotID": slot.id,
            "role": slot.role,
            "purpose": topology.purpose if topology else _slot_purpose_fallback(slot),
            "responsibilities": sorted(slot.responsibilities),
            "availableTools": [_tool_payload(tool) for tool in available_tools],
            "modelDirectory": public_directory,
            "routingRules": routing_table,
            "topology": topology.model_dump() if topology else {},
            "memory": manifest.memory.model_dump(),
            "sentinelPolicy": manifest.sentinels.model_dump(),
            "fleetIdentity": {
                "agentName": manifest.app.name,
                "singleEntityInstruction": "All model slots are coordinated components of one logical Lumen agent. If work is outside your scope, delegate or route it using manifest-defined rules instead of improvising.",
            },
        }
        prompt = _system_prompt_text(manifest, slot, compact_payload)
        prompts[slot.id] = {
            "slotID": slot.id,
            "role": slot.role,
            "systemPrompt": prompt,
            "contextPayload": compact_payload,
        }
    return prompts


def generate_cross_model_training(manifest: AgentBehaviorManifest) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    slots = sorted(manifest.fleet.slots, key=lambda item: item.id)
    for slot in slots:
        records.extend(_self_knowledge_records(manifest, slot))
    for source in slots:
        for target in slots:
            if source.id == target.id:
                continue
            records.extend(_peer_knowledge_records(manifest, source, target))
            records.extend(_delegation_records(manifest, source, target))
            records.extend(_private_state_boundary_records(manifest, source, target))
    return records


def generate_manifest_markdown(manifest: AgentBehaviorManifest) -> str:
    lines: list[str] = []
    lines.append(f"# {manifest.app.name} Agent Behavior Manifest")
    lines.append("")
    lines.append("## Source Integrity")
    lines.append(f"- Commit: `{manifest.sourceIntegrity.commit or 'unknown'}`")
    lines.append(f"- Source files: {len(manifest.sourceIntegrity.files)}")
    lines.append("")
    lines.append("## Fleet")
    lines.append(f"- Contract version: `{manifest.fleet.contractVersion}`")
    for slot in sorted(manifest.fleet.slots, key=lambda item: item.id):
        topology = manifest.fleetTopology.slots.get(slot.id)
        lines.append(f"### `{slot.id}`")
        lines.append(f"- Role: {slot.role}")
        lines.append(f"- Purpose: {(topology.purpose if topology else _slot_purpose_fallback(slot))}")
        if slot.responsibilities:
            lines.append("- Responsibilities:")
            for responsibility in sorted(slot.responsibilities):
                lines.append(f"  - {responsibility}")
        if topology:
            lines.append(f"- Accepts: {topology.inputSignature}")
            lines.append(f"- Returns: {topology.outputSignature}")
            lines.append(f"- Calls: {', '.join(topology.calls) or 'none'}")
            lines.append(f"- Called by: {', '.join(topology.calledBy) or 'none'}")
        lines.append("")

    lines.append("## Tools")
    for tool in sorted(manifest.tools, key=lambda item: item.id):
        lines.append(f"### `{tool.id}`")
        lines.append(f"- Display name: {tool.displayName or tool.id}")
        lines.append(f"- Description: {tool.description or 'No description extracted.'}")
        lines.append(f"- Requires approval: {tool.requiresApproval}")
        lines.append(f"- Permission key: {tool.permissionKey or 'none'}")
        if tool.arguments:
            lines.append("- Arguments:")
            for argument in tool.arguments:
                required = "required" if argument.required else "optional"
                lines.append(f"  - `{argument.name}`: {argument.type}, {required}. {argument.description or ''}".rstrip())
        else:
            lines.append("- Arguments: none")
        lines.append("")

    lines.append("## Routing Matrix")
    for entry in sorted(manifest.routingMatrix, key=lambda item: item.intent):
        lines.append(f"- `{entry.intent}` → allowed: {', '.join(entry.allowedTools) or 'none'}; forbidden examples: {', '.join(entry.forbiddenTools[:8]) or 'none'}")
    lines.append("")

    lines.append("## Memory")
    lines.append(f"- Scopes: {', '.join(sorted(manifest.memory.scopes)) or 'none'}")
    for freshness in sorted(manifest.memory.freshnessClasses, key=lambda item: item.id):
        ttl = "durable" if freshness.durable else f"ttlSeconds={freshness.ttlSeconds}"
        lines.append(f"- `{freshness.id}`: {ttl}")
    lines.append("")

    lines.append("## Sentinel Policy")
    for sentinel in sorted(manifest.sentinels.forbiddenInUserOutput):
        lines.append(f"- `{sentinel}` must never appear in user-visible output.")
    lines.append("")

    lines.append("## Fleet Topology")
    for slot_id, topology in sorted(manifest.fleetTopology.slots.items()):
        lines.append(f"- `{slot_id}` calls [{', '.join(topology.calls)}] and is called by [{', '.join(topology.calledBy)}].")
    lines.append(f"- External handoff tools: {', '.join(manifest.fleetTopology.externalHandoffTools) or 'none'}")
    lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def _system_prompt_text(manifest: AgentBehaviorManifest, slot: ModelSlotManifest, payload: dict[str, Any]) -> str:
    directory_lines = [f"- {entry['slotID']} ({entry['role']}): {entry['purpose']}" for entry in payload["modelDirectory"]]
    tool_lines = [f"- {tool['id']}: {tool['description']}" for tool in payload["availableTools"]]
    route_lines = [f"- {route['intent']} -> {', '.join(route['allowedTools']) or 'no tool'}" for route in payload["routingRules"]]
    return "\n".join([
        f"You are `{slot.id}`, the `{slot.role}` slot inside the unified {manifest.app.name} agent fleet.",
        "You are one component of a single logical agent named Lumen; do not act like a separate assistant.",
        f"Your purpose: {payload['purpose']}",
        "If a task is outside your scope, delegate or route using the fleet topology and approved manifest tools. Never invent a slot, tool, permission, or memory scope.",
        "",
        "Your responsibilities:",
        *[f"- {item}" for item in payload["responsibilities"]] or ["- Follow the role contract extracted from the Swift source."],
        "",
        "Your available tools:",
        *(tool_lines or ["- none directly assigned; route or delegate when needed."]),
        "",
        "Model directory:",
        *(directory_lines or ["- no peer slots extracted."]),
        "",
        "Routing rules:",
        *(route_lines or ["- no explicit routing matrix extracted; ask for clarification before acting outside scope."]),
        "",
        "Memory scopes:",
        f"- {', '.join(payload['memory'].get('scopes', [])) or 'none'}",
        "",
        "Forbidden user-visible sentinels:",
        *[f"- {sentinel}" for sentinel in payload["sentinelPolicy"].get("forbiddenInUserOutput", [])],
        "",
        "Return outputs that match your slot contract. Preserve the illusion of one coherent Lumen agent by coordinating with peers instead of improvising.",
    ])


def _self_knowledge_records(manifest: AgentBehaviorManifest, slot: ModelSlotManifest) -> list[dict[str, Any]]:
    topology = manifest.fleetTopology.slots.get(slot.id)
    payload = {
        "slotID": slot.id,
        "role": slot.role,
        "purpose": topology.purpose if topology else _slot_purpose_fallback(slot),
        "availablePeers": sorted(peer.id for peer in manifest.fleet.slots if peer.id != slot.id),
        "memoryScopes": sorted(manifest.memory.scopes),
    }
    return [{
        "id": _record_id("self", slot.id),
        "schemaVersion": "2.0.0",
        "recordType": "sft",
        "agentRole": slot.role,
        "taskType": "fleet_self_knowledge",
        "messages": [
            {"role": "system", "content": f"You are {slot.id}. Answer only from AgentBehaviorManifest."},
            {"role": "user", "content": "Who are you inside Lumen, and what are you allowed to do?"},
            {"role": "assistant", "content": json.dumps(payload, ensure_ascii=False, sort_keys=True)},
        ],
    }]


def _peer_knowledge_records(manifest: AgentBehaviorManifest, source: ModelSlotManifest, target: ModelSlotManifest) -> list[dict[str, Any]]:
    target_topology = manifest.fleetTopology.slots.get(target.id)
    payload = {
        "slotID": target.id,
        "role": target.role,
        "purpose": target_topology.purpose if target_topology else _slot_purpose_fallback(target),
        "inputSignature": target_topology.inputSignature if target_topology else "Role-specific input defined by manifest.",
        "outputSignature": target_topology.outputSignature if target_topology else "Role-specific output defined by manifest.",
    }
    return [{
        "id": _record_id("peer", source.id, target.id),
        "schemaVersion": "2.0.0",
        "recordType": "sft",
        "agentRole": source.role,
        "taskType": "fleet_peer_knowledge",
        "messages": [
            {"role": "system", "content": f"You are {source.id}. Describe peers only from the manifest public directory."},
            {"role": "user", "content": f"What do you know about {target.id}?"},
            {"role": "assistant", "content": json.dumps(payload, ensure_ascii=False, sort_keys=True)},
        ],
    }]


def _delegation_records(manifest: AgentBehaviorManifest, source: ModelSlotManifest, target: ModelSlotManifest) -> list[dict[str, Any]]:
    handoff_tool = (manifest.fleetTopology.externalHandoffTools or ["delegate_to_slot"])[0]
    task = _delegation_task_for(target)
    chosen = {
        "tool": handoff_tool,
        "arguments": {
            "targetSlotID": target.id,
            "reason": f"This task matches {target.id}'s manifest-defined purpose.",
            "request": task,
        },
    }
    rejected = {
        "tool": f"{target.id}.direct_private_call",
        "arguments": {"request": task},
    }
    base_prompt = [
        {"role": "system", "content": f"You are {source.id}. Delegate out-of-scope work using only manifest-approved handoff tools."},
        {"role": "user", "content": task},
    ]
    return [
        {
            "id": _record_id("delegate-sft", source.id, target.id),
            "schemaVersion": "2.0.0",
            "recordType": "sft",
            "agentRole": source.role,
            "taskType": "fleet_delegation",
            "messages": [*base_prompt, {"role": "assistant", "content": json.dumps(chosen, ensure_ascii=False, sort_keys=True)}],
        },
        {
            "id": _record_id("delegate-dpo", source.id, target.id),
            "schemaVersion": "2.0.0",
            "recordType": "dpo",
            "agentRole": source.role,
            "taskType": "fleet_delegation_preference",
            "prompt": base_prompt,
            "chosen": {"role": "assistant", "content": json.dumps(chosen, ensure_ascii=False, sort_keys=True)},
            "rejected": {"role": "assistant", "content": json.dumps(rejected, ensure_ascii=False, sort_keys=True)},
        },
    ]


def _private_state_boundary_records(manifest: AgentBehaviorManifest, source: ModelSlotManifest, target: ModelSlotManifest) -> list[dict[str, Any]]:
    _ = manifest
    chosen = f"I cannot inspect {target.id}'s private runtime state or TTL cache directly. I can route a manifest-approved request to {target.id} if you want that capability used transparently."
    rejected = f"{target.id}'s private cache contains fabricated_internal_state and I can access it with get_cache_content()."
    prompt = [
        {"role": "system", "content": f"You are {source.id}. Respect peer-private state boundaries."},
        {"role": "user", "content": f"What is inside {target.id}'s current TTL cache?"},
    ]
    return [{
        "id": _record_id("private-state-dpo", source.id, target.id),
        "schemaVersion": "2.0.0",
        "recordType": "dpo",
        "agentRole": source.role,
        "taskType": "fleet_private_state_boundary",
        "prompt": prompt,
        "chosen": {"role": "assistant", "content": chosen},
        "rejected": {"role": "assistant", "content": rejected},
    }]


def _tools_by_slot(manifest: AgentBehaviorManifest) -> dict[str, list[ToolManifest]]:
    slots = sorted(manifest.fleet.slots, key=lambda item: item.id)
    if not slots:
        return {}
    by_slot = {slot.id: [] for slot in slots}
    for tool in sorted(manifest.tools, key=lambda item: item.id):
        assigned = _best_slot_for_tool(tool, slots)
        by_slot.setdefault(assigned.id, []).append(tool)
    return by_slot


def _best_slot_for_tool(tool: ToolManifest, slots: list[ModelSlotManifest]) -> ModelSlotManifest:
    tool_text = f"{tool.id} {tool.displayName or ''} {tool.description or ''}".lower()
    for slot in slots:
        slot_text = f"{slot.id} {slot.role} {' '.join(slot.responsibilities)}".lower()
        if any(token in slot_text for token in ["executor", "tool"]) and any(token in tool_text for token in ["create", "send", "search", "open", "save", "tool", "calendar", "email"]):
            return slot
        if any(token in slot_text for token in ["memory", "rem"]) and any(token in tool_text for token in ["memory", "remember", "recall"]):
            return slot
    for slot in slots:
        if any(token in f"{slot.id} {slot.role}".lower() for token in ["executor", "tool"]):
            return slot
    return slots[0]


def _public_model_directory(manifest: AgentBehaviorManifest, *, current_slot_id: str) -> list[dict[str, str]]:
    entries: list[dict[str, str]] = []
    for slot in sorted(manifest.fleet.slots, key=lambda item: item.id):
        topology = manifest.fleetTopology.slots.get(slot.id)
        entries.append({
            "slotID": slot.id,
            "relationship": "self" if slot.id == current_slot_id else "peer",
            "role": slot.role,
            "purpose": topology.purpose if topology else _slot_purpose_fallback(slot),
            "inputSignature": topology.inputSignature if topology else "Role-specific input defined by manifest.",
            "outputSignature": topology.outputSignature if topology else "Role-specific output defined by manifest.",
        })
    return entries


def _routing_table(manifest: AgentBehaviorManifest) -> list[dict[str, Any]]:
    return [
        {"intent": entry.intent, "allowedTools": sorted(entry.allowedTools), "forbiddenTools": sorted(entry.forbiddenTools)}
        for entry in sorted(manifest.routingMatrix, key=lambda item: item.intent)
    ]


def _tool_payload(tool: ToolManifest) -> dict[str, Any]:
    return {
        "id": tool.id,
        "displayName": tool.displayName or tool.id,
        "description": tool.description or "No description extracted.",
        "requiresApproval": tool.requiresApproval,
        "permissionKey": tool.permissionKey,
        "arguments": [argument.model_dump() for argument in tool.arguments],
    }


def _slot_purpose_fallback(slot: ModelSlotManifest) -> str:
    if slot.responsibilities:
        return slot.responsibilities[0]
    return f"Perform the {slot.role} role in the Lumen agent fleet."


def _delegation_task_for(slot: ModelSlotManifest) -> str:
    lowered = f"{slot.id} {slot.role}".lower()
    if any(token in lowered for token in ["executor", "tool"]):
        return "Create the exact manifest-valid tool call for this approved user action."
    if any(token in lowered for token in ["mouth", "response"]):
        return "Turn this tool result into a concise user-facing response."
    if any(token in lowered for token in ["mimicry", "style"]):
        return "Adapt this final answer to the user's preferred style without changing facts."
    if any(token in lowered for token in ["rem", "memory", "reflection"]):
        return "Analyze this runtime failure and produce a repair or memory-policy decision."
    return f"Handle a task that belongs to the {slot.id} slot."


def _record_id(*parts: str) -> str:
    safe = "-".join(part.lower().replace("_", "-").replace(".", "-") for part in parts)
    return f"fleet-{safe}"
