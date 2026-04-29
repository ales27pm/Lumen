from __future__ import annotations

import logging
import subprocess
from pathlib import Path

from lumen_manifest_crawler.manifest import AgentBehaviorManifest, AppManifestInfo, RoutingMatrixEntry, SourceFileHash
from lumen_manifest_crawler.output.hashing import normalized_repo_path, sha256_file
from lumen_manifest_crawler.swift_extractors import ALL_EXTRACTORS
from lumen_manifest_crawler.swift_extractors.base import SwiftFile

logger = logging.getLogger(__name__)

IGNORED_DIRS = {
    ".git",
    ".build",
    ".swiftpm",
    "DerivedData",
    "Pods",
    "node_modules",
    ".expo",
    ".next",
    "build",
    "dist",
    "generated",
}
IGNORED_PLIST_DIRS = IGNORED_DIRS | {"Tests", "UITests", "UnitTests", "Fixtures", "fixtures"}


def generate_manifest(root: Path) -> AgentBehaviorManifest:
    root = _validated_scan_root(root)
    manifest = AgentBehaviorManifest(app=_read_app_info(root))
    manifest.sourceIntegrity.commit = _git_commit(root)

    swift_files = list(_iter_swift_files(root))
    manifest.sourceIntegrity.files = [
        SourceFileHash(path=normalized_repo_path(root, path), sha256=sha256_file(path))
        for path in swift_files
        if _is_source_of_truth_file(path)
    ]

    for path in swift_files:
        rel = normalized_repo_path(root, path)
        swift_file = SwiftFile(path=path, relpath=rel, text=path.read_text(encoding="utf-8", errors="replace"))
        for extractor in ALL_EXTRACTORS:
            if extractor.accepts(swift_file):
                extractor.extract(swift_file, manifest)

    _finalize_defaults(manifest)
    return manifest


def _validated_scan_root(root: Path) -> Path:
    resolved = root.resolve()
    if resolved == resolved.anchor:
        raise ValueError(
            "Refusing to scan the filesystem root. Pass the repository root explicitly, "
            "for example: --root /content/Lumen"
        )
    if not resolved.exists():
        raise ValueError(f"Manifest crawler root does not exist: {resolved}")
    if not resolved.is_dir():
        raise ValueError(f"Manifest crawler root is not a directory: {resolved}")
    return resolved


def _iter_swift_files(root: Path):
    for path in sorted(root.rglob("*.swift"), key=lambda candidate: normalized_repo_path(root, candidate)):
        parts = set(path.relative_to(root).parts)
        if parts.intersection(IGNORED_DIRS):
            continue
        yield path


def _is_source_of_truth_file(path: Path) -> bool:
    return path.name in {
        "ModelFleet.swift",
        "IntentRouter.swift",
        "ToolDefinition.swift",
        "AgentJSONValue.swift",
        "MimicryProfile.swift",
        "RemCycleService.swift",
        "MemoryItem.swift",
        "MemoryStore.swift",
        "MemoryContextItem.swift",
        "ChatView.swift",
        "AgentService.swift",
        "Trigger.swift",
        "AlarmTools.swift",
    }


def _git_commit(root: Path) -> str | None:
    try:
        completed = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
            timeout=5,
        )
        return completed.stdout.strip() or None
    except subprocess.CalledProcessError as error:
        logger.debug(
            "git rev-parse HEAD failed in _git_commit: returncode=%s stdout=%r stderr=%r",
            error.returncode,
            error.stdout,
            error.stderr,
        )
        return None
    except Exception as error:
        logger.debug("git rev-parse HEAD failed in _git_commit: %s", error, exc_info=True)
        return None


def _read_app_info(root: Path) -> AppManifestInfo:
    selected = _select_info_plist(root)
    if not selected:
        return AppManifestInfo(name="Lumen")
    text = selected.read_text(encoding="utf-8", errors="replace")
    return AppManifestInfo(
        name="Lumen",
        bundleIdentifier=_plist_value_after_key(text, "CFBundleIdentifier"),
        buildVersion=_plist_value_after_key(text, "CFBundleShortVersionString"),
    )


def _select_info_plist(root: Path) -> Path | None:
    candidates: list[Path] = []
    for plist in sorted(root.rglob("Info.plist"), key=lambda candidate: normalized_repo_path(root, candidate)):
        parts = set(plist.relative_to(root).parts)
        if parts.intersection(IGNORED_PLIST_DIRS):
            continue
        text = plist.read_text(encoding="utf-8", errors="replace")
        if "CFBundleIdentifier" in text:
            candidates.append(plist)
    if not candidates:
        return None
    preferred = [plist for plist in candidates if any(part in {"Lumen", "ios"} for part in plist.relative_to(root).parts)]
    return (preferred or candidates)[0]


def _plist_value_after_key(text: str, key: str) -> str | None:
    marker = f"<key>{key}</key>"
    index = text.find(marker)
    if index == -1:
        return None
    rest = text[index + len(marker): index + len(marker) + 400]
    start = rest.find("<string>")
    end = rest.find("</string>")
    if start == -1 or end == -1 or end <= start:
        return None
    return rest[start + len("<string>"):end].strip()


def _finalize_defaults(manifest: AgentBehaviorManifest) -> None:
    if not manifest.sentinels.forbiddenInUserOutput:
        manifest.sentinels.forbiddenInUserOutput = sorted({
            "<user_final_text>",
            "<private_reasoning>",
            "<tool_json>",
            "<internal_state>",
            "<scratchpad>",
            "<hidden_reasoning>",
        })
    if not manifest.agentProtocols.executorOutput.get("supportedJSONTypes"):
        manifest.agentProtocols.executorOutput["supportedJSONTypes"] = ["string", "double", "int", "bool", "array", "object", "null"]

    known_tools = sorted({tool.id for tool in manifest.tools})
    if manifest.intents and not manifest.routingMatrix:
        manifest.routingMatrix = [
            RoutingMatrixEntry(
                intent=intent.id,
                allowedTools=sorted(intent.allowedToolIDs),
                forbiddenTools=[tool_id for tool_id in known_tools if tool_id not in intent.allowedToolIDs][:25],
            )
            for intent in manifest.intents
        ]
