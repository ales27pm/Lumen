from __future__ import annotations

import re

from lumen_manifest_crawler.manifest import IntentManifest, RoutingMatrixEntry
from lumen_manifest_crawler.swift_extractors.base import SwiftExtractor, SwiftFile, enum_cases, string_literals


class IntentRouterExtractor(SwiftExtractor):
    target_names = ("IntentRouter.swift",)

    def extract(self, file: SwiftFile, manifest) -> None:
        intent_ids = set(enum_cases(file.text, "UserIntent"))
        existing = {i.id for i in manifest.intents}
        for intent_id in sorted(intent_ids):
            if intent_id not in existing:
                manifest.intents.append(IntentManifest(id=intent_id, source=file.relpath))

        known_tool_ids = {t.id for t in manifest.tools}
        for intent in manifest.intents:
            if intent.id not in intent_ids:
                continue
            allowed = self._tools_near_name(file.text, intent.id, known_tool_ids)
            if allowed:
                intent.allowedToolIDs = sorted(set(intent.allowedToolIDs).union(allowed))

        known_tools = sorted({t.id for t in manifest.tools})
        manifest.routingMatrix = [
            RoutingMatrixEntry(
                intent=intent.id,
                allowedTools=sorted(intent.allowedToolIDs),
                forbiddenTools=[tool_id for tool_id in known_tools if tool_id not in intent.allowedToolIDs][:25],
            )
            for intent in manifest.intents
        ]

    @staticmethod
    def _tools_near_name(text: str, name: str, known_tool_ids: set[str]) -> list[str]:
        allowed: set[str] = set()
        pattern = "\\b" + re.escape(name) + "\\b"
        for match in re.finditer(pattern, text):
            window = text[max(0, match.start() - 500): min(len(text), match.end() + 900)]
            for literal in string_literals(window):
                if literal in known_tool_ids:
                    allowed.add(literal)
        return sorted(allowed)
