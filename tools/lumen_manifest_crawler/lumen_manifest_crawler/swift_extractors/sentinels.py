from __future__ import annotations

import re

from lumen_manifest_crawler.swift_extractors.base import SwiftExtractor, SwiftFile, string_literals


DEFAULT_FORBIDDEN = {
    "<user_final_text>",
    "<private_reasoning>",
    "<tool_json>",
    "<internal_state>",
    "<scratchpad>",
    "<hidden_reasoning>",
}


class SentinelExtractor(SwiftExtractor):
    target_names = ("ChatView.swift", "AgentService.swift", "ComposeController.swift")

    def extract(self, file: SwiftFile, manifest) -> None:
        found = set(manifest.sentinels.forbiddenInUserOutput)
        found.update(DEFAULT_FORBIDDEN)
        for literal in string_literals(file.text):
            if re.fullmatch(r"<[A-Za-z0-9_\-]+>", literal):
                found.add(literal)
            lowered = literal.lower()
            if "private_reasoning" in lowered or "scratchpad" in lowered or "internal_state" in lowered:
                found.add(literal)
        manifest.sentinels.forbiddenInUserOutput = sorted(found)
