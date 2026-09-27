#!/bin/sh
# Generate the Xcode project, build Debug, and launch the app.
# Usage: scripts/dev.sh [--demo]
set -e
cd "$(dirname "$0")/.."
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen missing: brew install xcodegen" >&2; exit 1
fi
xcodegen generate --quiet
xcodebuild -scheme notchcode -configuration Debug -derivedDataPath build/DerivedData build | grep -E "error|warning: unre|BUILD" || true
APP="build/DerivedData/Build/Products/Debug/notchcode.app"
[ -d "$APP" ] || { echo "build failed" >&2; exit 1; }
pkill -x notchcode 2>/dev/null || true
open -n "$APP" --args "$@"
echo "launched $APP $*"
