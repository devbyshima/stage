#!/bin/bash
# Generates the Xcode project and builds the Mac app. Prints only errors,
# warnings from our own sources, and the result.
#
#   ./scripts/build.sh            # Debug build in .build/main
#   ./scripts/build.sh release    # Release build, copied to build/Stage.app
#   ./scripts/build.sh test       # anything else goes to xcodebuild (default: build)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${CONFIG:-Debug}"
DERIVED="${DERIVED:-$ROOT/.build/main}"
RELEASE=0
if [ "${1:-}" = "release" ]; then
  shift
  RELEASE=1
  CONFIG=Release
  DERIVED="$ROOT/.build/release"
fi
mkdir -p "$DERIVED"
LOG="$DERIVED/build.log"
ACTION=("$@")
[ ${#ACTION[@]} -eq 0 ] && ACTION=(build)

xcodegen generate --quiet || exit 1

xcodebuild -project Stage.xcodeproj -scheme Stage -configuration "$CONFIG" \
  -destination "platform=macOS,arch=arm64" -derivedDataPath "$DERIVED" \
  "${ACTION[@]}" >"$LOG" 2>&1
STATUS=$?

grep -E "^$ROOT/(Stage|StageTests)/.*(error|warning):" "$LOG" | sort -u
grep -E "^(error|fatal error):|Test .*(passed|failed)|recorded an issue|✘|✔ Test run" "$LOG" | sort -u | head -80
if [ $STATUS -eq 0 ] && [ $RELEASE -eq 1 ]; then
  mkdir -p build
  rm -rf build/Stage.app
  cp -R "$DERIVED/Build/Products/Release/Stage.app" build/
  echo "App: $ROOT/build/Stage.app"
fi
if [ $STATUS -eq 0 ]; then echo "SUCCEEDED (${ACTION[*]})"; else echo "FAILED (full log: $LOG)"; fi
exit $STATUS
