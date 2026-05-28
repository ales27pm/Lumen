#!/usr/bin/env python3
"""
Create a deterministic single-file text bundle of the Lumen source tree.

Run from the repository root:
    python3 scripts/bundle_lumen_source.py

Default output:
    LUMEN_SOURCE_CODE.txt

The bundle is designed for LLM review, archival, debugging, and code transfer. It
includes a directory tree, per-file metadata, and each selected text source file.
It deliberately excludes secrets, binary assets, build products, dependency
caches, generated datasets, local user state, and model weights.
"""
from __future__ import annotations

import argparse
import dataclasses
import datetime as _dt
import fnmatch
import hashlib
import os
import subprocess
import sys
from pathlib import Path
from typing import Iterator, Sequence


DEFAULT_OUTPUT = "LUMEN_SOURCE_CODE.txt"

DEFAULT_INCLUDE_ROOTS = (
    "ios/Lumen",
    "ios/LumenTests",
    "ios/LumenUITests",
    "scripts",
    "tools/lumen_manifest_crawler/lumen_manifest_crawler",
    "tools/lumen_manifest_crawler/tests",
    ".github/workflows",
)

DEFAULT_ROOT_FILES = (
    "README.md",
    "PLAN.md",
    "Package.swift",
    "Package.resolved",
    "pyproject.toml",
    "requirements.txt",
    "requirements-dev.txt",
    "Makefile",
    ".gitignore",
)

SOURCE_EXTENSIONS = {
    ".swift",
    ".h",
    ".hpp",
    ".c",
    ".cc",
    ".cpp",
    ".m",
    ".mm",
    ".metal",
    ".py",
    ".sh",
    ".bash",
    ".zsh",
    ".rb",
    ".pl",
    ".js",
    ".jsx",
    ".ts",
    ".tsx",
    ".json",
    ".jsonl",
    ".yaml",
    ".yml",
    ".toml",
    ".xml",
    ".plist",
    ".entitlements",
    ".xcconfig",
    ".xcscheme",
    ".pbxproj",
    ".strings",
    ".md",
    ".txt",
    ".csv",
    ".tsv",
}

ALWAYS_INCLUDE_FILENAMES = {
    "Podfile",
    "Gemfile",
    "Fastfile",
    "Matchfile",
    "Deliverfile",
    "Appfile",
    "Cartfile",
    "Makefile",
    "Dockerfile",
    "Brewfile",
}

EXCLUDED_DIR_NAMES = {
    ".git",
    ".github/actions/cache",
    ".build",
    ".swiftpm",
    ".venv",
    "venv",
    "env",
    "__pycache__",
    ".pytest_cache",
    ".mypy_cache",
    ".ruff_cache",
    ".idea",
    ".vscode",
    "DerivedData",
    "build",
    "Build",
    "dist",
    "node_modules",
    "Pods",
    "xcuserdata",
    "Generated",
    "generated",
    "runtime-audits",
    "artifacts",
    "archives",
    "models",
    "ModelCache",
}

SECRET_GLOBS = (
    ".env",
    ".env.*",
    "*.pem",
    "*.p8",
    "*.p12",
    "*.cer",
    "*.crt",
    "*.key",
    "*.mobileprovision",
    "*.provisionprofile",
    "credentials.json",
    "secrets.json",
    "GoogleService-Info.plist",
    "*.xcuserstate",
)

BINARY_EXTENSIONS = {
    ".a",
    ".app",
    ".appex",
    ".bin",
    ".car",
    ".dSYM",
    ".dylib",
    ".framework",
    ".gif",
    ".heic",
    ".icns",
    ".ico",
    ".ipa",
    ".jpeg",
    ".jpg",
    ".mlmodel",
    ".mlmodelc",
    ".mp3",
    ".mp4",
    ".otf",
    ".pdf",
    ".png",
    ".sqlite",
    ".sqlite3",
    ".ttf",
    ".wav",
    ".webp",
    ".xcarchive",
    ".zip",
    ".gz",
    ".tar",
    ".tgz",
    ".7z",
}


@dataclasses.dataclass(frozen=True)
class BundleFile:
    path: Path
    relative: str
    size: int
    sha256: str
    text: str


@dataclasses.dataclass(frozen=True)
class SkippedFile:
    relative: str
    reason: str
    size: int | None = None


@dataclasses.dataclass(frozen=True)
class BundleResult:
    files: list[BundleFile]
    skipped: list[SkippedFile]


def repo_root_from(start: Path) -> Path:
    current = start.resolve()
    for candidate in (current, *current.parents):
        if (candidate / ".git").exists() or (candidate / "ios" / "Lumen").exists():
            return candidate
    raise SystemExit("Could not find Lumen repository root. Run this from inside the repo.")


def posix(path: Path) -> str:
    return path.as_posix()


