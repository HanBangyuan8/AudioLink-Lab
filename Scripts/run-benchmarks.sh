#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${1:-quick}"
OUTPUT="${2:-$ROOT_DIR/Benchmarks/results/benchmark-summary.json}"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

case "$PROFILE" in
    quick|full) ;;
    *) echo "Usage: $0 [quick|full] [output-json]" >&2; exit 2 ;;
esac

swift run --package-path "$ROOT_DIR/Benchmarks/AudioLinkBenchmarks" \
    -Xswiftc -warnings-as-errors \
    AudioLinkBenchmarks --profile "$PROFILE" --output "$OUTPUT"
echo "Benchmark summary: $OUTPUT"
