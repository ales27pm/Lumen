#!/usr/bin/env bash
set -euo pipefail

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
    return 0
  fi

  warn "find command is missing. Attempting to install GNU findutils via Homebrew."
  if ! command -v brew >/dev/null 2>&1; then
    fail "Homebrew is not installed; install Homebrew or restore /usr/bin/find."
  fi

  brew install findutils
  if command -v find >/dev/null 2>&1; then
    return 0
  fi
  [[ -x /opt/homebrew/opt/findutils/libexec/gnubin/find ]] || [[ -x /usr/local/opt/findutils/libexec/gnubin/find ]] || fail "find installation did not expose expected binary."
}

ensure_xcodebuild_and_xcrun() {
  install_xcode_cli_tools

  if ! command -v xcodebuild >/dev/null 2>&1 || ! command -v xcrun >/dev/null 2>&1; then
    fail "xcodebuild/xcrun still unavailable after CLI tools check. Install Xcode from the App Store and run xcode-select --switch."
  fi

  xcodebuild -version >/dev/null 2>&1 || fail "xcodebuild is installed but not usable. Open Xcode once and accept licenses."

  if ! xcrun altool --help >/dev/null 2>&1; then
    warn "xcrun altool is unavailable. This usually means Xcode tools are incomplete or not selected."
    fail "Install/upgrade Xcode and ensure it is selected: sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer"
  fi
}

[[ "$(uname -s)" == "Darwin" ]] || fail "This script must run on macOS."
ensure_xcodebuild_and_xcrun
ensure_find

bold "Lumen iOS build + App Store Connect upload"

DEFAULT_PROJECT_PATH="ios/Lumen.xcodeproj"
DEFAULT_SCHEME="Lumen"
DEFAULT_CONFIGURATION="Release"
DEFAULT_EXPORT_METHOD="app-store"

read -r -p "Project/workspace path [$DEFAULT_PROJECT_PATH]: " PROJECT_PATH
PROJECT_PATH="${PROJECT_PATH:-$DEFAULT_PROJECT_PATH}"
[[ -e "$PROJECT_PATH" ]] || fail "Path not found: $PROJECT_PATH"
[[ "$PROJECT_PATH" == *.xcworkspace || "$PROJECT_PATH" == *.xcodeproj ]] || fail "Path must be .xcworkspace or .xcodeproj"

read -r -p "Scheme [$DEFAULT_SCHEME]: " SCHEME
SCHEME="${SCHEME:-$DEFAULT_SCHEME}"

read -r -p "Configuration [$DEFAULT_CONFIGURATION]: " CONFIGURATION
CONFIGURATION="${CONFIGURATION:-$DEFAULT_CONFIGURATION}"

read -r -p "Export method [$DEFAULT_EXPORT_METHOD]: " EXPORT_METHOD
EXPORT_METHOD="${EXPORT_METHOD:-$DEFAULT_EXPORT_METHOD}"

case "$EXPORT_METHOD" in
  app-store|ad-hoc|enterprise|development) ;;
  *) fail "Unsupported export method: $EXPORT_METHOD" ;;
esac

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
APPLE_ID=""
APP_SPECIFIC_PASSWORD=""
ASC_PROVIDER=""

case "$AUTH_MODE" in
  1)
    API_KEY="$(read_required 'API key ID: ')"
    API_ISSUER="$(read_required 'API issuer ID (UUID): ')"
    API_KEY_DIR="$(read_required 'Directory containing AuthKey_<KEYID>.p8: ')"
    [[ -d "$API_KEY_DIR" ]] || fail "API key directory not found: $API_KEY_DIR"
    [[ -f "$API_KEY_DIR/AuthKey_${API_KEY}.p8" ]] || fail "Missing API key file: $API_KEY_DIR/AuthKey_${API_KEY}.p8"
    read -r -p "Optional provider short name (leave blank to skip): " ASC_PROVIDER
    ;;
  2)
    APPLE_ID="$(read_required 'Apple ID (email): ')"
    APP_SPECIFIC_PASSWORD="$(read_secret_required 'App-specific password: ')"
    read -r -p "Optional provider short name (leave blank to skip): " ASC_PROVIDER
    ;;
  *)
    fail "Invalid auth mode."
    ;;
esac

cat > "$EXPORT_OPTIONS_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>${EXPORT_METHOD}</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>stripSwiftSymbols</key>
  <true/>
  <key>compileBitcode</key>
  <false/>
</dict>
</plist>
PLIST

info "Archive"
if [[ "$PROJECT_PATH" == *.xcworkspace ]]; then
  xcodebuild -workspace "$PROJECT_PATH" -scheme "$SCHEME" -configuration "$CONFIGURATION" -archivePath "$ARCHIVE_PATH" clean archive
else
  xcodebuild -project "$PROJECT_PATH" -scheme "$SCHEME" -configuration "$CONFIGURATION" -archivePath "$ARCHIVE_PATH" clean archive
fi

info "Export IPA"
xcodebuild -exportArchive -archivePath "$ARCHIVE_PATH" -exportPath "$EXPORT_DIR" -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"

IPA_PATH="$(find "$EXPORT_DIR" -maxdepth 1 -type f -name '*.ipa' -print -quit)"
[[ -n "$IPA_PATH" ]] || fail "No IPA found in $EXPORT_DIR"

bold "Built IPA: $IPA_PATH"
if ! confirm "Upload this IPA to App Store Connect now?"; then
  warn "Upload skipped. IPA is ready at: $IPA_PATH"
  exit 0
fi

info "Upload via altool"
UPLOAD_CMD=(xcrun altool --upload-app --type ios --file "$IPA_PATH")
[[ -n "$ASC_PROVIDER" ]] && UPLOAD_CMD+=(--asc-provider "$ASC_PROVIDER")
if [[ "$AUTH_MODE" == "1" ]]; then
  export API_PRIVATE_KEYS_DIR="$API_KEY_DIR"
  UPLOAD_CMD+=(--apiKey "$API_KEY" --apiIssuer "$API_ISSUER")
else
  export ALTOOL_APP_SPECIFIC_PASSWORD="$APP_SPECIFIC_PASSWORD"
  UPLOAD_CMD+=(--username "$APPLE_ID" --password @env:ALTOOL_APP_SPECIFIC_PASSWORD)
fi

"${UPLOAD_CMD[@]}"
unset ALTOOL_APP_SPECIFIC_PASSWORD || true
bold "✅ Upload complete. Check App Store Connect for processing status."
