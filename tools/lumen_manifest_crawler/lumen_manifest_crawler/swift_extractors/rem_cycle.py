from __future__ import annotations

from lumen_manifest_crawler.swift_extractors.base import SwiftExtractor, SwiftFile, balanced_call_blocks, string_literals


class RemCycleExtractor(SwiftExtractor):
    target_names = ("RemCycleService.swift", "REMService.swift")

    def extract(self, file: SwiftFile, manifest) -> None:
        report_fields: set[str] = set()
        for struct_name in ("RemCycleReport", "REMReport", "TrainingRecord"):
            for block in balanced_call_blocks(file.text, struct_name):
                report_fields.update(string_literals(block))
        literals = [s for s in string_literals(file.text) if "training" in s.lower() or "reflection" in s.lower() or "memory" in s.lower()]
        if report_fields or literals:
            manifest.agentProtocols.executorOutput["remCycle"] = {
                "reportFields": sorted(report_fields),
                "hints": sorted(dict.fromkeys(literals))[:100],
                "source": file.relpath,
            }
