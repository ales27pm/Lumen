#!/usr/bin/env python3
"""Static drift guard for Lumen's Qwen3 adapter runtime.

This script intentionally avoids importing app modules. It scans source files for
architecture invariants that must remain true after the Qwen3 shared-base + LoRA
adapter migration.

It is not a replacement for Xcode/device validation. It is a fast guard against
regressing to the slow five-full-GGUF runtime shape.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

MODEL_FAMILY_SELECTION = ROOT / "ios/Lumen/Services/ModelFamilySelection.swift"
MODEL_FLEET = ROOT / "ios/Lumen/Services/ModelFleet.swift"
LLAMA_SERVICE = ROOT / "ios/Lumen/Services/LlamaService.swift"
SLOT_COORDINATOR = ROOT / "ios/Lumen/Services/SlotModelRuntimeCoordinator.swift"
MODELS_VIEW = ROOT / "ios/Lumen/Views/ModelsView.swift"
EXPORT_GGUF = ROOT / "tools/fine_tuning/unsloth/export_gguf.py"
DOC = ROOT / "docs/ADAPTER_RUNTIME_IMPROVE_LOOP.md"

EXPECTED_ADAPTERS = {
    "lumen-cortex-lora.gguf",
    "lumen-executor-lora.gguf",
    "lumen-mouth-lora.gguf",
    "lumen-mimicry-lora.gguf",
    "lumen-rem-lora.gguf",
    "lumen-fleet-lora.gguf",
}

RELEASE_BAKE_DEFAULTS = {
    "lumen-cortex-release-bake-q4_k_m.gguf",
    "lumen-executor-release-bake-q4_k_m.gguf",
    "lumen-mouth-release-bake-q4_k_m.gguf",
    "lumen-mimicry-release-bake-q4_k_m.gguf",
    "lumen-rem-release-bake-q4_k_m.gguf",
}


def read(path: Path) -> str:
    if not path.exists():
        fail(f"missing required file: {path.relative_to(ROOT)}")
    return path.read_text(encoding="utf-8")


def fail(message: str) -> None:
    raise AssertionError(message)


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


def section_after_marker(text: str, marker: str) -> str:
    index = text.find(marker)
    require(index >= 0, f"missing marker: {marker}")
    return text[index:]


def check_catalog() -> None:
    text = read(MODEL_FAMILY_SELECTION)
    qwen3 = section_after_marker(text, "static var qwen3BootstrapModels")

    require(
        qwen3.count("lumen-qwen3-fast-shared-q4_k_m.gguf") == 1,
        "Qwen3 default catalog must contain exactly one shared chat base filename.",
    )
    for adapter in sorted(EXPECTED_ADAPTERS):
        require(adapter in qwen3, f"Qwen3 default catalog missing adapter: {adapter}")
    for release_bake in sorted(RELEASE_BAKE_DEFAULTS):
        require(
            release_bake not in qwen3,
            f"Qwen3 default catalog must not include release-bake artifact: {release_bake}",
        )
    require(
        "lumen-fleet-lora.gguf" in qwen3 and "roleID" in qwen3,
        "Fleet adapter must be represented as a role adapter, not by abusing embedding slot metadata.",
    )


def check_fleet_resolver() -> None:
    text = read(MODEL_FLEET)
    require(
        "fallbackFamily: LumenModelFamily? = selectedFamily == .qwen3 ? nil : selectedFamily" in text,
        "Qwen3 fallback path must not label non-Qwen3 fallback assignments as Qwen3.",
    )
    require(
        "if text.contains(slotToken) { return (model, 2) }" in text,
        "Adapter ranking must prefer exact role adapter matches.",
    )
    require(
        "if slot == .cortex, text.contains(\"fleet\") { return (model, 1) }" in text,
        "Fleet adapter fallback must rank below exact cortex adapter matches.",
    )


def check_runtime() -> None:
    text = read(LLAMA_SERVICE)
    require("private actor AdapterChatRuntime" in text, "AdapterChatRuntime must remain actor-isolated.")
    require("clearAdapters()" in text and "context.apply(loraAdapter: adapter, scale: scale)" in text, "Adapter activation must clear before applying LoRA.")
    require("let isLast = index == lastIndex" in text, "Prompt decode must mark the final prompt token for logits.")
    require("outputTokenCount: nil" in text, "outputTokenCount must stay nil unless real token counts are threaded through.")
    require("sanitized.split(whereSeparator: { $0.isWhitespace }).count" not in text, "Do not report whitespace word count as outputTokenCount.")
    require("adapterApplied" in text and "adapterSlot" in text, "Runtime trace metadata must include adapterApplied and adapterSlot.")


def check_slot_coordinator() -> None:
    text = read(SLOT_COORDINATOR)
    adapter_section_match = re.search(r"private func ensureAdapterRuntimeReady[\s\S]+?private func ensureLegacyRuntimeReady", text)
    require(adapter_section_match is not None, "Missing ensureAdapterRuntimeReady/ensureLegacyRuntimeReady split.")
    adapter_section = adapter_section_match.group(0)
    require("unloadAllChat" not in adapter_section, "Qwen3 adapter slot switch must not call unloadAllChat().")
    require("unloadRoleAdapter(slot: slot)" in adapter_section, "Failed role adapter activation must unload the failed adapter handle.")


def check_models_view() -> None:
    text = read(MODELS_VIEW)
    require("isAdapter: sm.modelRole == .roleAdapter" in text, "Downloaded model rows must know when a row is a role adapter.")
    require("catalog.role == .roleAdapter" in text, "Featured model cards must treat role adapters as non-activatable adapter artifacts.")
    require("stored.modelRole != .roleAdapter" in text, "Stored role adapters must not be activatable as chat/embedding models.")


def check_export_policy() -> None:
    text = read(EXPORT_GGUF)
    require("--release-bake" in text, "export_gguf.py must require explicit --release-bake for merged GGUF export.")
    require("Skipped GGUF release bake by default" in text, "export_gguf.py must skip release-bake by default.")
    require("merge_adapters_by_default") in text if False else None
    require("merge_adapters_by_default" in text and "release_bake_enabled_by_default" in text, "export_gguf.py must validate adapter-first config flags.")


def check_docs() -> None:
    text = read(DOC)
    require("Non-negotiable runtime invariant" in text, "Adapter runtime doctrine doc missing invariant section.")
    require("Default Qwen3 runtime must not" in text, "Adapter runtime doctrine doc must explicitly forbid five full role GGUFs.")
    require("Improve-loop drift checks" in text, "Adapter runtime doctrine doc must include improve-loop drift checks.")


def main() -> int:
    checks = [
        check_catalog,
        check_fleet_resolver,
        check_runtime,
        check_slot_coordinator,
        check_models_view,
        check_export_policy,
        check_docs,
    ]
    failures: list[str] = []
    for check in checks:
        try:
            check()
            print(f"PASS {check.__name__}")
        except Exception as exc:  # noqa: BLE001 - command-line checker should report every failure
            failures.append(f"FAIL {check.__name__}: {exc}")
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print("All Qwen3 adapter runtime invariants passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
