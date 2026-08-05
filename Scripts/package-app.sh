#!/usr/bin/env bash
set -euo pipefail

PRODUCT_NAME="AudioLink Lab"
EXECUTABLE_NAME="AudioLinkMac"
BUNDLE_IDENTIFIER="com.han.AudioLinkLab"
VERSION="${AUDIO_LINK_VERSION:-1.0.0}"
BUILD_VERSION="${AUDIO_LINK_BUILD_VERSION:-1}"
CONFIGURATION="${1:-release}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/Apps/AudioLinkMac"
DIST_DIR="$ROOT_DIR/dist"
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/audiolink-lab.XXXXXX")"
export CLANG_MODULE_CACHE_PATH="$STAGE_DIR/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
APP_DIR="$STAGE_DIR/$PRODUCT_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

trap 'rm -rf "$STAGE_DIR"' EXIT
mkdir -p "$CLANG_MODULE_CACHE_PATH"

clean_bundle_metadata() {
    local bundle_path="$1"
    find "$bundle_path" -name "._*" -delete
    if command -v dot_clean >/dev/null 2>&1; then
        dot_clean -m "$bundle_path"
    fi
    if command -v xattr >/dev/null 2>&1; then
        xattr -cr "$bundle_path"
        while IFS= read -r -d '' item; do
            xattr -d com.apple.FinderInfo "$item" 2>/dev/null || true
            xattr -d 'com.apple.fileprovider.fpfs#P' "$item" 2>/dev/null || true
        done < <(find "$bundle_path" -print0)
    fi
}

if [[ "$(uname -s)" == "Darwin" ]]; then
    # SwiftPM does not expose a portable multi-architecture output switch.
    # Build each supported macOS architecture in an isolated scratch tree and
    # combine the executables explicitly so the delivered app is genuinely
    # universal (rather than a host-only binary with a universal filename).
    ARM_SCRATCH="$STAGE_DIR/build-arm64"
    X86_SCRATCH="$STAGE_DIR/build-x86_64"
    swift build --package-path "$PACKAGE_DIR" -c "$CONFIGURATION" \
        --triple arm64-apple-macosx13.0 --scratch-path "$ARM_SCRATCH"
    swift build --package-path "$PACKAGE_DIR" -c "$CONFIGURATION" \
        --triple x86_64-apple-macosx13.0 --scratch-path "$X86_SCRATCH"
    ARM_BIN_DIR="$(swift build --package-path "$PACKAGE_DIR" -c "$CONFIGURATION" \
        --triple arm64-apple-macosx13.0 --scratch-path "$ARM_SCRATCH" --show-bin-path)"
    X86_BIN_DIR="$(swift build --package-path "$PACKAGE_DIR" -c "$CONFIGURATION" \
        --triple x86_64-apple-macosx13.0 --scratch-path "$X86_SCRATCH" --show-bin-path)"
    lipo -create "$ARM_BIN_DIR/$EXECUTABLE_NAME" "$X86_BIN_DIR/$EXECUTABLE_NAME" \
        -output "$STAGE_DIR/$EXECUTABLE_NAME"
    BIN_PATH="$STAGE_DIR/$EXECUTABLE_NAME"
else
    swift build --package-path "$PACKAGE_DIR" -c "$CONFIGURATION"
    BIN_DIR="$(swift build --package-path "$PACKAGE_DIR" -c "$CONFIGURATION" --show-bin-path)"
    BIN_PATH="$BIN_DIR/$EXECUTABLE_NAME"
fi
mkdir -p "$MACOS_DIR"
cp "$BIN_PATH" "$MACOS_DIR/$EXECUTABLE_NAME"
chmod +x "$MACOS_DIR/$EXECUTABLE_NAME"

plutil -create xml1 "$CONTENTS_DIR/Info.plist"
plutil -insert CFBundleDisplayName -string "$PRODUCT_NAME" "$CONTENTS_DIR/Info.plist"
plutil -insert CFBundleExecutable -string "$EXECUTABLE_NAME" "$CONTENTS_DIR/Info.plist"
plutil -insert CFBundleIdentifier -string "$BUNDLE_IDENTIFIER" "$CONTENTS_DIR/Info.plist"
plutil -insert CFBundleInfoDictionaryVersion -string "6.0" "$CONTENTS_DIR/Info.plist"
plutil -insert CFBundleName -string "$PRODUCT_NAME" "$CONTENTS_DIR/Info.plist"
plutil -insert CFBundlePackageType -string "APPL" "$CONTENTS_DIR/Info.plist"
plutil -insert CFBundleShortVersionString -string "$VERSION" "$CONTENTS_DIR/Info.plist"
plutil -insert CFBundleVersion -string "$BUILD_VERSION" "$CONTENTS_DIR/Info.plist"
plutil -insert LSMinimumSystemVersion -string "13.0" "$CONTENTS_DIR/Info.plist"
plutil -insert NSHighResolutionCapable -bool true "$CONTENTS_DIR/Info.plist"
plutil -insert NSMicrophoneUsageDescription -string "AudioLink Lab records the selected input only when you start a real-time latency measurement." "$CONTENTS_DIR/Info.plist"

clean_bundle_metadata "$APP_DIR"
codesign --force --deep --sign - "$APP_DIR"
clean_bundle_metadata "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
mkdir -p "$DIST_DIR"
rm -rf "$DIST_DIR/$PRODUCT_NAME.app"
ditto --norsrc "$APP_DIR" "$DIST_DIR/$PRODUCT_NAME.app"
clean_bundle_metadata "$DIST_DIR/$PRODUCT_NAME.app"
# The workspace may be backed by File Provider, which can immediately restore
# root-level FinderInfo metadata after cleanup. The staged bundle above receives
# the signature; verify the delivered copy without trying to mutate provider-
# owned filesystem metadata on the copied root directory.
codesign --verify --deep "$DIST_DIR/$PRODUCT_NAME.app"
echo "$DIST_DIR/$PRODUCT_NAME.app"
