#!/bin/zsh
# Runs the ReflexKit unit tests and checks that both app targets build.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo "▶ ReflexKit (swift test)"
(cd "$ROOT/Packages/ReflexKit" && swift test 2>&1 | grep -E "✘|error:|Test run with")
(cd "$ROOT" && xcodegen generate --quiet)
for scheme in Reflex ReflexSpike; do
  echo "▶ $scheme (xcodebuild build)"
  (cd "$ROOT" && xcodebuild -project Reflex.xcodeproj -scheme $scheme -derivedDataPath build \
    -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)")
done
