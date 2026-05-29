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

DISALLOWED_ENTITLEMENTS = {
    "com.apple.developer.carplay": (
        "CarPlay requires a provisioning profile with the CarPlay entitlement. "
        "Remove the entitlement or use a CarPlay-enabled App Store profile."
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


def read_plist(path: Path) -> dict[str, object]:
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
    args = parser.parse_args(argv)

    failures = [
        *validate_project_settings(args.project_file),
        *validate_entitlements(args.entitlements),
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
