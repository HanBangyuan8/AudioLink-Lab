#!/usr/bin/env bash
set -euo pipefail

PRODUCT_NAME="AudioLink Lab"
EXECUTABLE_NAME="AudioLinkMac"
BUNDLE_IDENTIFIER="com.han.AudioLinkLab"
VERSION="${AUDIO_LINK_VERSION:-1.0.0}"
BUILD_VERSION="${AUDIO_LINK_BUILD_VERSION:-1}"
CONFIGURATION="${1:-release}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/audiolink-lab.XXXXXX")"
export CLANG_MODULE_CACHE_PATH="$STAGE_DIR/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
APP_DIR="$STAGE_DIR/$PRODUCT_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

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

assert_no_user_cache_payload() {
    local bundle_path="$1"
    if find "$bundle_path" \( -name "*.sqlite" -o -name "*.json" -o -name "*Cache*" -o -name "*cache*" \) -print -quit | grep -q .; then
        echo "Refusing to package generated state or user cache inside $bundle_path" >&2
        exit 1
    fi
}

if [[ "$(uname -s)" == "Darwin" ]]; then
    ARM_SCRATCH="$STAGE_DIR/build-arm64"
    X86_SCRATCH="$STAGE_DIR/build-x86_64"
    swift build --package-path "$ROOT_DIR/Apps/AudioLinkMac" -c "$CONFIGURATION" \
        --triple arm64-apple-macosx13.0 --scratch-path "$ARM_SCRATCH"
    swift build --package-path "$ROOT_DIR/Apps/AudioLinkMac" -c "$CONFIGURATION" \
        --triple x86_64-apple-macosx13.0 --scratch-path "$X86_SCRATCH"
    ARM_BIN_DIR="$(swift build --package-path "$ROOT_DIR/Apps/AudioLinkMac" -c "$CONFIGURATION" \
        --triple arm64-apple-macosx13.0 --scratch-path "$ARM_SCRATCH" --show-bin-path)"
    X86_BIN_DIR="$(swift build --package-path "$ROOT_DIR/Apps/AudioLinkMac" -c "$CONFIGURATION" \
        --triple x86_64-apple-macosx13.0 --scratch-path "$X86_SCRATCH" --show-bin-path)"
    lipo -create "$ARM_BIN_DIR/$EXECUTABLE_NAME" "$X86_BIN_DIR/$EXECUTABLE_NAME" \
        -output "$STAGE_DIR/$EXECUTABLE_NAME"
    BIN_PATH="$STAGE_DIR/$EXECUTABLE_NAME"
else
    swift build --package-path "$ROOT_DIR/Apps/AudioLinkMac" -c "$CONFIGURATION"
    BIN_DIR="$(swift build --package-path "$ROOT_DIR/Apps/AudioLinkMac" -c "$CONFIGURATION" --show-bin-path)"
    BIN_PATH="$BIN_DIR/$EXECUTABLE_NAME"
fi

if [[ ! -x "$BIN_PATH" ]]; then
    echo "Built executable not found: $BIN_PATH" >&2
    exit 1
fi

if command -v lipo >/dev/null 2>&1; then
    ARCHS="$(lipo -archs "$BIN_PATH" 2>/dev/null || true)"
else
    ARCHS="$(uname -m)"
fi
if [[ "$ARCHS" == *"arm64"* && "$ARCHS" == *"x86_64"* ]]; then
    ARCH_LABEL="universal"
elif [[ "$ARCHS" == *"arm64"* ]]; then
    ARCH_LABEL="arm64"
else
    ARCH_LABEL="x86_64"
fi
ARTIFACT_BASENAME="AudioLink-Lab-v${VERSION}-macOS-${ARCH_LABEL}"
FINAL_APP_DIR="$DIST_DIR/${ARTIFACT_BASENAME}.app"

mkdir -p "$MACOS_DIR"
cp "$BIN_PATH" "$MACOS_DIR/$EXECUTABLE_NAME"
chmod +x "$MACOS_DIR/$EXECUTABLE_NAME"
if [[ -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
    mkdir -p "$RESOURCES_DIR"
    cp "$ROOT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

plutil -create xml1 "$CONTENTS_DIR/Info.plist"
plutil -insert CFBundleDevelopmentRegion -string "en" "$CONTENTS_DIR/Info.plist"
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
plutil -insert NSSupportsAutomaticTermination -bool false "$CONTENTS_DIR/Info.plist"
plutil -insert NSMicrophoneUsageDescription -string "AudioLink Lab records the selected input only when you start a real-time latency measurement." "$CONTENTS_DIR/Info.plist"
if [[ -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
    plutil -insert CFBundleIconFile -string "AppIcon" "$CONTENTS_DIR/Info.plist"
fi

clean_bundle_metadata "$APP_DIR"
assert_no_user_cache_payload "$APP_DIR"
codesign --force --deep --sign - "$APP_DIR"
clean_bundle_metadata "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

mkdir -p "$DIST_DIR"
rm -rf "$FINAL_APP_DIR"
ditto --norsrc "$APP_DIR" "$FINAL_APP_DIR"
clean_bundle_metadata "$FINAL_APP_DIR"
assert_no_user_cache_payload "$FINAL_APP_DIR"
codesign --verify --deep "$FINAL_APP_DIR"

echo "$FINAL_APP_DIR"
