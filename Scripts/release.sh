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
RELEASE_STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/audiolink-release.XXXXXX")"
trap 'rm -rf "$RELEASE_STAGE_DIR"' EXIT

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
ARTIFACT_DIR="$ROOT_DIR/dist"
mkdir -p "$ARTIFACT_DIR"

echo "== Universal macOS CLI =="
CLI_PACKAGE_DIR="$ROOT_DIR/Packages/AudioLinkAutomation"
if [[ "$(uname -s)" == "Darwin" ]]; then
    CLI_ARM_SCRATCH="$RELEASE_STAGE_DIR/cli-arm64"
    CLI_X86_SCRATCH="$RELEASE_STAGE_DIR/cli-x86_64"
    swift build --package-path "$CLI_PACKAGE_DIR" --product audiolink \
        --triple arm64-apple-macosx13.0 --scratch-path "$CLI_ARM_SCRATCH" \
        -Xswiftc -warnings-as-errors
    swift build --package-path "$CLI_PACKAGE_DIR" --product audiolink \
        --triple x86_64-apple-macosx13.0 --scratch-path "$CLI_X86_SCRATCH" \
        -Xswiftc -warnings-as-errors
    CLI_ARM_BIN_DIR="$(swift build --package-path "$CLI_PACKAGE_DIR" --product audiolink \
        --triple arm64-apple-macosx13.0 --scratch-path "$CLI_ARM_SCRATCH" --show-bin-path)"
    CLI_X86_BIN_DIR="$(swift build --package-path "$CLI_PACKAGE_DIR" --product audiolink \
        --triple x86_64-apple-macosx13.0 --scratch-path "$CLI_X86_SCRATCH" --show-bin-path)"
    CLI_ARTIFACT="$ARTIFACT_DIR/AudioLink-Lab-v${VERSION}-macOS-universal-cli"
    lipo -create "$CLI_ARM_BIN_DIR/audiolink" "$CLI_X86_BIN_DIR/audiolink" -output "$CLI_ARTIFACT"
else
    CLI_BIN_DIR="$(swift build --package-path "$CLI_PACKAGE_DIR" --product audiolink --show-bin-path)"
    CLI_ARTIFACT="$ARTIFACT_DIR/AudioLink-Lab-v${VERSION}-macOS-$(uname -m)-cli"
    cp "$CLI_BIN_DIR/audiolink" "$CLI_ARTIFACT"
fi
chmod +x "$CLI_ARTIFACT"
shasum -a 256 "$CLI_ARTIFACT" > "$CLI_ARTIFACT.sha256"

echo "== macOS app archive and DMG (unsigned/ad-hoc app) =="
APP_PATH="$("$ROOT_DIR/Scripts/package-app.sh" release | tail -n 1)"
PACKAGE_OUTPUT="$(AUDIO_LINK_APP_PATH="$APP_PATH" AUDIO_LINK_VERSION="$VERSION" \
    "$ROOT_DIR/Scripts/package-dmg.sh" release)"
ARCHIVE="$(printf '%s\n' "$PACKAGE_OUTPUT" | sed -n '1p')"
DMG="$(printf '%s\n' "$PACKAGE_OUTPUT" | sed -n '2p')"
shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"
shasum -a 256 "$DMG" > "$DMG.sha256"

