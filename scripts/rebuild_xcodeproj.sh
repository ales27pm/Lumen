#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_DIR="${ROOT_DIR}/ios"
PROJECT_SPEC="${IOS_DIR}/project.yml"
PROJECT_FILE="${IOS_DIR}/Lumen.xcodeproj"
SCHEME="Lumen"
CONFIGURATION="Release"
DERIVED_DATA_PATH="${ROOT_DIR}/.derived-data/rebuild-xcodeproj"

log() {
  printf '\n\033[1;36m==> %s\033[0m\n' "$*"
}

fail() {
  printf '\n\033[1;31merror:\033[0m %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

require_cmd python3
require_cmd xcodebuild
require_cmd xcodegen

[[ -f "${PROJECT_SPEC}" ]] || fail "Missing XcodeGen spec: ${PROJECT_SPEC}"
[[ -f "${ROOT_DIR}/scripts/validate_ios_signing_capabilities.py" ]] || fail "Missing signing validator."

log "Removing stale generated Xcode project"
rm -rf "${PROJECT_FILE}"

log "Generating deterministic Xcode project from ios/project.yml"
(
  cd "${IOS_DIR}"
  xcodegen generate --spec "${PROJECT_SPEC}"
)

[[ -d "${PROJECT_FILE}" ]] || fail "XcodeGen did not create ${PROJECT_FILE}"

log "Validating signing capability declarations"
python3 "${ROOT_DIR}/scripts/validate_ios_signing_capabilities.py" \
  --project-file "${PROJECT_FILE}/project.pbxproj" \
  --entitlements "${IOS_DIR}/Lumen/Lumen.entitlements"

log "Checking generated project for forbidden generic CarPlay entitlement"
if grep -R "com.apple.developer.carplay[[:space:]]" "${IOS_DIR}/Lumen" "${PROJECT_FILE}/project.pbxproj" >/dev/null 2>&1; then
  fail "Found generic com.apple.developer.carplay entitlement. Use com.apple.developer.carplay-voice-based-conversation only."
fi

log "Resolving Swift Package dependencies"
xcodebuild \
  -project "${PROJECT_FILE}" \
  -scheme "${SCHEME}" \
  -resolvePackageDependencies \
  -derivedDataPath "${DERIVED_DATA_PATH}"

log "Building Release for generic iOS without code signing"
xcodebuild \
  -project "${PROJECT_FILE}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -destination "generic/platform=iOS" \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  CODE_SIGNING_ALLOWED=NO \
  build

log "Generated project is valid"
