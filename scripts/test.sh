#!/bin/zsh
# Runs the ReflexKit unit tests and checks that the app targets build.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo "▶ ReflexKit (swift test)"
(cd "$ROOT/Packages/ReflexKit" && swift test 2>&1 | grep -E "✘|error:|Test run with")
echo "▶ Spike (xcodebuild build)"
(cd "$ROOT" && xcodegen generate --quiet && xcodebuild -project Reflex.xcodeproj -scheme ReflexSpike \
  -derivedDataPath build -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)")
