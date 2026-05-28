#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROJECT="ios/Lumen.xcodeproj"
PBX="$PROJECT/project.pbxproj"

echo "== Xcode availability =="
if command -v xcodebuild >/dev/null 2>&1; then
  xcodebuild -version
  echo "== Project schemes =="
  (cd ios && xcodebuild -list -project Lumen.xcodeproj)
else
  echo "xcodebuild unavailable; static readiness checks only."
fi

echo "== Project membership format =="
test -f "$PBX"
if rg -q "PBXFileSystemSynchronizedRootGroup" "$PBX"; then
  echo "Project uses file-system synchronized root groups for Lumen and LumenTests."
else
  echo "warning: project does not use synchronized root groups; manual source membership audit required." >&2
fi

echo "== Swift files present =="
find ios/Lumen -name "*.swift" -print | sort >/tmp/lumen_app_swift_files.txt
find ios/LumenTests -name "*.swift" -print | sort >/tmp/lumen_test_swift_files.txt
wc -l /tmp/lumen_app_swift_files.txt /tmp/lumen_test_swift_files.txt

echo "== Static privacy/build-hardening checks =="
if rg -n "TODO|stub|placeholder" ios/Lumen ios/LumenTests docs; then
  echo "Found TODO/stub/placeholder markers. Review above; some may be literal test/prompt text." >&2
fi
rg -n "import AppIntents|AppIntent|AppShortcutsProvider" ios/Lumen/AppIntents >/dev/null
rg -n "FoundationModels|@available|canImport\(FoundationModels\)" ios/Lumen >/dev/null || true
rg -n "NSMicrophoneUsageDescription|NSSpeechRecognitionUsageDescription|NSCalendars|NSContactsUsageDescription|NSLocationWhenInUseUsageDescription|BGTaskSchedulerPermittedIdentifiers" ios >/dev/null
if rg -n "OSLog|Logger" ios/Lumen/AppIntents ios/Lumen/Voice ios/Lumen/Diagnostics; then
  echo "Found logging APIs in privacy-sensitive additions; review output above." >&2
fi

echo "Build readiness static checks completed. Run xcodebuild on macOS for compile validation."
