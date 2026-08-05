#!/usr/bin/env bash
set -euo pipefail

PRODUCT_NAME="AudioLink Lab"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
CONFIGURATION="${1:-release}"
APP_PATH="${AUDIO_LINK_APP_PATH:-}"

if [[ -z "$APP_PATH" ]]; then
    APP_PATH="$("$ROOT_DIR/Scripts/package-app.sh" "$CONFIGURATION" | tail -n 1)"
fi
if [[ ! -d "$APP_PATH" ]]; then
    echo "Packaged app not found: $APP_PATH" >&2
    exit 1
fi

ARTIFACT_BASENAME="$(basename "$APP_PATH" .app)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
ZIP_PATH="$DIST_DIR/${ARTIFACT_BASENAME}.zip"
DMG_PATH="$DIST_DIR/${ARTIFACT_BASENAME}.dmg"
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/audiolink-lab-dmg.XXXXXX")"
ZIP_APP_PATH="$STAGE_DIR/${ARTIFACT_BASENAME}.app"
DMG_ROOT="$STAGE_DIR/dmg"

clean_bundle_metadata() {
    local bundle_path="$1"
    find "$bundle_path" -name "._*" -delete
    if command -v dot_clean >/dev/null 2>&1; then
        dot_clean -m "$bundle_path"
    fi
    if command -v xattr >/dev/null 2>&1; then
        xattr -cr "$bundle_path" 2>/dev/null || true
    fi
}

trap 'rm -rf "$STAGE_DIR"' EXIT
mkdir -p "$DMG_ROOT"

ditto --norsrc "$APP_PATH" "$ZIP_APP_PATH"
clean_bundle_metadata "$ZIP_APP_PATH"
codesign --force --deep --sign - "$ZIP_APP_PATH"
clean_bundle_metadata "$ZIP_APP_PATH"
codesign --verify --deep --strict "$ZIP_APP_PATH"

rm -f "$ZIP_PATH" "$DMG_PATH"
ditto -c -k --norsrc --keepParent "$ZIP_APP_PATH" "$ZIP_PATH"
ditto --norsrc "$ZIP_APP_PATH" "$DMG_ROOT/$PRODUCT_NAME.app"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -volname "$PRODUCT_NAME $VERSION" \
    -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG_PATH" >/dev/null

printf '%s\n%s\n' "$ZIP_PATH" "$DMG_PATH"
