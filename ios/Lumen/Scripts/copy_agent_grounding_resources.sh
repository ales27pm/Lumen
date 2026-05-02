#!/bin/sh
set -eu

log() {
  printf '[AgentGroundingResources] %s\n' "$1"
}

fail() {
  printf '[AgentGroundingResources] ERROR: %s\n' "$1" >&2
  exit 1
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
CROSS_MODEL_DIR="$REPO_ROOT/generated/cross_model_training"
APP_RESOURCES_DIR="$TARGET_BUILD_DIR_VALUE/$UNLOCALIZED_RESOURCES_FOLDER_PATH_VALUE"
DEST_DIR="$APP_RESOURCES_DIR/AgentGrounding"

[ -d "$AGENT_MANIFEST_DIR" ] || fail "Missing generated agent manifest directory: $AGENT_MANIFEST_DIR"
[ -d "$CROSS_MODEL_DIR" ] || fail "Missing generated cross-model training directory: $CROSS_MODEL_DIR"
[ -f "$AGENT_MANIFEST_DIR/AgentBehaviorManifest.json" ] || fail 'Missing AgentBehaviorManifest.json. Run lumen_manifest_crawler generate first.'
[ -f "$AGENT_MANIFEST_DIR/fleet_system_prompts.json" ] || fail 'Missing fleet_system_prompts.json. Run generation with --generate-system-prompts.'
[ -f "$AGENT_MANIFEST_DIR/manifest_validation_report.json" ] || fail 'Missing manifest_validation_report.json.'
[ -f "$CROSS_MODEL_DIR/cross_model_training.jsonl" ] || fail 'Missing cross_model_training.jsonl. Run generation with --cross-model-train-dir.'

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

log "Installed resources at: $DEST_DIR"
log "Manifest: $DEST_DIR/agent_manifest/AgentBehaviorManifest.json"
log "Prompts:  $DEST_DIR/agent_manifest/fleet_system_prompts.json"
