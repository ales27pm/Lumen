#!/usr/bin/env bash
set -euo pipefail

FIND_BIN="find"

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
info() { printf "\n➡️  %s\n" "$1"; }
warn() { printf "\n⚠️  %s\n" "$1"; }
fail() { printf "\n❌ %s\n" "$1"; exit 1; }

confirm() {
  local prompt="$1"
  local response
  read -r -p "$prompt [y/N]: " response
  [[ "$response" =~ ^[Yy]$ ]]
}

read_required() {
  local prompt="$1"
  local var=""
  while [[ -z "${var// }" ]]; do
    read -r -p "$prompt" var
  done
  printf "%s" "$var"
}

read_secret_required() {
  local prompt="$1"
  local var=""
  while [[ -z "${var// }" ]]; do
    read -r -s -p "$prompt" var
    printf "\n"
  done
  printf "%s" "$var"
}

install_xcode_cli_tools() {
  if xcode-select -p >/dev/null 2>&1; then
    return 0
  fi

  info "Xcode Command Line Tools are not installed."
  if ! confirm "Install Xcode Command Line Tools now via xcode-select --install?"; then
    fail "Xcode Command Line Tools are required."
  fi

  xcode-select --install || true
  warn "Complete the GUI installer, then re-run this script."
  exit 1
}

ensure_find() {
  if command -v find >/dev/null 2>&1; then
    FIND_BIN="$(command -v find)"
    export FIND_BIN
    return 0
  fi

  warn "find command is missing. Attempting to install GNU findutils via Homebrew."
  if ! command -v brew >/dev/null 2>&1; then
    fail "Homebrew is not installed; install Homebrew or restore /usr/bin/find."
  fi

  brew install findutils
  if command -v find >/dev/null 2>&1; then
    FIND_BIN="$(command -v find)"
    export FIND_BIN
    return 0
  fi
  if [[ -x /opt/homebrew/opt/findutils/libexec/gnubin/find ]]; then
    FIND_BIN="/opt/homebrew/opt/findutils/libexec/gnubin/find"
  elif [[ -x /usr/local/opt/findutils/libexec/gnubin/find ]]; then
    FIND_BIN="/usr/local/opt/findutils/libexec/gnubin/find"
  else
    fail "find installation did not expose expected binary under /opt/homebrew or /usr/local gnubin paths."
  fi
  export FIND_BIN
}

ensure_xcodebuild_and_xcrun() {
  install_xcode_cli_tools

  if ! command -v xcodebuild >/dev/null 2>&1 || ! command -v xcrun >/dev/null 2>&1; then
    fail "xcodebuild/xcrun unavailable. Install Xcode and select it with: sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer"
  fi

  xcodebuild -version >/dev/null 2>&1 || fail "xcodebuild is installed but not usable. Open Xcode once and accept licenses."
}

ensure_upload_tool() {
  if ! xcrun altool --help >/dev/null 2>&1; then
    fail "xcrun altool is unavailable. Install/upgrade Xcode and select it with: sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer"
  fi
}

normalize_export_method() {
  case "$1" in
    app-store|app-store-connect) printf "app-store-connect" ;;
    ad-hoc|release-testing) printf "release-testing" ;;
    development|debugging) printf "debugging" ;;
    enterprise) printf "enterprise" ;;
    validation) printf "validation" ;;
    *) return 1 ;;
  esac
}

is_distribution_export() {
  case "$1" in
    app-store-connect|release-testing|enterprise|validation) return 0 ;;
    *) return 1 ;;
  esac
}

write_export_options_plist() {
  local plist_path="$1"
  local export_method="$2"
  local team_id="$3"
  local signing_certificate="$4"

  cat > "$plist_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>${export_method}</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>signingCertificate</key>
  <string>${signing_certificate}</string>
PLIST

  if [[ -n "$team_id" ]]; then
    cat >> "$plist_path" <<PLIST
  <key>teamID</key>
  <string>${team_id}</string>
PLIST
  fi

  cat >> "$plist_path" <<PLIST
  <key>stripSwiftSymbols</key>
  <true/>
  <key>uploadSymbols</key>
  <true/>
</dict>
</plist>
PLIST
}

build_project_selector_args() {
  local project_path="$1"
  if [[ "$project_path" == *.xcworkspace ]]; then
    printf '%s\0%s\0' "-workspace" "$project_path"
  else
    printf '%s\0%s\0' "-project" "$project_path"
  fi
}

[[ "$(uname -s)" == "Darwin" ]] || fail "This script must run on macOS."
ensure_xcodebuild_and_xcrun
ensure_find

bold "Lumen iOS build + App Store Connect upload"

DEFAULT_PROJECT_PATH="ios/Lumen.xcodeproj"
DEFAULT_SCHEME="Lumen"
DEFAULT_CONFIGURATION="Release"
DEFAULT_EXPORT_METHOD="app-store-connect"
DEFAULT_TEAM_ID="${DEVELOPMENT_TEAM:-52T7P32J34}"

read -r -p "Project/workspace path [$DEFAULT_PROJECT_PATH]: " PROJECT_PATH
PROJECT_PATH="${PROJECT_PATH:-$DEFAULT_PROJECT_PATH}"
[[ -e "$PROJECT_PATH" ]] || fail "Path not found: $PROJECT_PATH"
[[ "$PROJECT_PATH" == *.xcworkspace || "$PROJECT_PATH" == *.xcodeproj ]] || fail "Path must be .xcworkspace or .xcodeproj"

read -r -p "Scheme [$DEFAULT_SCHEME]: " SCHEME
SCHEME="${SCHEME:-$DEFAULT_SCHEME}"

