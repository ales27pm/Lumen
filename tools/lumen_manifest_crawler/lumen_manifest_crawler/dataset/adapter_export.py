from __future__ import annotations

import re
from typing import Any

ADAPTER_EXPORT_SCHEMA_VERSION = "1.0.0"
DEFAULT_AGENT_BASE_MODEL_ID = "Qwen/Qwen3-1.7B"
DEFAULT_ADAPTER_DIR = "adapters"


def adapter_artifact_name(agent: str) -> str:
    slug = re.sub(r"[^a-z0-9_.-]+", "-", agent.strip().casefold()).strip("-._")
    return f"{slug or 'agent'}.lora"


def adapter_artifact_path(agent: str) -> str:
    return f"{DEFAULT_ADAPTER_DIR}/{adapter_artifact_name(agent)}"


def base_model_id_from_config(config: dict[str, Any] | None) -> str:
    config = config or {}
    for key in ("baseModelID", "base_model_id", "base_model", "model_name", "modelName"):
        value = config.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return DEFAULT_AGENT_BASE_MODEL_ID


def augment_unsloth_config_for_adapter_export(agent: str, config: dict[str, Any] | None) -> dict[str, Any]:
    """Return an adapter-first training/export config without mutating the input config.

    The improvement loop should train and keep role adapters as the default artifact.
    Merged full-model/GGUF export remains possible, but only as an explicit release-bake
    step after an adapter passes role-specific eval gates.
    """
    out = dict(config or {})
    base_model_id = base_model_id_from_config(out)
    out.setdefault("baseModelID", base_model_id)
    out["artifactMode"] = "adapter_first"
    out["defaultExportArtifact"] = "lora_adapter"
    out["adapterExport"] = {
        "enabled": True,
        "agent": agent,
        "adapterID": f"lumen-{agent}-adapter",
        "adapterArtifact": adapter_artifact_path(agent),
        "baseModelID": base_model_id,
        "trainBaseModelWeights": False,
        "saveAdapterByDefault": True,
        "mergeAdaptersByDefault": False,
        "rollbackUnit": "adapter",
    }
    out["mergeExport"] = {
        "enabledByDefault": False,
        "phase": "optional_release_bake",
        "allowManualExport": True,
        "requiresPassingEvalGates": True,
        "reason": "Keep one shared base model plus role adapters during iterative training; merge only for release/runtime backends that cannot load adapters dynamically.",
    }
    return out


def agent_adapter_export_plan(agent: str, dataset_card: dict[str, Any], unsloth_config: dict[str, Any] | None) -> dict[str, Any]:
    base_model_id = base_model_id_from_config(unsloth_config)
    return {
        "schemaVersion": ADAPTER_EXPORT_SCHEMA_VERSION,
        "mode": "adapter_first",
        "agent": agent,
        "baseModelID": base_model_id,
        "adapterID": f"lumen-{agent}-adapter",
        "adapterArtifact": adapter_artifact_path(agent),
        "systemPrompt": dataset_card.get("systemPrompt"),
        "datasetCard": {
            "manifestCommit": dataset_card.get("manifestCommit"),
            "recordCounts": dataset_card.get("recordCounts", {}),
            "sourceFamilies": dataset_card.get("sourceFamilies", []),
            "taskTypes": dataset_card.get("taskTypes", []),
        },
        "runtimeBinding": {
            "loadBaseModelOnce": True,
            "selectAdapterByAgentSlot": True,
            "agentSlot": agent,
            "promptBinding": "systemPrompt",
            "fallbackToBaselineAdapter": True,
        },
        "exportPolicy": {
            "defaultArtifact": "adapter",
            "mergeAdaptersByDefault": False,
            "mergedExportPhase": "optional_release_bake",
            "publishMergedArtifactByDefault": False,
            "allowMergedExport": True,
            "requiresPassingEvalGatesBeforeMerge": True,
            "rollbackUnit": "adapter",
        },
        "expectedArtifacts": {
            "adapterDirectory": f"{DEFAULT_ADAPTER_DIR}/{agent}",
            "trainSFT": "train_sft.jsonl",
            "validationSFT": "val_sft.jsonl",
            "trainDPO": "train_dpo.jsonl",
            "validationDPO": "val_dpo.jsonl",
            "eval": "eval.jsonl",
            "datasetCard": "dataset_card.json",
            "trainingConfig": "unsloth_config.json",
        },
    }


def adapter_runtime_manifest(datasets: dict[str, Any]) -> dict[str, Any]:
    adapters: list[dict[str, Any]] = []
    base_model_ids: set[str] = set()
    for agent, dataset in sorted(datasets.items()):
        unsloth_config = getattr(dataset, "unsloth_config", {}) or {}
        dataset_card = getattr(dataset, "dataset_card", {}) or {}
        base_model_id = base_model_id_from_config(unsloth_config)
        base_model_ids.add(base_model_id)
        adapters.append(
            {
                "agent": agent,
                "adapterID": f"lumen-{agent}-adapter",
                "adapterArtifact": adapter_artifact_path(agent),
                "baseModelID": base_model_id,
                "systemPrompt": dataset_card.get("systemPrompt"),
                "recordCounts": dataset_card.get("recordCounts", {}),
            }
        )

    shared_base_model_id = next(iter(base_model_ids)) if len(base_model_ids) == 1 else None
    return {
        "schemaVersion": ADAPTER_EXPORT_SCHEMA_VERSION,
        "mode": "adapter_first",
        "sharedBaseModelID": shared_base_model_id,
        "baseModelIDs": sorted(base_model_ids),
        "runtimeStrategy": {
            "loadBaseModelOnce": True,
            "selectAdapterByAgentSlot": True,
            "mergeAdaptersByDefault": False,
            "mergedExportPhase": "optional_release_bake",
            "fallbackUnit": "adapter",
        },
        "adapters": adapters,
        "releaseBakePolicy": {
            "enabledByDefault": False,
            "manualOnly": True,
            "requiresPassingEvalGates": True,
            "allowedWhenRuntimeCannotLoadAdapters": True,
        },
    }
