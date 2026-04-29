from __future__ import annotations

import re

from lumen_manifest_crawler.manifest import FreshnessClassManifest
from lumen_manifest_crawler.swift_extractors.base import SwiftExtractor, SwiftFile, enum_cases, string_literals


class MemoryExtractor(SwiftExtractor):
    target_names = ("MemoryItem.swift", "MemoryStore.swift", "MemoryContextItem.swift")

    def extract(self, file: SwiftFile, manifest) -> None:
        scopes = set(manifest.memory.scopes)
        for enum_name in ("Scope", "MemoryScope", "MemoryContextScope"):
            scopes.update(enum_cases(file.text, enum_name))
        for literal in string_literals(file.text):
            if literal in {"currentTurn", "session", "userPreference", "project", "durableFact", "person", "conversation"}:
                scopes.add(literal)
        manifest.memory.scopes = sorted(scopes)

        existing = {f.id for f in manifest.memory.freshnessClasses}
        freshness_cases = set(enum_cases(file.text, "MemoryFreshnessClass")) | set(enum_cases(file.text, "FreshnessClass"))
        for name in freshness_cases:
            if name not in existing:
                manifest.memory.freshnessClasses.append(
                    FreshnessClassManifest(
                        id=name,
                        ttlSeconds=self._ttl_near(file.text, name),
                        durable=name.lower() in {"durable", "permanent", "pinned"},
                        source=file.relpath,
                    )
                )
                existing.add(name)

        for ttl_name, ttl in self._extract_ttl_constants(file.text):
            if ttl_name not in existing:
                manifest.memory.freshnessClasses.append(
                    FreshnessClassManifest(id=ttl_name, ttlSeconds=ttl, durable=ttl is None, source=file.relpath)
                )
                existing.add(ttl_name)

    @staticmethod
    def _ttl_near(text: str, name: str) -> int | None:
        pattern = "\\b" + re.escape(name) + "\\b"
        match = re.search(pattern, text)
        if not match:
            return None
        window = text[match.start(): min(len(text), match.end() + 500)]
        num = re.search(r"(\d+)\s*(?:seconds|second|minutes|minute|hours|hour|days|day)", window, flags=re.I)
        if not num:
            return None
        value = int(num.group(1))
        unit = re.search(r"\d+\s*([A-Za-z]+)", num.group(0))
        factor = 1
        if unit:
            u = unit.group(1).lower()
            if u.startswith("minute"):
                factor = 60
            elif u.startswith("hour"):
                factor = 3600
            elif u.startswith("day"):
                factor = 86400
        return value * factor

    @staticmethod
    def _extract_ttl_constants(text: str) -> list[tuple[str, int | None]]:
        out: list[tuple[str, int | None]] = []
        for match in re.finditer(r"(ephemeral|session|durable|permanent|project)\w*\s*[=:]\s*(\d+)?", text, flags=re.I):
            raw_name = match.group(1)
            raw_value = match.group(2)
            out.append((raw_name[0].lower() + raw_name[1:], int(raw_value) if raw_value else None))
        return out
