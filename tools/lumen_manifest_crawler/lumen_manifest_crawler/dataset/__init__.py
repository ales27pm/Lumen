from __future__ import annotations

from pathlib import Path
from typing import Any

from lumen_manifest_crawler.dataset.compiler import DatasetCompilerConfig, compile_state_of_art_datasets, load_runtime_audit_reports
from lumen_manifest_crawler.dataset.cortex import generate_cortex_records
from lumen_manifest_crawler.dataset.executor import generate_approval_boundary_records, generate_executor_records, generate_negative_samples
from lumen_manifest_crawler.dataset.mimicry import generate_mimicry_records
from lumen_manifest_crawler.dataset.mouth import generate_mouth_records
from lumen_manifest_crawler.dataset.rem import generate_rem_records
from lumen_manifest_crawler.manifest import AgentBehaviorManifest


def generate_role_datasets(manifest: AgentBehaviorManifest) -> dict[str, list[dict[str, Any]]]:
    return {
        "cortex_routing": generate_cortex_records(manifest),
        "executor_tool_calls": generate_executor_records(manifest),
        "mouth_responses": generate_mouth_records(manifest),
        "mimicry_style": generate_mimicry_records(manifest),
        "rem_reflection": generate_rem_records(manifest),
        "negative_samples": generate_negative_samples(manifest),
        "approval_boundary_samples": generate_approval_boundary_records(manifest),
    }


def generate_all_datasets(
    manifest: AgentBehaviorManifest,
    *,
    runtime_audit_paths: list[Path] | None = None,
    deterministic: bool = True,
) -> dict[str, list[dict[str, Any]]]:
    role_records = generate_role_datasets(manifest)
    runtime_audit_reports = load_runtime_audit_reports(runtime_audit_paths)
    compiled = compile_state_of_art_datasets(
        manifest,
        role_records,
        runtime_audit_reports=runtime_audit_reports,
        config=DatasetCompilerConfig(deterministic=deterministic),
    )
    return {
        **role_records,
        **compiled.records,
        "dataset_manifest": [compiled.manifest],
    }
