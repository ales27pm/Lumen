from __future__ import annotations

import re

from lumen_manifest_crawler.manifest import ToolArgumentManifest, ToolManifest
from lumen_manifest_crawler.swift_extractors.base import (
    SwiftExtractor,
    SwiftFile,
    argument_value,
    balanced_call_blocks,
    bool_value,
    clean_swift_string,
    string_literals,
)


class ToolDefinitionExtractor(SwiftExtractor):
    target_names = ("ToolDefinition.swift",)

    def extract(self, file: SwiftFile, manifest) -> None:
        seen: set[str] = {tool.id for tool in manifest.tools}
        for block in balanced_call_blocks(file.text, "ToolDefinition"):
            tool_id = self._extract_tool_id(block)
            if not tool_id or tool_id in seen:
                continue
            seen.add(tool_id)
            manifest.tools.append(
                ToolManifest(
                    id=tool_id,
                    displayName=clean_swift_string(argument_value(block, "displayName"))
                    or clean_swift_string(argument_value(block, "name"))
                    or tool_id,
                    description=clean_swift_string(argument_value(block, "description")),
                    requiresApproval=bool_value(argument_value(block, "requiresApproval"), False),
                    permissionKey=clean_swift_string(argument_value(block, "permissionKey")),
                    arguments=self._extract_arguments(block, file.relpath),
                    source=file.relpath,
                )
            )

        # Fallback for registry literals such as "calendar.create" not wrapped in full ToolDefinition blocks.
        for literal in string_literals(file.text):
            if self._looks_like_tool_id(literal) and literal not in seen:
                seen.add(literal)
                manifest.tools.append(ToolManifest(id=literal, displayName=literal, source=file.relpath))

    def _extract_tool_id(self, block: str) -> str | None:
        for label in ("id", "toolID", "toolId", "identifier"):
            value = clean_swift_string(argument_value(block, label))
            if value and self._looks_like_tool_id(value):
                return value
        literals = [s for s in string_literals(block) if self._looks_like_tool_id(s)]
        return literals[0] if literals else None

    def _extract_arguments(self, block: str, source: str) -> list[ToolArgumentManifest]:
        args: list[ToolArgumentManifest] = []
        seen: set[str] = set()
        for callee in ("ToolArgument", "ToolParameter", "ArgumentDefinition", "ParameterDefinition"):
            for arg_block in balanced_call_blocks(block, callee):
                name = clean_swift_string(argument_value(arg_block, "name")) or self._first_string(arg_block)
                if not name or name in seen:
                    continue
                seen.add(name)
                arg_type = (
                    clean_swift_string(argument_value(arg_block, "type"))
                    or clean_swift_string(argument_value(arg_block, "valueType"))
                    or self._infer_type_from_block(arg_block)
                )
                args.append(
                    ToolArgumentManifest(
                        name=name,
                        type=self._normalize_type(arg_type or "string"),
                        required=not bool_value(argument_value(arg_block, "optional"), False)
                        and bool_value(argument_value(arg_block, "required"), True),
                        description=clean_swift_string(argument_value(arg_block, "description")),
                        source=source,
                    )
                )
        return args

    @staticmethod
    def _first_string(block: str) -> str | None:
        vals = string_literals(block)
        return vals[0] if vals else None

    @staticmethod
    def _infer_type_from_block(block: str) -> str:
        lowered = block.lower()
        if "double" in lowered or "float" in lowered or "number" in lowered:
            return "double"
        if "int" in lowered:
            return "int"
        if "bool" in lowered:
            return "bool"
        if "array" in lowered or "list" in lowered:
            return "array"
        if "object" in lowered or "dictionary" in lowered:
            return "object"
        return "string"

    @staticmethod
    def _normalize_type(raw: str) -> str:
        value = raw.strip().lower().replace(".", "")
        mapping = {
            "str": "string",
            "string": "string",
            "text": "string",
            "double": "double",
            "float": "double",
            "number": "double",
            "int": "int",
            "integer": "int",
            "bool": "bool",
            "boolean": "bool",
            "array": "array",
            "list": "array",
            "object": "object",
            "dictionary": "object",
            "dict": "object",
        }
        return mapping.get(value, value or "string")

    @staticmethod
    def _looks_like_tool_id(value: str) -> bool:
        return bool(re.fullmatch(r"[a-z][a-z0-9]*(?:\.[a-z][a-z0-9]*)+", value))
