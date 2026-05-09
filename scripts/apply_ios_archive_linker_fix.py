#!/usr/bin/env python3
"""
Patch the Lumen Xcode project with archive-safe Swift/linker settings.

Why this exists
---------------
The app can compile successfully and then fail at the final arm64 link step with
missing Swift specialization symbols and missing system framework metadata symbols.
That failure pattern is consistent with Release whole-module/linker instability or
fragile project source/autolink state, not a normal Swift syntax error.

This script makes the Xcode project itself inherit the same safe settings used by
our stable archive command-line flow, so manual Xcode archives and non-interactive
xcodebuild archives behave consistently.

The script is intentionally conservative:
- no third-party dependencies;
- idempotent output;
- edits only XCBuildConfiguration buildSettings blocks;
- keeps the original pbxproj formatting as much as possible;
- creates a .bak backup unless --no-backup is passed.
"""

from __future__ import annotations

import argparse
import difflib
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


DEFAULT_PROJECT_FILE = Path("ios/Lumen.xcodeproj/project.pbxproj")

# Settings that directly attack the observed Release archive failure:
# - disable Swift whole-module linking specialization pressure;
# - keep optimization but use the lower-risk size optimizer;
# - explicitly embed Swift runtime libraries;
# - avoid aggressive dead stripping while the project uses many Swift/system frameworks.
RELEASE_SETTINGS: dict[str, str] = {
    "ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES": "YES",
    "DEAD_CODE_STRIPPING": "NO",
    "SWIFT_COMPILATION_MODE": "singlefile",
    "SWIFT_OPTIMIZATION_LEVEL": '"-Osize"',
    "SWIFT_WHOLE_MODULE_OPTIMIZATION": "NO",
}

# Useful for Debug too because Xcode can still run package/archive diagnostics from
# Debug-derived settings in some workflows.
DEBUG_SETTINGS: dict[str, str] = {
    "ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES": "YES",
}

RUNPATH_BLOCK = """LD_RUNPATH_SEARCH_PATHS = (\n\t\t\t\t\t\"$(inherited)\",\n\t\t\t\t\t\"@executable_path/Frameworks\",\n\t\t\t\t);"""


@dataclass(frozen=True)
class BuildConfiguration:
    uuid: str
    label: str
    start: int
    end: int
    body: str
    name: str | None


def find_matching_brace(text: str, open_index: int) -> int:
    depth = 0
    in_string = False
    escaped = False

    for index in range(open_index, len(text)):
        char = text[index]
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            continue

        if char == '"':
            in_string = True
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return index

    raise ValueError(f"Unmatched brace at byte offset {open_index}")


def iter_xcbuild_configurations(text: str) -> Iterable[BuildConfiguration]:
    section_match = re.search(
        r"/\* Begin XCBuildConfiguration section \*/(?P<section>.*?)/\* End XCBuildConfiguration section \*/",
        text,
        re.DOTALL,
    )
    if not section_match:
        raise ValueError("Could not find XCBuildConfiguration section in project.pbxproj")

    section_start = section_match.start("section")
    section = section_match.group("section")
    object_pattern = re.compile(
        r"\n\t\t(?P<uuid>[A-F0-9]{24}) /\* (?P<label>[^*]+) \*/ = \{\n\t\t\tisa = XCBuildConfiguration;",
        re.MULTILINE,
    )

    for match in object_pattern.finditer(section):
        absolute_start = section_start + match.start() + 1
        open_brace = text.find("{", absolute_start)
        close_brace = find_matching_brace(text, open_brace)
        absolute_end = close_brace + len(";\n")
        body = text[absolute_start:absolute_end]
        name_match = re.search(r"\n\t\t\tname = (?P<name>[^;]+);", body)
        name = name_match.group("name").strip().strip('"') if name_match else None
        yield BuildConfiguration(
            uuid=match.group("uuid"),
            label=match.group("label"),
            start=absolute_start,
            end=absolute_end,
            body=body,
            name=name,
        )


def find_build_settings_block(configuration_body: str) -> tuple[int, int, str]:
    marker = "\n\t\t\tbuildSettings = {"
    block_start = configuration_body.find(marker)
    if block_start == -1:
        raise ValueError("XCBuildConfiguration object has no buildSettings block")

    open_brace = configuration_body.find("{", block_start)
    close_brace = find_matching_brace(configuration_body, open_brace)
    return open_brace, close_brace, configuration_body[open_brace + 1 : close_brace]


