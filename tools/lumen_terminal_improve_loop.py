#!/usr/bin/env python3
"""Terminal-only AIO improve-loop launcher for Lumen.

This is the local, menu-driven replacement for the browser/HTML control panel.
It performs the complete adapter-first workflow from the terminal:

1. preflight checks;
2. code crawl + manifest/dataset generation;
3. in-app JSON ingestion;
4. embedding-state augmentation;
5. adapter-first release manifest generation;
6. Qwen3 role-adapter training;
7. LoRA-to-GGUF adapter conversion;
8. optional Hugging Face uploads.

The script runs fixed repo-rooted commands only. It never accepts arbitrary shell
commands from a web page or text field.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import shlex
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable, Sequence

AGENTS = ("cortex", "executor", "mouth", "mimicry", "rem", "fleet")

DEFAULT_OUTPUT = Path("generated/agent_manifest")
DEFAULT_LOOP_OUTPUT = Path("generated/agent_improvement_loop")
DEFAULT_FINE_TUNING_OUTPUT = Path("generated/fine_tuning")
DEFAULT_QWEN3_CONFIG_DIR = Path("tools/fine_tuning/unsloth/configs_qwen3_bootstrap")
DEFAULT_LORA_DIR = Path("models/lora_qwen3_bootstrap")
DEFAULT_LORA_GGUF_DIR = Path("models/lora_qwen3_gguf")
DEFAULT_RELEASE_OUTPUT_ROOT = Path("models/gguf_release_bake_qwen3_bootstrap")
DEFAULT_RELEASE_MANIFEST = Path("generated/fine_tuning/qwen3_bootstrap_release_bake_gguf_manifest.json")
DEFAULT_ADAPTER_REPO = "ales27pm/lumen-qwen3-bootstrap-adapters-gguf"
DEFAULT_BASE_REPO = "ales27pm/lumen-qwen3-bootstrap-gguf"
DEFAULT_BASE_FILE_NAME = "lumen-qwen3-fast-shared-q4_k_m.gguf"
DEFAULT_BASE_FILE = Path("models/base_qwen3_fast") / DEFAULT_BASE_FILE_NAME

RUNTIME_INCLUDE_HINTS = (
    "runtime",
    "audit",
    "grounding",
    "agent-grounding",
    "agent_grounding",
    "live-e2e",
    "e2e",
    "testflight",
    "in-app",
    "in_app",
    "trace",
)
RUNTIME_EXCLUDE_HINTS = (
    "loop_state",
    "loop_gaps",
    "next_action_prompts",
    "testflight_scenarios",
    "release_bake_gguf_manifest",
    "adapter_runtime_manifest",
    "dataset_manifest",
    "visual_improve_loop_summary",
)


@dataclass(frozen=True)
class RunResult:
    name: str
    returncode: int
    elapsed: float


class Terminal:
    def __init__(self, quiet: bool = False) -> None:
        self.quiet = quiet

    def print(self, text: str = "") -> None:
        if not self.quiet:
            print(text)

    def title(self, text: str) -> None:
        self.print("\n" + "=" * 88)
        self.print(text)
        self.print("=" * 88)

    def info(self, text: str) -> None:
        self.print(f"• {text}")

    def ok(self, text: str) -> None:
        self.print(f"✓ {text}")

    def warn(self, text: str) -> None:
        self.print(f"⚠ {text}")

    def fail(self, text: str) -> None:
        self.print(f"✗ {text}")


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def resolve(root: Path, value: str | Path) -> Path:
    path = Path(value).expanduser()
    return path if path.is_absolute() else root / path


def rel(root: Path, path: Path) -> str:
    try:
        return path.relative_to(root).as_posix()
    except ValueError:
        return str(path)


def parse_agents(raw: str) -> list[str]:
    agents = [x.strip().lower() for x in raw.split(",") if x.strip()]
    invalid = [a for a in agents if a not in AGENTS]
    if invalid:
        raise SystemExit(f"Invalid agent(s): {', '.join(invalid)}. Valid: {', '.join(AGENTS)}")
    return agents or list(AGENTS)


def env(root: Path) -> dict[str, str]:
    out = os.environ.copy()
    crawler = str((root / "tools/lumen_manifest_crawler").resolve())
    existing = out.get("PYTHONPATH")
    out["PYTHONPATH"] = crawler if not existing else f"{crawler}{os.pathsep}{existing}"
    out.setdefault("PYTHONUNBUFFERED", "1")
    return out


def run(
    term: Terminal,
    root: Path,
    name: str,
    argv: Sequence[str | Path],
    *,
    dry_run: bool = False,
    quiet_command: bool = False,
    stop_on_error: bool = False,
) -> RunResult:
    printable = [str(x) for x in argv]
    term.title(name)
    term.info(shlex.join(printable))
    if dry_run:
        term.warn("dry-run: command not executed")
        return RunResult(name, 0, 0.0)

    started = time.perf_counter()
    process = subprocess.Popen(
        printable,
        cwd=root,
        env=env(root),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
        errors="replace",
    )
    assert process.stdout is not None
    for line in process.stdout:
        if not quiet_command:
            print(line.rstrip())
    code = process.wait()
    elapsed = time.perf_counter() - started
    if code == 0:
        term.ok(f"{name} passed in {elapsed:.1f}s")
    else:
        term.fail(f"{name} failed with {code} after {elapsed:.1f}s")
        if stop_on_error:
            raise SystemExit(code)
    return RunResult(name, code, elapsed)


def runtime_json_candidate(path: Path) -> bool:
    name = path.name.lower()
    if not path.is_file() or path.suffix.lower() != ".json":
        return False
    if any(token in name for token in RUNTIME_EXCLUDE_HINTS):
        return False
    if not any(token in name for token in RUNTIME_INCLUDE_HINTS):
        return False
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return False
    if not isinstance(payload, dict):
        return False
    lowered_keys = {str(k).lower() for k in payload.keys()}
    if lowered_keys.intersection({"traces", "events", "failures", "runtime", "toolcalls", "tool_calls", "scenarioresults"}):
        return True
    sample = json.dumps(payload, ensure_ascii=False)[:30000].lower()
    return "adapterapplied" in sample or "agent grounding" in sample or "runtime" in sample or "trace" in sample


def discover_runtime_jsons(root: Path, explicit: Iterable[str]) -> list[Path]:
    patterns = list(explicit) or [
        "exports/*.json",
        "generated/runtime_audits/*.json",
        "generated/runtime_audit/*.json",
        "generated/testflight_exports/*.json",
        "generated/agent_improvement_loop/runtime_audits/*.json",
    ]
    found: list[Path] = []
    for pattern in patterns:
        absolute_pattern = str(resolve(root, pattern))
        for raw in glob.glob(absolute_pattern):
            path = Path(raw).resolve()
            if runtime_json_candidate(path):
                found.append(path)
    seen: set[Path] = set()
    unique: list[Path] = []
    for path in sorted(found):
        if path not in seen:
            seen.add(path)
            unique.append(path)
    return unique


def print_runtime_jsons(term: Terminal, root: Path, paths: Sequence[Path]) -> None:
    if not paths:
        term.warn("no in-app JSON exports found; the loop will create TestFlight handoff artifacts")
        return
    term.ok(f"in-app JSON exports discovered: {len(paths)}")
    for path in paths:
        term.info(rel(root, path))


def preflight(term: Terminal, root: Path, args: argparse.Namespace) -> list[RunResult]:
    term.title("Preflight")
    required = [
        root / "tools/lumen_manifest_crawler/lumen_manifest_crawler/cli.py",
        root / "tools/lumen_manifest_crawler/lumen_manifest_crawler/improvement_loop.py",
        root / "tools/fine_tuning/unsloth/train_sft.py",
        root / "tools/fine_tuning/unsloth/export_gguf.py",
        root / "tools/check_adapter_runtime_invariants.py",
        root / "docs/ADAPTER_RUNTIME_IMPROVE_LOOP.md",
        root / "ios/Lumen",
    ]
    missing = [p for p in required if not p.exists()]
    if missing:
        for path in missing:
            term.fail(f"missing {rel(root, path)}")
        if args.stop_on_error:
            raise SystemExit(2)
    else:
        term.ok("required files are present")

    results = [
        run(term, root, "adapter runtime drift guard", [sys.executable, "tools/check_adapter_runtime_invariants.py"], dry_run=args.dry_run, quiet_command=args.quiet_commands, stop_on_error=args.stop_on_error)
    ]
    if not args.skip_pytest:
        results.append(run(term, root, "manifest crawler tests", [sys.executable, "-m", "pytest", "tools/lumen_manifest_crawler/tests"], dry_run=args.dry_run, quiet_command=args.quiet_commands, stop_on_error=args.stop_on_error))
    return results


def crawl_ingest_generate(term: Terminal, root: Path, args: argparse.Namespace) -> list[RunResult]:
    audits = discover_runtime_jsons(root, args.runtime_audit)
    print_runtime_jsons(term, root, audits)

    improve = [
        sys.executable,
        "-m",
        "lumen_manifest_crawler",
        "improve-loop",
        "--root",
        str(root),
        "--output",
        str(resolve(root, args.output)),
        "--loop-output",
        str(resolve(root, args.loop_output)),
        "--fine-tuning-output",
        str(resolve(root, args.fine_tuning_output)),
        "--testflight-scenario-limit",
        str(args.testflight_scenario_limit),
        "--app-run-mode",
        args.app_run_mode,
        "--strict",
        "--deterministic",
        "--pretty",
        "--generate-system-prompts",
        "--generate-agent-fine-tuning",
    ]
    if args.require_runtime_audit:
        improve.append("--require-testflight-runtime-audit")
    for audit in audits:
        improve.extend(["--runtime-audit", str(audit)])

    results = [
        run(term, root, "crawl code + ingest JSON + generate datasets", improve, dry_run=args.dry_run, quiet_command=args.quiet_commands, stop_on_error=args.stop_on_error)
    ]

    augment = [
        sys.executable,
        "tools/augment_loop_state_embedding.py",
        "--loop-state",
        str(resolve(root, args.loop_output) / "loop_state.json"),
        "--embedding-dir",
        str(resolve(root, args.output) / "embedding"),
        "--print-summary",
    ]
    results.append(run(term, root, "augment loop summary with embedding state", augment, dry_run=args.dry_run, quiet_command=args.quiet_commands, stop_on_error=args.stop_on_error))

    export = [
        sys.executable,
        "tools/fine_tuning/unsloth/export_gguf.py",
        "--config-dir",
        str(resolve(root, args.config_dir)),
        "--agents",
        args.agents,
        "--quantization",
        args.quantization,
        "--output-root",
        str(resolve(root, args.release_output_root)),
        "--manifest-output",
        str(resolve(root, args.release_manifest)),
        "--skip-upload",
    ]
    if args.release_bake:
        export.append("--release-bake")
    results.append(run(term, root, "adapter-first manifest / optional release bake", export, dry_run=args.dry_run, quiet_command=args.quiet_commands, stop_on_error=args.stop_on_error))
    return results


def train(term: Terminal, root: Path, args: argparse.Namespace) -> list[RunResult]:
    cfg_dir = resolve(root, args.config_dir)
    if not cfg_dir.exists():
        raise SystemExit(f"Missing config dir: {cfg_dir}")
    results: list[RunResult] = []
    for agent in parse_agents(args.agents):
        cfg = cfg_dir / f"{agent}.json"
        if not cfg.exists():
            raise SystemExit(f"Missing config: {cfg}")
        results.append(run(term, root, f"train {agent} adapter", [sys.executable, "tools/fine_tuning/unsloth/train_sft.py", "--config", str(cfg)], dry_run=args.dry_run, quiet_command=args.quiet_commands, stop_on_error=args.stop_on_error))
    return results


def converter(root: Path, args: argparse.Namespace) -> Path:
    if args.converter:
        return resolve(root, args.converter)
    return Path.home() / ".unsloth/llama.cpp/convert_lora_to_gguf.py"


def convert(term: Terminal, root: Path, args: argparse.Namespace) -> list[RunResult]:
    script = converter(root, args)
    if not script.exists() and not args.dry_run:
        raise SystemExit(f"Missing converter: {script}")
    out_dir = resolve(root, args.lora_gguf_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    results: list[RunResult] = []
    for agent in parse_agents(args.agents):
        source = resolve(root, args.lora_dir) / agent
        if not source.exists() and not args.dry_run:
            term.warn(f"missing trained adapter dir: {rel(root, source)}")
            if args.stop_on_error:
                raise SystemExit(2)
            continue
        outfile = out_dir / f"lumen-{agent}-lora.gguf"
        results.append(run(term, root, f"convert {agent} adapter to GGUF", [sys.executable, str(script), str(source), "--outfile", str(outfile)], dry_run=args.dry_run, quiet_command=args.quiet_commands, stop_on_error=args.stop_on_error))
    return results


def upload_adapters(term: Terminal, root: Path, args: argparse.Namespace) -> list[RunResult]:
    if args.skip_upload:
        term.warn("skip-upload enabled")
        return []
    out_dir = resolve(root, args.lora_gguf_dir)
    if not out_dir.exists() and not args.dry_run:
        raise SystemExit(f"Missing adapter GGUF dir: {out_dir}")
    create = ["hf", "repo", "create", args.adapter_repo, "--type", "model", "--yes"]
    if args.hf_private:
        create.append("--private")
    return [
        run(term, root, "ensure adapter HF repo", create, dry_run=args.dry_run, quiet_command=args.quiet_commands, stop_on_error=False),
        run(term, root, "upload adapter GGUFs", ["hf", "upload", args.adapter_repo, str(out_dir), ".", "--repo-type", "model"], dry_run=args.dry_run, quiet_command=args.quiet_commands, stop_on_error=args.stop_on_error),
    ]


def upload_base(term: Terminal, root: Path, args: argparse.Namespace) -> list[RunResult]:
    if args.skip_upload:
        term.warn("skip-upload enabled")
        return []
    base = resolve(root, args.base_file)
    if not base.exists() and not args.dry_run:
        raise SystemExit(f"Missing shared base GGUF: {base}")
    create = ["hf", "repo", "create", args.base_repo, "--type", "model", "--yes"]
    if args.hf_private:
        create.append("--private")
    return [
        run(term, root, "ensure base HF repo", create, dry_run=args.dry_run, quiet_command=args.quiet_commands, stop_on_error=False),
        run(term, root, "upload shared Qwen3 base", ["hf", "upload", args.base_repo, str(base), DEFAULT_BASE_FILE_NAME, "--repo-type", "model"], dry_run=args.dry_run, quiet_command=args.quiet_commands, stop_on_error=args.stop_on_error),
    ]


def status(term: Terminal, root: Path, args: argparse.Namespace) -> None:
    term.title("Latest generated state")
    paths = [
        resolve(root, args.loop_output) / "LOOP_REPORT.md",
        resolve(root, args.loop_output) / "loop_gaps.json",
        resolve(root, args.loop_output) / "next_action_prompts.jsonl",
        resolve(root, args.output) / "dataset_manifest.json",
        resolve(root, args.output) / "embedding" / "dataset_card.json",
        resolve(root, args.release_manifest),
    ]
    for path in paths:
        if not path.exists():
            term.warn(f"missing {rel(root, path)}")
            continue
        term.title(rel(root, path))
        text = path.read_text(encoding="utf-8", errors="replace")
        if path.suffix == ".json":
            try:
                text = json.dumps(json.loads(text), indent=2, ensure_ascii=False)
            except Exception:
                pass
        print(text[:12000])


def full(term: Terminal, root: Path, args: argparse.Namespace) -> None:
    preflight(term, root, args)
    crawl_ingest_generate(term, root, args)
    train(term, root, args)
    convert(term, root, args)
    if args.upload_after_full:
        upload_adapters(term, root, args)
    status(term, root, args)


def menu(term: Terminal) -> str:
    term.title("Lumen terminal AIO improve-loop")
    print("1) Preflight: drift guard + tests")
    print("2) Crawl code + ingest in-app JSONs + generate datasets")
    print("3) Train Qwen3 role adapters")
    print("4) Convert trained LoRA adapters to GGUF")
    print("5) Upload adapter GGUFs to Hugging Face")
    print("6) Upload shared Qwen3 base GGUF to Hugging Face")
    print("7) Full local cycle: preflight → crawl/ingest/datasets → train → convert → status")
    print("8) Full local cycle + upload adapters")
    print("9) Show latest report/gaps/dataset summaries")
    print("0) Exit")
    return input("\nSelect: ").strip().lower()


def interactive(term: Terminal, root: Path, args: argparse.Namespace) -> int:
    actions: dict[str, Callable[[], object]] = {
        "1": lambda: preflight(term, root, args),
        "2": lambda: crawl_ingest_generate(term, root, args),
        "3": lambda: train(term, root, args),
        "4": lambda: convert(term, root, args),
        "5": lambda: upload_adapters(term, root, args),
        "6": lambda: upload_base(term, root, args),
        "7": lambda: full(term, root, args),
        "8": lambda: full(term, root, argparse.Namespace(**{**vars(args), "upload_after_full": True})),
        "9": lambda: status(term, root, args),
    }
    while True:
        choice = menu(term)
        if choice in {"0", "q", "quit", "exit"}:
            return 0
        action = actions.get(choice)
        if not action:
            term.warn("unknown selection")
            continue
        try:
            action()
        except KeyboardInterrupt:
            term.warn("interrupted")
        except Exception as exc:  # noqa: BLE001 - terminal menu should survive one failed step
            term.fail(str(exc))
            if args.stop_on_error:
                return 1
        input("\nPress Enter to return to menu...")


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Terminal-only AIO improve-loop launcher for Lumen.")
    parser.add_argument("--root", type=Path, default=repo_root())
    parser.add_argument("--mode", choices=["menu", "preflight", "generate", "train", "convert", "upload-adapters", "upload-base", "full", "status"], default="menu")
    parser.add_argument("--agents", default=",".join(AGENTS))
    parser.add_argument("--runtime-audit", action="append", default=[], help="Runtime JSON glob/path. Can be repeated. Defaults to exports/*.json and generated export dirs.")
    parser.add_argument("--require-runtime-audit", action="store_true")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--loop-output", type=Path, default=DEFAULT_LOOP_OUTPUT)
    parser.add_argument("--fine-tuning-output", type=Path, default=DEFAULT_FINE_TUNING_OUTPUT)
    parser.add_argument("--config-dir", type=Path, default=DEFAULT_QWEN3_CONFIG_DIR)
    parser.add_argument("--lora-dir", type=Path, default=DEFAULT_LORA_DIR)
    parser.add_argument("--lora-gguf-dir", type=Path, default=DEFAULT_LORA_GGUF_DIR)
    parser.add_argument("--release-output-root", type=Path, default=DEFAULT_RELEASE_OUTPUT_ROOT)
    parser.add_argument("--release-manifest", type=Path, default=DEFAULT_RELEASE_MANIFEST)
    parser.add_argument("--quantization", default="q4_k_m")
    parser.add_argument("--release-bake", action="store_true", help="Manual only: produce role-baked GGUFs. Leave off for adapter-first runtime.")
    parser.add_argument("--converter", type=Path, default=None)
    parser.add_argument("--adapter-repo", default=DEFAULT_ADAPTER_REPO)
    parser.add_argument("--base-repo", default=DEFAULT_BASE_REPO)
    parser.add_argument("--base-file", type=Path, default=DEFAULT_BASE_FILE)
    parser.add_argument("--hf-private", action="store_true")
    parser.add_argument("--skip-upload", action="store_true")
    parser.add_argument("--upload-after-full", action="store_true")
    parser.add_argument("--app-run-mode", default="testflight")
    parser.add_argument("--testflight-scenario-limit", type=int, default=120)
    parser.add_argument("--skip-pytest", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--quiet", action="store_true")
    parser.add_argument("--quiet-commands", action="store_true")
    parser.add_argument("--stop-on-error", action="store_true")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    root = resolve(Path.cwd(), args.root).resolve()
    os.chdir(root)
    term = Terminal(quiet=args.quiet)

    dispatch: dict[str, Callable[[], object]] = {
        "preflight": lambda: preflight(term, root, args),
        "generate": lambda: crawl_ingest_generate(term, root, args),
        "train": lambda: train(term, root, args),
        "convert": lambda: convert(term, root, args),
        "upload-adapters": lambda: upload_adapters(term, root, args),
        "upload-base": lambda: upload_base(term, root, args),
        "full": lambda: full(term, root, args),
        "status": lambda: status(term, root, args),
    }
    if args.mode == "menu":
        return interactive(term, root, args)
    dispatch[args.mode]()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