echo "== iOS companion simulator artifact (not an IPA) =="
IOS_ARTIFACT=""
if [[ "$(uname -s)" == "Darwin" ]] && command -v xcrun >/dev/null 2>&1; then
    IOS_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
    IOS_VERSION="$(xcrun --sdk iphonesimulator --show-sdk-platform-version)"
    IOS_ARM_SCRATCH="$RELEASE_STAGE_DIR/ios-arm64"
    IOS_X86_SCRATCH="$RELEASE_STAGE_DIR/ios-x86_64"
    swift build --package-path "$ROOT_DIR/Apps/AudioLinkMobile" --sdk "$IOS_SDK" \
        --triple "arm64-apple-ios${IOS_VERSION}-simulator" --scratch-path "$IOS_ARM_SCRATCH" \
        -Xswiftc -warnings-as-errors
    swift build --package-path "$ROOT_DIR/Apps/AudioLinkMobile" --sdk "$IOS_SDK" \
        --triple "x86_64-apple-ios${IOS_VERSION}-simulator" --scratch-path "$IOS_X86_SCRATCH" \
        -Xswiftc -warnings-as-errors
    IOS_ARM_BIN_DIR="$(swift build --package-path "$ROOT_DIR/Apps/AudioLinkMobile" --sdk "$IOS_SDK" \
        --triple "arm64-apple-ios${IOS_VERSION}-simulator" --scratch-path "$IOS_ARM_SCRATCH" --show-bin-path)"
    IOS_X86_BIN_DIR="$(swift build --package-path "$ROOT_DIR/Apps/AudioLinkMobile" --sdk "$IOS_SDK" \
        --triple "x86_64-apple-ios${IOS_VERSION}-simulator" --scratch-path "$IOS_X86_SCRATCH" --show-bin-path)"
    IOS_ROOT="$RELEASE_STAGE_DIR/AudioLink-Lab-v${VERSION}-iOS-companion-simulator-universal"
    mkdir -p "$IOS_ROOT"
    lipo -create "$IOS_ARM_BIN_DIR/AudioLinkMobile" "$IOS_X86_BIN_DIR/AudioLinkMobile" \
        -output "$IOS_ROOT/AudioLinkMobile"
    chmod +x "$IOS_ROOT/AudioLinkMobile"
    cat > "$IOS_ROOT/README.txt" <<EOF
AudioLink Lab iOS companion simulator build
============================================
This is an unsigned universal (arm64 + x86_64) iOS Simulator executable.
It is not an installable iPhone/iPad IPA and does not include distribution signing.
Build the Apps/AudioLinkMobile package with Xcode for a device archive.
EOF
    IOS_ARTIFACT="$ARTIFACT_DIR/AudioLink-Lab-v${VERSION}-iOS-companion-simulator-universal.zip"
    rm -f "$IOS_ARTIFACT" "$IOS_ARTIFACT.sha256"
    ditto -c -k --sequesterRsrc --keepParent "$IOS_ROOT" "$IOS_ARTIFACT"
    shasum -a 256 "$IOS_ARTIFACT" > "$IOS_ARTIFACT.sha256"
else
    echo "iOS Simulator SDK unavailable; no iOS binary artifact generated." >&2
fi

echo "== Source archive =="
SOURCE_ARCHIVE="$ARTIFACT_DIR/AudioLink-Lab-v${VERSION}-source.zip"
SOURCE_CHECKSUM="$SOURCE_ARCHIVE.sha256"
rm -f "$SOURCE_ARCHIVE" "$SOURCE_CHECKSUM"
(
    cd "$ROOT_DIR"
    zip -q -r "$SOURCE_ARCHIVE" . \
        -x '.git/*' '*/.git/*' '.build/*' '*/.build/*' \
        -x '.swiftpm/*' '*/.swiftpm/*' '.venv-validation/*' '*/.venv-validation/*' \
        -x 'dist/*' '*/dist/*' 'Validation/results/*' 'Validation/generated/*' \
        -x 'Resources/AppIcon.iconset/*' 'Resources/AppIcon.iconset' \
        -x 'Validation/BlindCases/generated/*' 'Validation/fixtures/*.wav' \
        -x 'Validation/fixtures/*.png' 'Benchmarks/results/*' \
        -x '.DS_Store' '*/.DS_Store'
)
shasum -a 256 "$SOURCE_ARCHIVE" > "$SOURCE_CHECKSUM"

IOS_MANIFEST_VALUE="null"
if [[ -n "$IOS_ARTIFACT" ]]; then IOS_MANIFEST_VALUE="\"$(basename "$IOS_ARTIFACT")\""; fi
SOURCE_HASH="$(shasum -a 256 "$SOURCE_ARCHIVE" | awk '{print $1}')"

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
  "platforms": {
    "macOS": "universal arm64+x86_64",
    "iOS": "companion simulator artifact only; no signed device IPA"
  },
  "macOSAppArtifact": "$(basename "$ARCHIVE")",
  "macOSDMGArtifact": "$(basename "$DMG")",
  "macOSCLIArtifact": "$(basename "$CLI_ARTIFACT")",
  "iOSSimulatorArtifact": $IOS_MANIFEST_VALUE,
  "sourceArtifact": "$(basename "$SOURCE_ARCHIVE")",
  "sourceArchiveSHA256": "$SOURCE_HASH",
  "signed": false,
  "notarized": false,
  "validation": "$([[ "$SKIP_VALIDATION" -eq 1 ]] && echo skipped || echo requested)"
}
EOF

echo "Release artifacts: $ARTIFACT_DIR"
