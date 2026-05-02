#!/bin/sh
set -eu

log() {
  printf '[AgentGroundingResources] %s\n' "$1"
}

fail() {
  printf '[AgentGroundingResources] ERROR: %s\n' "$1" >&2
  exit 1
}

require_file() {
  path="$1"
  label="$2"
  [ -f "$path" ] || fail "Missing required file: $label ($path)"
}

require_dir() {
  path="$1"
  label="$2"
  [ -d "$path" ] || fail "Missing required directory: $label ($path)"
}

PROJECT_DIR_VALUE="${PROJECT_DIR:-}"
TARGET_BUILD_DIR_VALUE="${TARGET_BUILD_DIR:-}"
UNLOCALIZED_RESOURCES_FOLDER_PATH_VALUE="${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}"

if [ -z "$PROJECT_DIR_VALUE" ]; then
  fail 'PROJECT_DIR is not set. Run this script from an Xcode build action or pass Xcode build settings.'
fi

if [ -z "$TARGET_BUILD_DIR_VALUE" ]; then
  fail 'TARGET_BUILD_DIR is not set. Run this script from an Xcode build action or pass Xcode build settings.'
fi

if [ -z "$UNLOCALIZED_RESOURCES_FOLDER_PATH_VALUE" ]; then
  fail 'UNLOCALIZED_RESOURCES_FOLDER_PATH is not set. Run this script from an Xcode build action or pass Xcode build settings.'
fi

REPO_ROOT="$(cd "$PROJECT_DIR_VALUE/.." && pwd)"
AGENT_MANIFEST_DIR="$REPO_ROOT/generated/agent_manifest"
LEGACY_CROSS_MODEL_DIR="$REPO_ROOT/generated/cross_model_training"
NESTED_CROSS_MODEL_DIR="$AGENT_MANIFEST_DIR/cross_model_training"
LOOP_OUTPUT_DIR="$REPO_ROOT/generated/agent_improvement_loop"
APP_RESOURCES_DIR="$TARGET_BUILD_DIR_VALUE/$UNLOCALIZED_RESOURCES_FOLDER_PATH_VALUE"
DEST_DIR="$APP_RESOURCES_DIR/AgentGrounding"

if [ -d "$LEGACY_CROSS_MODEL_DIR" ]; then
  CROSS_MODEL_DIR="$LEGACY_CROSS_MODEL_DIR"
elif [ -d "$NESTED_CROSS_MODEL_DIR" ]; then
  CROSS_MODEL_DIR="$NESTED_CROSS_MODEL_DIR"
else
  fail "Missing cross-model training directory. Expected either $LEGACY_CROSS_MODEL_DIR or $NESTED_CROSS_MODEL_DIR"
fi

require_dir "$AGENT_MANIFEST_DIR" 'generated agent manifest directory'
require_dir "$CROSS_MODEL_DIR" 'generated cross-model training directory'

require_file "$AGENT_MANIFEST_DIR/AgentBehaviorManifest.json" 'AgentBehaviorManifest.json'
require_file "$AGENT_MANIFEST_DIR/AgentBehaviorManifest.md" 'AgentBehaviorManifest.md'
require_file "$AGENT_MANIFEST_DIR/fleet_system_prompts.json" 'fleet_system_prompts.json'
require_file "$AGENT_MANIFEST_DIR/manifest_validation_report.json" 'manifest_validation_report.json'
require_file "$AGENT_MANIFEST_DIR/AgentBehaviorManifest.sha256" 'AgentBehaviorManifest.sha256'
require_file "$AGENT_MANIFEST_DIR/AgentBehaviorManifest.incremental.sha256" 'AgentBehaviorManifest.incremental.sha256'
require_file "$AGENT_MANIFEST_DIR/dataset_manifest.json" 'dataset_manifest.json'
require_file "$AGENT_MANIFEST_DIR/dataset_index.csv" 'dataset_index.csv'
require_file "$AGENT_MANIFEST_DIR/tool_registry.csv" 'tool_registry.csv'
require_file "$AGENT_MANIFEST_DIR/routing_matrix.csv" 'routing_matrix.csv'

require_dir "$AGENT_MANIFEST_DIR/dataset" 'generated dataset directory'
require_file "$AGENT_MANIFEST_DIR/dataset/train_sft.jsonl" 'dataset/train_sft.jsonl'
require_file "$AGENT_MANIFEST_DIR/dataset/validation_sft.jsonl" 'dataset/validation_sft.jsonl'
require_file "$AGENT_MANIFEST_DIR/dataset/dpo_preference_pairs.jsonl" 'dataset/dpo_preference_pairs.jsonl'
require_file "$AGENT_MANIFEST_DIR/dataset/eval_scenarios.jsonl" 'dataset/eval_scenarios.jsonl'
require_file "$AGENT_MANIFEST_DIR/dataset/tool_schema_cards.jsonl" 'dataset/tool_schema_cards.jsonl'
require_file "$AGENT_MANIFEST_DIR/dataset/manifest_grounding_cards.jsonl" 'dataset/manifest_grounding_cards.jsonl'
require_file "$AGENT_MANIFEST_DIR/dataset/runtime_audit_repairs.jsonl" 'dataset/runtime_audit_repairs.jsonl'

require_file "$CROSS_MODEL_DIR/cross_model_training.jsonl" 'cross_model_training.jsonl'
require_file "$CROSS_MODEL_DIR/train_sft_cross.jsonl" 'train_sft_cross.jsonl'
require_file "$CROSS_MODEL_DIR/val_sft_cross.jsonl" 'val_sft_cross.jsonl'
require_file "$CROSS_MODEL_DIR/dpo_train_cross.jsonl" 'dpo_train_cross.jsonl'
require_file "$CROSS_MODEL_DIR/dpo_val_cross.jsonl" 'dpo_val_cross.jsonl'
require_file "$CROSS_MODEL_DIR/cross_model_training_index.csv" 'cross_model_training_index.csv'

python3 - "$AGENT_MANIFEST_DIR/manifest_validation_report.json" <<'PY'
import json
import sys
from pathlib import Path

report = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
if report.get('passed') is not True:
    raise SystemExit('manifest_validation_report.json is not passed=true')
if report.get('failures'):
    raise SystemExit(f"manifest_validation_report.json has failures: {len(report['failures'])}")
if report.get('warnings'):
    raise SystemExit(f"manifest_validation_report.json has warnings: {len(report['warnings'])}")
PY

log "Copying generated artifacts into app bundle resources"
rm -rf "$DEST_DIR"
mkdir -p "$DEST_DIR"

cp -R "$AGENT_MANIFEST_DIR" "$DEST_DIR/agent_manifest"
cp -R "$CROSS_MODEL_DIR" "$DEST_DIR/cross_model_training"

if [ -d "$LOOP_OUTPUT_DIR" ]; then
  cp -R "$LOOP_OUTPUT_DIR" "$DEST_DIR/agent_improvement_loop"
  log "Loop outputs: $DEST_DIR/agent_improvement_loop"
else
  log "Loop outputs not present at $LOOP_OUTPUT_DIR (skipped)"
fi

log "Installed resources at: $DEST_DIR"
log "Manifest: $DEST_DIR/agent_manifest/AgentBehaviorManifest.json"
log "Prompts:  $DEST_DIR/agent_manifest/fleet_system_prompts.json"
