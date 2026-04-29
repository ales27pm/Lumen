from __future__ import annotations

import re

from lumen_manifest_crawler.swift_extractors.base import SwiftExtractor, SwiftFile, enum_cases


class AgentJSONValueExtractor(SwiftExtractor):
    target_names = ("AgentJSONValue.swift",)

    def extract(self, file: SwiftFile, manifest) -> None:
        cases = set(enum_cases(file.text, "AgentJSONValue"))
        inferred = set()
        text = file.text.lower()
        if "string" in text or "case string" in text:
            inferred.add("string")
        if "double" in text or "float" in text or "number" in text:
            inferred.add("double")
        if "int" in text or "integer" in text:
            inferred.add("int")
        if "bool" in text:
            inferred.add("bool")
        if "array" in text:
            inferred.add("array")
        if "object" in text or "dictionary" in text:
            inferred.add("object")
        supported = sorted(cases.union(inferred))
        if supported:
            manifest.agentProtocols.executorOutput["supportedJSONTypes"] = supported
            manifest.agentProtocols.executorOutput["jsonTypeSource"] = file.relpath
