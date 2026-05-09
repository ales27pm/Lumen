#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_FILE="$REPO_ROOT/ios/Lumen.xcodeproj/project.pbxproj"
PROJECT_PATH="$REPO_ROOT/ios/Lumen.xcodeproj"
SCHEME="${LUMEN_IOS_SCHEME:-Lumen}"
CONFIGURATION="${LUMEN_IOS_CONFIGURATION:-Release}"
DERIVED_DATA_ROOT="${LUMEN_DERIVED_DATA_ROOT:-$HOME/Library/Developer/Xcode/DerivedData}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE_PATH="${LUMEN_ARCHIVE_PATH:-$REPO_ROOT/build/Lumen-$TIMESTAMP.xcarchive}"
LOG_DIR="$REPO_ROOT/build/logs"
LOG_PATH="$LOG_DIR/archive-stable-$TIMESTAMP.log"

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
info() { printf "\n➡️  %s\n" "$1"; }
warn() { printf "\n⚠️  %s\n" "$1"; }
fail() { printf "\n❌ %s\n" "$1"; exit 1; }

print_xcode_log_diagnostics() {
  local log_path="$1"
  [[ -f "$log_path" ]] || return 0

  warn "xcodebuild failed. Full log: $log_path"
  info "Most relevant diagnostics"
  grep -nEi \
    '(^|[^A-Za-z])(error:|fatal error:|warning:|failed|failure|Command SwiftCompile failed|Command CompileSwift failed|Command CodeSign failed|no such module|cannot find|cannot convert|ambiguous|missing|undefined|duplicate|provisioning|codesign|SwiftDriver|CompileSwift|Ld |ld:|clang: error)' \
    "$log_path" | tail -n 160 || true

  info "Last 220 lines"
  tail -n 220 "$log_path" || true
}

run_logged() {
  local log_path="$1"
  shift
  mkdir -p "$(dirname "$log_path")"

  set +e
  "$@" 2>&1 | tee "$log_path"
  local status=${PIPESTATUS[0]}
  set -e

  if [[ $status -ne 0 ]]; then
    print_xcode_log_diagnostics "$log_path"
    return "$status"
  fi
}

[[ "$(uname -s)" == "Darwin" ]] || fail "This script must run on macOS."
command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild not found. Select Xcode with: sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer"
command -v python3 >/dev/null 2>&1 || fail "python3 not found. Install Xcode Command Line Tools or Python 3."
[[ -f "$PROJECT_FILE" ]] || fail "Missing project file: $PROJECT_FILE"

cd "$REPO_ROOT"
mkdir -p "$LOG_DIR" "$REPO_ROOT/build"

bold "Lumen stable iOS archive"
info "Applying durable archive/linker build settings"
python3 "$REPO_ROOT/scripts/apply_ios_archive_linker_fix.py" "$PROJECT_FILE" --no-backup

if [[ "${LUMEN_CLEAN_DERIVED_DATA:-1}" == "1" ]]; then
  info "Cleaning Lumen DerivedData"
  rm -rf "$DERIVED_DATA_ROOT"/Lumen-*
fi

if [[ "${LUMEN_RESET_SWIFTPM_CACHE:-0}" == "1" ]]; then
  info "Cleaning SwiftPM cache"
  rm -rf "$HOME/Library/Caches/org.swift.swiftpm"
  rm -rf "$REPO_ROOT/.build"
fi

info "Resolving Swift package dependencies"
run_logged "$LOG_DIR/resolve-packages-$TIMESTAMP.log" \
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -resolvePackageDependencies

info "Archiving with linker-safe Swift settings"
run_logged "$LOG_PATH" \
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=iOS" \
    -archivePath "$ARCHIVE_PATH" \
    COMPILER_INDEX_STORE_ENABLE=NO \
    ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES=YES \
    DEAD_CODE_STRIPPING=NO \
    SWIFT_COMPILATION_MODE=singlefile \
    SWIFT_WHOLE_MODULE_OPTIMIZATION=NO \
    SWIFT_OPTIMIZATION_LEVEL=-Osize \
    clean archive

bold "✅ Archive created: $ARCHIVE_PATH"
