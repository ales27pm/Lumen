#!/usr/bin/env python3
"""Patch generated Info.plist build settings for MSAL iOS broker callback support.

Lumen uses GENERATE_INFOPLIST_FILE=YES, so there is no checked-in Info.plist to edit.
The app target stores generated plist entries as INFOPLIST_KEY_* build settings in
`ios/Lumen.xcodeproj/project.pbxproj`.

This script inserts the required MSAL URL scheme and broker query schemes into the
Lumen target Debug/Release build settings idempotently.
"""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "ios" / "Lumen.xcodeproj" / "project.pbxproj"

URL_TYPES = '''\t\t\t\tINFOPLIST_KEY_CFBundleURLTypes = (
\t\t\t\t\t{
\t\t\t\t\t\tCFBundleURLName = "com.27pm.lumen";
\t\t\t\t\t\tCFBundleURLSchemes = (
\t\t\t\t\t\t\t"msauth.com.27pm.lumen",
\t\t\t\t\t\t);
\t\t\t\t\t},
\t\t\t\t);
'''

QUERY_SCHEMES = '''\t\t\t\tINFOPLIST_KEY_LSApplicationQueriesSchemes = (
\t\t\t\t\tmsauth,
\t\t\t\t\tmsauthv2,
\t\t\t\t\tmsauthv3,
\t\t\t\t);
'''

TARGET_CONFIG_IDS = (
    "105FC59E2E9EAD3200EA8BCF",  # Lumen Debug
    "105FC59F2E9EAD3200EA8BCF",  # Lumen Release
)


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
    raise RuntimeError("Could not find matching brace")


def replace_or_insert_setting(block: str, key: str, value: str) -> str:
    needle = f"\t\t\t\t{key} = "
    existing = block.find(needle)
    if existing >= 0:
        value_start = existing
        cursor = existing + len(needle)
        depth = 0
        in_string = False
        escaped = False
        while cursor < len(block):
            char = block[cursor]
            if in_string:
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == '"':
                    in_string = False
            else:
                if char == '"':
                    in_string = True
                elif char in "({":
                    depth += 1
                elif char in ")}":
                    depth -= 1
                elif char == ";" and depth == 0:
                    return block[:value_start] + value + block[cursor + 2 :]
            cursor += 1
        raise RuntimeError(f"Could not replace existing {key}")

    marker = "\t\t\t\tINFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO;\n"
    if marker not in block:
        raise RuntimeError(f"Could not find insertion marker for {key}")
    return block.replace(marker, value + marker, 1)


def patch_config(text: str, config_id: str) -> str:
    marker = f"\t\t{config_id} /* "
    config_start = text.find(marker)
    if config_start < 0:
        raise RuntimeError(f"Missing build configuration {config_id}")
    open_index = text.find("{", config_start)
    close_index = find_matching_brace(text, open_index)
    block = text[open_index : close_index + 1]
    block = replace_or_insert_setting(block, "INFOPLIST_KEY_CFBundleURLTypes", URL_TYPES)
    block = replace_or_insert_setting(block, "INFOPLIST_KEY_LSApplicationQueriesSchemes", QUERY_SCHEMES)
    return text[:open_index] + block + text[close_index + 1 :]


def main() -> None:
    text = PROJECT.read_text(encoding="utf-8")
    original = text
    for config_id in TARGET_CONFIG_IDS:
        text = patch_config(text, config_id)

    if text != original:
        PROJECT.write_text(text, encoding="utf-8")
        print(f"Patched {PROJECT}")
    else:
        print(f"Already patched: {PROJECT}")

    for required in [
        'INFOPLIST_KEY_CFBundleURLTypes',
        '"msauth.com.27pm.lumen"',
        'INFOPLIST_KEY_LSApplicationQueriesSchemes',
        'msauthv2',
        'msauthv3',
    ]:
        if required not in text:
            raise SystemExit(f"Patch failed; missing {required}")


if __name__ == "__main__":
    main()