def git_value(root: Path, args: Sequence[str]) -> str:
    try:
        completed = subprocess.run(
            ["git", *args],
            cwd=root,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        return "unknown"
    value = completed.stdout.strip()
    return value or "unknown"


def is_secret_path(rel: str) -> bool:
    name = Path(rel).name
    return any(fnmatch.fnmatch(name, pattern) or fnmatch.fnmatch(rel, pattern) for pattern in SECRET_GLOBS)


def has_excluded_dir(rel: str, extra_excluded_dirs: set[str]) -> bool:
    parts = Path(rel).parts
    excluded = EXCLUDED_DIR_NAMES | extra_excluded_dirs
    return any(part in excluded for part in parts)


def is_candidate_text_file(path: Path, include_all_text: bool) -> bool:
    if path.name in ALWAYS_INCLUDE_FILENAMES:
        return True
    if path.suffix in SOURCE_EXTENSIONS:
        return True
    if include_all_text and path.suffix not in BINARY_EXTENSIONS:
        return True
    return False


def iter_candidate_paths(
    root: Path,
    include_roots: Sequence[str],
    root_files: Sequence[str],
    include_all_text: bool,
    include_docs: bool,
    extra_excluded_dirs: set[str],
) -> Iterator[Path]:
    seen: set[Path] = set()
    roots = list(include_roots)
    if include_docs:
        roots.append("docs")

    for root_file in root_files:
        path = (root / root_file).resolve()
        if path.exists() and path.is_file() and path not in seen:
            seen.add(path)
            yield path

    for raw_rel_root in roots:
        source_root = (root / raw_rel_root).resolve()
        if not source_root.exists():
            continue
        if source_root.is_file():
            if source_root not in seen:
                seen.add(source_root)
                yield source_root
            continue
        for current, dirs, files in os.walk(source_root):
            current_path = Path(current)
            rel_current = posix(current_path.relative_to(root))
            dirs[:] = sorted(
                d for d in dirs
                if not has_excluded_dir(posix((current_path / d).relative_to(root)), extra_excluded_dirs)
            )
            if has_excluded_dir(rel_current, extra_excluded_dirs):
                continue
            for file_name in sorted(files):
                path = current_path / file_name
                try:
                    resolved = path.resolve()
                except OSError:
                    continue
                if resolved in seen:
                    continue
                if is_candidate_text_file(resolved, include_all_text):
                    seen.add(resolved)
                    yield resolved


def decode_text(data: bytes) -> tuple[str | None, str | None]:
    if b"\x00" in data[:8192]:
        return None, "binary null byte"
    for encoding in ("utf-8", "utf-8-sig"):
        try:
            return data.decode(encoding), None
        except UnicodeDecodeError:
            pass
    try:
        return data.decode("latin-1"), None
    except UnicodeDecodeError as exc:
        return None, f"decode failed: {exc}"


def collect_files(
    root: Path,
    include_roots: Sequence[str],
    root_files: Sequence[str],
    include_all_text: bool,
    include_docs: bool,
    max_file_bytes: int,
    extra_excluded_dirs: set[str],
) -> BundleResult:
    included: list[BundleFile] = []
    skipped: list[SkippedFile] = []

    for path in sorted(
        iter_candidate_paths(root, include_roots, root_files, include_all_text, include_docs, extra_excluded_dirs),
        key=lambda p: posix(p.relative_to(root)).lower(),
    ):
        rel = posix(path.relative_to(root))
        try:
            stat = path.stat()
        except OSError as exc:
            skipped.append(SkippedFile(rel, f"stat failed: {exc}"))
            continue

        if is_secret_path(rel):
            skipped.append(SkippedFile(rel, "secret/credential path", stat.st_size))
            continue
        if path.suffix in BINARY_EXTENSIONS:
            skipped.append(SkippedFile(rel, "binary extension", stat.st_size))
            continue
        if stat.st_size > max_file_bytes:
            skipped.append(SkippedFile(rel, f"larger than max_file_bytes={max_file_bytes}", stat.st_size))
            continue

        try:
            data = path.read_bytes()
        except OSError as exc:
            skipped.append(SkippedFile(rel, f"read failed: {exc}", stat.st_size))
            continue

        text, reason = decode_text(data)
        if text is None:
            skipped.append(SkippedFile(rel, reason or "not text", stat.st_size))
            continue

        included.append(BundleFile(
            path=path,
            relative=rel,
            size=stat.st_size,
            sha256=hashlib.sha256(data).hexdigest(),
            text=text.replace("\r\n", "\n").replace("\r", "\n"),
        ))

    return BundleResult(included, skipped)


def render_tree(files: Sequence[BundleFile]) -> str:
    lines: list[str] = []
    previous_dirs: tuple[str, ...] = ()
    for item in files:
        parts = Path(item.relative).parts
        dirs = parts[:-1]
        for depth, directory in enumerate(dirs):
            prefix = "  " * depth
            if len(previous_dirs) <= depth or previous_dirs[depth] != directory or previous_dirs[:depth] != dirs[:depth]:
                lines.append(f"{prefix}{directory}/")
        lines.append(f"{'  ' * len(dirs)}{parts[-1]}")
        previous_dirs = dirs
    return "\n".join(lines)


def language_hint(path: str) -> str:
    suffix = Path(path).suffix.lower()
    mapping = {
        ".swift": "swift",
        ".py": "python",
        ".sh": "shell",
        ".bash": "shell",
        ".zsh": "shell",
        ".rb": "ruby",
        ".js": "javascript",
        ".jsx": "javascript",
        ".ts": "typescript",
        ".tsx": "typescript",
        ".json": "json",
        ".jsonl": "jsonl",
        ".yaml": "yaml",
        ".yml": "yaml",
        ".toml": "toml",
        ".xml": "xml",
        ".plist": "xml",
        ".md": "markdown",
        ".txt": "text",
        ".c": "c",
        ".cc": "cpp",
        ".cpp": "cpp",
        ".h": "c-header",
        ".hpp": "cpp-header",
        ".m": "objective-c",
        ".mm": "objective-cpp",
        ".metal": "metal",
        ".pbxproj": "xcodeproj",
    }
    if Path(path).name == "Podfile":
        return "ruby"
    return mapping.get(suffix, "text")


def render_bundle(root: Path, result: BundleResult, args: argparse.Namespace) -> str:
    now = _dt.datetime.now(_dt.timezone.utc).replace(microsecond=0).isoformat()
    commit = git_value(root, ["rev-parse", "HEAD"])
    branch = git_value(root, ["branch", "--show-current"])
    status = git_value(root, ["status", "--short"])
    dirty = "clean" if status == "unknown" or not status else "dirty"
    total_bytes = sum(item.size for item in result.files)

    lines: list[str] = [
        "LUMEN SOURCE CODE BUNDLE",
        "=" * 80,
        f"Generated UTC: {now}",
        f"Repository root: {root}",
        f"Git branch: {branch}",
        f"Git commit: {commit}",
        f"Git worktree: {dirty}",
        f"Included files: {len(result.files)}",
        f"Included bytes: {total_bytes}",
        f"Skipped files: {len(result.skipped)}",
        f"Max file bytes: {args.max_file_bytes}",
        f"Include all text: {args.all_text}",
        f"Include docs: {args.include_docs}",
        "",
        "INCLUDED ROOTS",
        "-" * 80,
        *(f"- {root_item}" for root_item in args.include_root),
    ]

    if args.include_docs:
        lines.append("- docs")

    lines.extend([
        "",
        "DIRECTORY TREE",
        "-" * 80,
        render_tree(result.files) or "<empty>",
        "",
        "SKIPPED FILES",
        "-" * 80,
    ])

    if result.skipped:
        for skipped in sorted(result.skipped, key=lambda item: item.relative.lower()):
            size = "unknown" if skipped.size is None else str(skipped.size)
            lines.append(f"- {skipped.relative} | {skipped.reason} | bytes={size}")
    else:
        lines.append("<none>")

    lines.extend([
        "",
        "FILE CONTENTS",
        "=" * 80,
    ])

    for item in result.files:
        lines.extend([
            "",
            "=" * 80,
            f"FILE: {item.relative}",
            f"LANGUAGE: {language_hint(item.relative)}",
            f"BYTES: {item.size}",
            f"SHA256: {item.sha256}",
            "-" * 80,
            item.text.rstrip("\n"),
        ])

    lines.append("")
    return "\n".join(lines)


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Bundle Lumen source code into one deterministic .txt file.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--output", default=DEFAULT_OUTPUT, help="Output .txt file path, relative to repo root unless absolute.")
    parser.add_argument(
        "--include-root",
        action="append",
        default=list(DEFAULT_INCLUDE_ROOTS),
        help="Directory or file to include. Can be passed multiple times.",
    )
    parser.add_argument(
        "--root-file",
        action="append",
        default=list(DEFAULT_ROOT_FILES),
        help="Top-level file to include when present. Can be passed multiple times.",
    )
    parser.add_argument("--include-docs", action="store_true", help="Also include docs/ text files.")
    parser.add_argument("--all-text", action="store_true", help="Include any decodable non-binary text file under selected roots.")
    parser.add_argument("--max-file-bytes", type=int, default=1_500_000, help="Skip individual files larger than this.")
    parser.add_argument(
        "--exclude-dir",
        action="append",
        default=[],
        help="Additional directory name to exclude anywhere in a path. Can be passed multiple times.",
    )
    parser.add_argument("--quiet", action="store_true", help="Only print the output path.")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    root = repo_root_from(Path.cwd())
    output = Path(args.output)
    if not output.is_absolute():
        output = root / output

    result = collect_files(
        root=root,
        include_roots=args.include_root,
        root_files=args.root_file,
        include_all_text=args.all_text,
        include_docs=args.include_docs,
        max_file_bytes=args.max_file_bytes,
        extra_excluded_dirs=set(args.exclude_dir),
    )
    text = render_bundle(root, result, args)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(text, encoding="utf-8", newline="\n")

    if args.quiet:
        print(output)
    else:
        print(f"Wrote {output}")
        print(f"Included {len(result.files)} files; skipped {len(result.skipped)} files.")
        print("Run with --include-docs or --all-text if you want a wider bundle.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
