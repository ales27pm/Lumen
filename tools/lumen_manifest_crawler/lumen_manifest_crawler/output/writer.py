from __future__ import annotations

import csv
import json
from pathlib import Path
from typing import Any

from lumen_manifest_crawler.manifest import AgentBehaviorManifest, ValidationReport
from lumen_manifest_crawler.output.hashing import sha256_file


def write_outputs(output_dir: Path, manifest: AgentBehaviorManifest, report: ValidationReport, datasets: dict[str, list[dict[str, Any]]], *, pretty: bool) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    canonical_path = output_dir / "AgentBehaviorManifest.json"
    manifest.write_json(canonical_path, pretty=False)
    if pretty:
        manifest.write_json(output_dir / "AgentBehaviorManifest.pretty.json", pretty=True)
    (output_dir / "AgentBehaviorManifest.sha256").write_text(sha256_file(canonical_path) + "\n", encoding="utf-8")
    (output_dir / "manifest_validation_report.json").write_text(report.model_dump_json(indent=2), encoding="utf-8")
    _write_tool_registry_csv(output_dir / "tool_registry.csv", manifest)
    _write_routing_matrix_csv(output_dir / "routing_matrix.csv", manifest)

    dataset_dir = output_dir / "dataset"
    dataset_dir.mkdir(parents=True, exist_ok=True)
    dataset_manifest_records = datasets.get("dataset_manifest", [])
    if len(dataset_manifest_records) > 1:
        raise ValueError(
            f"Expected at most one dataset_manifest record while writing outputs to {output_dir}, "
            f"but got {len(dataset_manifest_records)}. Multiple dataset manifests would make lineage ambiguous."
        )
    if len(dataset_manifest_records) == 1:
        (output_dir / "dataset_manifest.json").write_text(
            json.dumps(dataset_manifest_records[0], ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    _write_dataset_index(output_dir / "dataset_index.csv", datasets)
    for name, records in datasets.items():
        if name == "dataset_manifest":
            continue
        with (dataset_dir / f"{name}.jsonl").open("w", encoding="utf-8") as handle:
            for record in records:
                handle.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")


def _write_dataset_index(path: Path, datasets: dict[str, list[dict[str, Any]]]) -> None:
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["family", "recordCount", "splits", "roles", "taskTypes"])
        for name, records in sorted(datasets.items()):
            if name == "dataset_manifest":
                continue
            splits = sorted({str(record.get("split")) for record in records if record.get("split") is not None})
            roles = sorted({str(record.get("agentRole")) for record in records if record.get("agentRole") is not None})
            task_types = sorted({str(record.get("taskType")) for record in records if record.get("taskType") is not None})
            writer.writerow([name, len(records), ";".join(splits), ";".join(roles), ";".join(task_types)])


def _write_tool_registry_csv(path: Path, manifest: AgentBehaviorManifest) -> None:
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["id", "displayName", "requiresApproval", "permissionKey", "argumentCount", "source"])
        for tool in manifest.tools:
            writer.writerow([tool.id, tool.displayName or "", tool.requiresApproval, tool.permissionKey or "", len(tool.arguments), tool.source or ""])


def _write_routing_matrix_csv(path: Path, manifest: AgentBehaviorManifest) -> None:
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["intent", "allowedTools", "forbiddenTools"])
        for entry in manifest.routingMatrix:
            writer.writerow([entry.intent, ";".join(entry.allowedTools), ";".join(entry.forbiddenTools)])