def remove_scalar_setting(settings_body: str, key: str) -> str:
    # Matches common scalar build setting format:
    #     KEY = VALUE;
    return re.sub(rf"\n\t{{4}}{re.escape(key)} = [^;]+;", "", settings_body)


def remove_parenthesized_setting(settings_body: str, key: str) -> str:
    pattern = re.compile(
        rf"\n\t{{4}}{re.escape(key)} = \(.*?\n\t{{4}}\);",
        re.DOTALL,
    )
    return pattern.sub("", settings_body)


def insert_sorted_settings(settings_body: str, scalar_settings: dict[str, str], include_runpath: bool) -> str:
    for key in scalar_settings:
        settings_body = remove_scalar_setting(settings_body, key)

    if include_runpath:
        settings_body = remove_parenthesized_setting(settings_body, "LD_RUNPATH_SEARCH_PATHS")

    additions = [f"\n\t\t\t\t{key} = {value};" for key, value in sorted(scalar_settings.items())]
    if include_runpath:
        additions.append("\n\t\t\t\t" + RUNPATH_BLOCK.replace("\n", "\n"))

    # Insert before the buildSettings closing brace. We keep the rest of the block untouched.
    if settings_body.endswith("\n\t\t\t"):
        return settings_body[: -len("\n\t\t\t")] + "".join(additions) + "\n\t\t\t"
    return settings_body.rstrip() + "".join(additions) + "\n\t\t\t"


def patch_configuration_body(configuration: BuildConfiguration) -> str:
    open_brace, close_brace, settings_body = find_build_settings_block(configuration.body)

    if configuration.name == "Release":
        patched_settings = insert_sorted_settings(
            settings_body,
            RELEASE_SETTINGS,
            include_runpath=True,
        )
    elif configuration.name == "Debug":
        patched_settings = insert_sorted_settings(
            settings_body,
            DEBUG_SETTINGS,
            include_runpath=True,
        )
    else:
        return configuration.body

    return configuration.body[: open_brace + 1] + patched_settings + configuration.body[close_brace:]


def patch_project(text: str) -> tuple[str, int]:
    configurations = list(iter_xcbuild_configurations(text))
    if not configurations:
        raise ValueError("No XCBuildConfiguration objects found")

    replacements: list[tuple[int, int, str]] = []
    changed_count = 0

    for configuration in configurations:
        if configuration.name not in {"Debug", "Release"}:
            continue
        patched_body = patch_configuration_body(configuration)
        if patched_body != configuration.body:
            changed_count += 1
            replacements.append((configuration.start, configuration.end, patched_body))

    patched = text
    for start, end, replacement in sorted(replacements, reverse=True):
        patched = patched[:start] + replacement + patched[end:]

    return patched, changed_count


def main() -> int:
    parser = argparse.ArgumentParser(description="Patch Lumen iOS archive-safe Xcode build settings.")
    parser.add_argument(
        "project_file",
        nargs="?",
        default=str(DEFAULT_PROJECT_FILE),
        help=f"Path to project.pbxproj. Default: {DEFAULT_PROJECT_FILE}",
    )
    parser.add_argument("--check", action="store_true", help="Exit 1 if the file would change.")
    parser.add_argument("--diff", action="store_true", help="Print a unified diff when changes are needed.")
    parser.add_argument("--no-backup", action="store_true", help="Do not write a .bak file before patching.")
    args = parser.parse_args()

    project_file = Path(args.project_file)
    if not project_file.exists():
        print(f"error: project file not found: {project_file}", file=sys.stderr)
        return 2

    original = project_file.read_text(encoding="utf-8")
    patched, changed_count = patch_project(original)

    if patched == original:
        print(f"ok: {project_file} already contains archive-safe linker settings")
        return 0

    if args.diff:
        sys.stdout.writelines(
            difflib.unified_diff(
                original.splitlines(keepends=True),
                patched.splitlines(keepends=True),
                fromfile=f"{project_file} (before)",
                tofile=f"{project_file} (after)",
            )
        )

    if args.check:
        print(
            f"needs-patch: {project_file} would update {changed_count} build configuration block(s)",
            file=sys.stderr,
        )
        return 1

    if not args.no_backup:
        backup_file = project_file.with_suffix(project_file.suffix + ".bak")
        backup_file.write_text(original, encoding="utf-8")
        print(f"backup: {backup_file}")

    project_file.write_text(patched, encoding="utf-8")
    print(f"patched: {project_file} ({changed_count} build configuration block(s))")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
