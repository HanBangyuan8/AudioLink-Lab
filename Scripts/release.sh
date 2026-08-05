#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${AUDIO_LINK_VERSION:-1.0.0}"
BUILD_VERSION="${AUDIO_LINK_BUILD_VERSION:-1}"
PROFILE="${AUDIO_LINK_VALIDATION_PROFILE:-quick}"
SKIP_VALIDATION=0
for argument in "$@"; do
    if [[ "$argument" == "--skip-validation" ]]; then SKIP_VALIDATION=1; fi
done

export AUDIO_LINK_VERSION="$VERSION"
export AUDIO_LINK_BUILD_VERSION="$BUILD_VERSION"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

echo "== Clean package build artifacts =="
for package in AudioLinkCore AudioLinkDSP AudioLinkRealtime AudioLinkStorage AudioLinkNetworking AudioLinkReporting AudioLinkPlugin AudioLinkSignalPath AudioLinkAdaptive AudioLinkSpatial AudioLinkDistributed AudioLinkBundle AudioLinkPlatform AudioLinkAutomation; do
    swift package clean --package-path "$ROOT_DIR/Packages/$package"
done
swift package clean --package-path "$ROOT_DIR/Apps/AudioLinkMac"
swift package clean --package-path "$ROOT_DIR/Apps/AudioLinkMobile"
swift package clean --package-path "$ROOT_DIR/Benchmarks/AudioLinkBenchmarks"

echo "== Tests and host builds =="
"$ROOT_DIR/Scripts/test-packages.sh"
"$ROOT_DIR/Scripts/build-all.sh"

if [[ "$SKIP_VALIDATION" -eq 0 ]]; then
    echo "== DSP validation ($PROFILE) =="
    python3 "$ROOT_DIR/Validation/run_validation.py" --workspace "$ROOT_DIR" --profile "$PROFILE" --output "$ROOT_DIR/Validation/results/$VERSION"
else
    echo "== DSP validation skipped by explicit flag =="
fi

echo "== Unsigned/ad-hoc macOS artifact =="
"$ROOT_DIR/Scripts/package-app.sh" release
ARTIFACT_DIR="$ROOT_DIR/dist/releases/$VERSION"
mkdir -p "$ARTIFACT_DIR"
CLI_BIN_DIR="$(swift build --package-path "$ROOT_DIR/Packages/AudioLinkAutomation" --product audiolink --show-bin-path)"
cp "$CLI_BIN_DIR/audiolink" "$ARTIFACT_DIR/audiolink"
shasum -a 256 "$ARTIFACT_DIR/audiolink" > "$ARTIFACT_DIR/audiolink.sha256"
ARCHIVE="$ARTIFACT_DIR/AudioLinkLab-macOS-$VERSION-build-$BUILD_VERSION.zip"
rm -f "$ARCHIVE" "$ARCHIVE.sha256"
ditto -c -k --sequesterRsrc --keepParent "$ROOT_DIR/dist/AudioLink Lab.app" "$ARCHIVE"
shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"

cat > "$ARTIFACT_DIR/release-manifest.json" <<EOF
{
  "appVersion": "$VERSION",
  "buildVersion": "$BUILD_VERSION",
  "algorithmVersion": "correlation-v2-dsp-audit",
  "protocolVersion": "1.0",
  "reportSchemaVersion": "1.0",
  "bundleSchemaVersion": "1.0",
  "moduleSchemaVersion": "1.0",
  "automationAPIVersion": "1.0",
  "databaseSchemaVersion": 5,
  "artifact": "$(basename "$ARCHIVE")",
  "signed": false,
  "notarized": false,
  "validation": "$([[ "$SKIP_VALIDATION" -eq 1 ]] && echo skipped || echo requested)"
}
EOF

echo "Release artifacts: $ARTIFACT_DIR"
