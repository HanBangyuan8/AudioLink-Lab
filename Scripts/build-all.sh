#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

for package in AudioLinkCore AudioLinkDSP AudioLinkRealtime AudioLinkStorage AudioLinkNetworking AudioLinkReporting AudioLinkPlugin AudioLinkSignalPath AudioLinkAdaptive AudioLinkSpatial AudioLinkDistributed AudioLinkBundle AudioLinkPlatform AudioLinkAutomation; do
    echo "Building $package"
    swift build --package-path "$ROOT_DIR/Packages/$package" -Xswiftc -warnings-as-errors
done

echo "Building AudioLinkMac"
swift build --package-path "$ROOT_DIR/Apps/AudioLinkMac" -Xswiftc -warnings-as-errors

echo "Building AudioLinkMobile host companion target"
swift build --package-path "$ROOT_DIR/Apps/AudioLinkMobile" -Xswiftc -warnings-as-errors

echo "Building AudioLinkBenchmarks"
swift build --package-path "$ROOT_DIR/Benchmarks/AudioLinkBenchmarks" -Xswiftc -warnings-as-errors
