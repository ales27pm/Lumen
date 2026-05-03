# Visual Improve-Loop Runner

`tools/run_visual_improve_loop_v2.py` is the hardened one-command visual orchestrator for the Lumen improvement loop.

It wraps the existing `lumen_manifest_crawler improve-loop` command, runs the adapter-first fine-tuning output pass, writes the TestFlight handoff queue, runs the release-bake manifest pass, and generates a standalone visual dashboard.

The v2 runner is repo-rooted: every relative output path is resolved against `--root`, not against the shell's current working directory. This prevents generated loop artifacts from being scattered outside the repository when the script is invoked from another directory.

> `tools/run_visual_improve_loop.py` remains the first visual draft. Prefer `tools/run_visual_improve_loop_v2.py` for real use.

## Default adapter-first run

Run from the repository root:

```bash
python tools/run_visual_improve_loop_v2.py
```

The same command also works from outside the repository when `--root` is explicit:

```bash
python /path/to/Lumen/tools/run_visual_improve_loop_v2.py --root /path/to/Lumen
```

Default outputs, all rooted under `--root`:

```text
generated/agent_manifest/
generated/agent_improvement_loop/
generated/fine_tuning/
generated/fine_tuning/release_bake_gguf_manifest.json
generated/visual_improve_loop/index.html
generated/visual_improve_loop/pipeline.svg
generated/visual_improve_loop/visual_improve_loop_summary.json
```

The default run is adapter-first. It does **not** merge LoRA adapters into full GGUF models. It writes a release-bake manifest that explicitly says the GGUF bake was skipped by default.

## Open the visual dashboard automatically

```bash
python tools/run_visual_improve_loop_v2.py --open-dashboard
```

## Run without local tests

Useful when the environment does not have `pytest` installed yet:

```bash
python tools/run_visual_improve_loop_v2.py --skip-tests
```

## Ingest a TestFlight / in-app audit export

After running the app on device and exporting the Agent Grounding dataset package:

```bash
python tools/run_visual_improve_loop_v2.py \
  --runtime-audit exports/lumen-in-app-dataset-testflight.json
```

Multiple audit files or directories are supported:

```bash
python tools/run_visual_improve_loop_v2.py \
  --runtime-audit exports/ \
  --runtime-audit generated/testflight_exports/
```

The runner also auto-discovers likely runtime audit JSON files under:

```text
generated/runtime_audits/
generated/runtime_audit/
generated/agent_improvement_loop/runtime_audits/
generated/testflight_exports/
exports/
```

Disable discovery with:

```bash
python tools/run_visual_improve_loop_v2.py --no-auto-discover-runtime-audit
```

## Treat missing TestFlight audit as hard failure

```bash
python tools/run_visual_improve_loop_v2.py --require-testflight-runtime-audit --fail-on-gaps
```

## Record build/train commands in the loop state

```bash
python tools/run_visual_improve_loop_v2.py \
  --build-command "xcodebuild -project ios/Lumen.xcodeproj -scheme Lumen -configuration Debug build" \
  --train-command "python tools/fine_tuning/unsloth/train_sft.py --config tools/fine_tuning/unsloth/configs/cortex.json" \
  --dry-run-commands
```

Remove `--dry-run-commands` when the build/train environment is ready and the commands should execute.

## Explicit GGUF release bake

Only run this after adapter eval gates pass or when the runtime cannot load adapters dynamically:

```bash
python tools/run_visual_improve_loop_v2.py \
  --release-bake \
  --release-bake-python .venv-unsloth/bin/python \
  --skip-release-bake-existing
```

With Hugging Face upload:

```bash
python tools/run_visual_improve_loop_v2.py \
  --release-bake \
  --release-bake-python .venv-unsloth/bin/python \
  --hf-repo-id ales27pm/lumen-fleet-gguf
```

## Important runtime boundary

The script automates the repository-side loop. It cannot execute the iOS app on a physical device. The live-app stage is handled by generated TestFlight artifacts:

```text
generated/agent_improvement_loop/testflight_scenarios.jsonl
generated/agent_improvement_loop/TESTFLIGHT_RUNBOOK.md
```

Run those scenarios in the real app, export the Agent Grounding dataset package, then feed that JSON back with `--runtime-audit`.

## Quick CI-friendly command

```bash
python tools/run_visual_improve_loop_v2.py \
  --quiet-commands \
  --fail-on-gaps \
  --require-testflight-runtime-audit
```

## Dashboard contents

The generated HTML dashboard includes:

- pipeline step status;
- command output tails;
- dataset family record counts;
- per-agent fine-tuning record counts;
- gap severity distribution;
- TestFlight scenario count;
- next-action prompt count;
- adapter runtime manifest summary;
- release-bake manifest summary;
- runtime audit summary.

## Regression coverage

`tools/lumen_manifest_crawler/tests/test_visual_improve_loop_runner.py` validates:

- relative output paths are rooted under `--root`;
- the improve-loop command receives repo-rooted output paths;
- GGUF release bake requires explicit `--release-bake`;
- realistic TestFlight exports are auto-discoverable;
- loop-state JSON is not mistaken for a runtime audit export;
- dynamic dashboard content is HTML-escaped.