read -r -p "Configuration [$DEFAULT_CONFIGURATION]: " CONFIGURATION
CONFIGURATION="${CONFIGURATION:-$DEFAULT_CONFIGURATION}"

read -r -p "Apple Developer Team ID [$DEFAULT_TEAM_ID]: " TEAM_ID
TEAM_ID="${TEAM_ID:-$DEFAULT_TEAM_ID}"

read -r -p "Export method [$DEFAULT_EXPORT_METHOD]: " EXPORT_METHOD_INPUT
EXPORT_METHOD_INPUT="${EXPORT_METHOD_INPUT:-$DEFAULT_EXPORT_METHOD}"
EXPORT_METHOD="$(normalize_export_method "$EXPORT_METHOD_INPUT")" || fail "Unsupported export method: $EXPORT_METHOD_INPUT"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
SCHEME_SAFE="${SCHEME//[^A-Za-z0-9_.-]/_}"
ARCHIVE_PATH="build/${SCHEME_SAFE}-${TIMESTAMP}.xcarchive"
EXPORT_DIR="build/export-${SCHEME_SAFE}-${TIMESTAMP}"
EXPORT_OPTIONS_PLIST="build/export-options-${SCHEME_SAFE}-${TIMESTAMP}.plist"

mkdir -p build

bold "Choose auth mode"
echo "1) App Store Connect API key (recommended)"
echo "2) Apple ID + app-specific password"
AUTH_MODE="$(read_required 'Select [1/2]: ')"

API_KEY=""
API_ISSUER=""
API_KEY_DIR=""
API_KEY_PATH=""
APPLE_ID=""
APP_SPECIFIC_PASSWORD=""
ASC_PROVIDER=""

case "$AUTH_MODE" in
  1)
    API_KEY="$(read_required 'API key ID: ')"
    API_ISSUER="$(read_required 'API issuer ID (UUID): ')"
    API_KEY_DIR="$(read_required 'Directory containing AuthKey_<KEYID>.p8: ')"
    [[ -d "$API_KEY_DIR" ]] || fail "API key directory not found: $API_KEY_DIR"
    API_KEY_PATH="$API_KEY_DIR/AuthKey_${API_KEY}.p8"
    [[ -f "$API_KEY_PATH" ]] || fail "Missing API key file: $API_KEY_PATH"
    read -r -p "Optional provider short name (leave blank to skip): " ASC_PROVIDER
    ;;
  2)
    APPLE_ID="$(read_required 'Apple ID (email): ')"
    APP_SPECIFIC_PASSWORD="$(read_secret_required 'App-specific password: ')"
    read -r -p "Optional provider short name (leave blank to skip): " ASC_PROVIDER
    warn "Apple ID auth can upload the IPA, but automatic profile creation still depends on Xcode being signed into your Apple Developer account."
    ;;
  *)
    fail "Invalid auth mode."
    ;;
esac

SIGNING_CERTIFICATE="Apple Development"
if is_distribution_export "$EXPORT_METHOD"; then
  SIGNING_CERTIFICATE="Apple Distribution"
fi

write_export_options_plist "$EXPORT_OPTIONS_PLIST" "$EXPORT_METHOD" "$TEAM_ID" "$SIGNING_CERTIFICATE"

PROJECT_SELECTOR=()
while IFS= read -r -d '' arg; do
  PROJECT_SELECTOR+=("$arg")
done < <(build_project_selector_args "$PROJECT_PATH")

XCODE_AUTH_ARGS=()
if [[ "$AUTH_MODE" == "1" ]]; then
  XCODE_AUTH_ARGS+=(
    -authenticationKeyPath "$API_KEY_PATH"
    -authenticationKeyID "$API_KEY"
    -authenticationKeyIssuerID "$API_ISSUER"
  )
fi

SIGNING_BUILD_SETTINGS=(
  "CODE_SIGN_STYLE=Automatic"
  "DEVELOPMENT_TEAM=$TEAM_ID"
  "PROVISIONING_PROFILE_SPECIFIER="
)

info "Archive"
xcodebuild \
  "${PROJECT_SELECTOR[@]}" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  "${XCODE_AUTH_ARGS[@]}" \
  "${SIGNING_BUILD_SETTINGS[@]}" \
  clean archive

info "Export IPA"
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
  -allowProvisioningUpdates \
  "${XCODE_AUTH_ARGS[@]}"

IPA_PATH="$("$FIND_BIN" "$EXPORT_DIR" -maxdepth 1 -type f -name '*.ipa' -print -quit)"
[[ -n "$IPA_PATH" ]] || fail "No IPA found in $EXPORT_DIR"

bold "Built IPA: $IPA_PATH"
if ! confirm "Upload this IPA to App Store Connect now?"; then
  warn "Upload skipped. IPA is ready at: $IPA_PATH"
  exit 0
fi

ensure_upload_tool
info "Upload via altool"
UPLOAD_CMD=(xcrun altool --upload-app --type ios --file "$IPA_PATH")
[[ -n "$ASC_PROVIDER" ]] && UPLOAD_CMD+=(--asc-provider "$ASC_PROVIDER")
if [[ "$AUTH_MODE" == "1" ]]; then
  export API_PRIVATE_KEYS_DIR="$API_KEY_DIR"
  UPLOAD_CMD+=(--apiKey "$API_KEY" --apiIssuer "$API_ISSUER")
else
  export APP_SPECIFIC_PASSWORD
  UPLOAD_CMD+=(--username "$APPLE_ID" --password @env:APP_SPECIFIC_PASSWORD)
fi

"${UPLOAD_CMD[@]}"
unset APP_SPECIFIC_PASSWORD || true
bold "✅ Upload complete. Check App Store Connect for processing status."
