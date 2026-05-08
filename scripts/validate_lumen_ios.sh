#!/usr/bin/env bash
set -euo pipefail

if [[ ! -d .git ]]; then
  echo "Error: run this script from the repository root." >&2
  exit 1
fi

DESTINATION="${DESTINATION:-platform=iOS Simulator,name=iPhone 16}"
PROJECT="ios/Lumen.xcodeproj"
SCHEME="Lumen"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Error: macOS is required to run iOS xcodebuild validation." >&2
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "Error: xcodebuild is not available in PATH." >&2
  exit 1
fi

echo "== Conflict marker scan =="
rg "<<<<<<<|=======|>>>>>>>" ios || true

echo "== try! scan =="
rg "try!" ios/Lumen || true

echo "== Task.detached scan =="
rg "Task\\.detached" ios/Lumen ios/LumenTests || true

echo "== xcodebuild build-for-testing =="
xcodebuild build-for-testing -project "$PROJECT" -scheme "$SCHEME" -destination "$DESTINATION"

echo "== xcodebuild test =="
xcodebuild test -project "$PROJECT" -scheme "$SCHEME" -destination "$DESTINATION"
