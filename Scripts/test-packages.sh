#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
PACKAGES=(
    "AudioLinkCore"
    "AudioLinkDSP"
    "AudioLinkRealtime"
    "AudioLinkStorage"
    "AudioLinkNetworking"
    "AudioLinkReporting"
    "AudioLinkPlugin"
    "AudioLinkSignalPath"
    "AudioLinkAdaptive"
    "AudioLinkSpatial"
    "AudioLinkDistributed"
    "AudioLinkBundle"
    "AudioLinkPlatform"
    "AudioLinkAutomation"
)

for package in "${PACKAGES[@]}"; do
    echo "Testing $package"
    swift test --package-path "$ROOT_DIR/Packages/$package" -Xswiftc -warnings-as-errors
done

echo "Testing AudioLinkMobile host companion target"
swift test --package-path "$ROOT_DIR/Apps/AudioLinkMobile" -Xswiftc -warnings-as-errors
