#!/usr/bin/env python3
"""Validate iOS signing capabilities expected by App Store profiles.

This static guard catches capabilities that require special provisioning-profile
approval before Xcode reaches the archive signing phase.
"""
from __future__ import annotations

import argparse
import plistlib
import sys
from pathlib import Path
from typing import Any

# The approved voice-based conversational CarPlay capability uses the category-
# specific entitlement below. Keep rejecting the legacy/generic CarPlay key because
# it is the one Xcode reports when a stale provisioning profile was generated
# before Apple attached the approved CarPlay capability to the App ID.
APPROVED_CARPLAY_ENTITLEMENTS = {
    "com.apple.developer.carplay-voice-based-conversation",
}

DISALLOWED_ENTITLEMENTS = {
    "com.apple.developer.carplay": (
        "Use the approved category-specific CarPlay entitlement "
        "'com.apple.developer.carplay-voice-based-conversation' and archive with "
        "a freshly regenerated CarPlay-enabled App Store provisioning profile."
    ),
}

DISALLOWED_PROJECT_SETTINGS = {
    "INFOPLIST_KEY_UIApplicationSupportsCarPlay": (
        "UIApplicationSupportsCarPlay causes Xcode/App Store signing to expect "
        "CarPlay capability support. Remove it unless the profile is enabled for CarPlay."
    ),
}


def repo_root_from_script() -> Path:
    return Path(__file__).resolve().parents[1]


def read_plist(path: Path) -> dict[str, Any]:
    try:
        with path.open("rb") as handle:
            value = plistlib.load(handle)
    except FileNotFoundError:
        raise SystemExit(f"error: missing entitlements file: {path}")
    except plistlib.InvalidFileException as exc:
        raise SystemExit(f"error: invalid plist in {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise SystemExit(f"error: expected plist dictionary in {path}")
    return value


def sanitized_entitlements(entitlements: dict[str, Any]) -> tuple[dict[str, Any], list[str]]:
    """Return entitlements with App-Store-profile-incompatible keys removed."""
    sanitized = dict(entitlements)
    removed: list[str] = []
    for key in DISALLOWED_ENTITLEMENTS:
        if key in sanitized:
            sanitized.pop(key)
            removed.append(key)
    return sanitized, removed


def write_plist(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as handle:
        plistlib.dump(value, handle, sort_keys=False)


def sanitize_entitlements_file(source: Path, destination: Path) -> list[str]:
    entitlements = read_plist(source)
    sanitized, removed = sanitized_entitlements(entitlements)
    write_plist(destination, sanitized)
    return removed


def validate_entitlements(path: Path) -> list[str]:
    entitlements = read_plist(path)
    failures: list[str] = []
    for key, message in DISALLOWED_ENTITLEMENTS.items():
        if key in entitlements:
            failures.append(f"{path}: disallowed entitlement '{key}'. {message}")
    return failures


def validate_project_settings(path: Path) -> list[str]:
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        raise SystemExit(f"error: missing Xcode project file: {path}")
    failures: list[str] = []
    lines = text.splitlines()
    for token, message in DISALLOWED_PROJECT_SETTINGS.items():
        for index, line in enumerate(lines, start=1):
            if token in line:
                failures.append(f"{path}:{index}: disallowed build setting '{token}'. {message}")
    return failures


def main(argv: list[str] | None = None) -> int:
    root = repo_root_from_script()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--project-file",
        type=Path,
        default=root / "ios" / "Lumen.xcodeproj" / "project.pbxproj",
        help="Path to project.pbxproj (default: ios/Lumen.xcodeproj/project.pbxproj)",
    )
    parser.add_argument(
        "--entitlements",
        type=Path,
        default=root / "ios" / "Lumen" / "Lumen.entitlements",
        help="Path to app entitlements plist (default: ios/Lumen/Lumen.entitlements)",
    )
    parser.add_argument(
        "--sanitized-entitlements-output",
        type=Path,
        help=(
            "Write a copy of --entitlements with App Store profile-incompatible "
            "entitlements removed. Validation still fails unless --allow-sanitized-output is set."
        ),
    )
    parser.add_argument(
        "--allow-sanitized-output",
        action="store_true",
        help="Allow disallowed entitlements when they are removed into --sanitized-entitlements-output.",
    )
    args = parser.parse_args(argv)

    entitlement_failures = validate_entitlements(args.entitlements)
    removed: list[str] = []
    if args.sanitized_entitlements_output:
        removed = sanitize_entitlements_file(args.entitlements, args.sanitized_entitlements_output)
        if removed:
            print(
                "Wrote sanitized entitlements without disallowed keys "
                f"{', '.join(removed)}: {args.sanitized_entitlements_output}",
                file=sys.stderr,
            )

    failures = [
        *validate_project_settings(args.project_file),
        *([] if args.allow_sanitized_output and args.sanitized_entitlements_output else entitlement_failures),
    ]
    if failures:
        print("iOS signing capability validation failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1

    print("iOS signing capability validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
