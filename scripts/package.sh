#!/bin/bash
#
# Builds an isolated development bundle by default. Use --stable for the local stable release.
# Usage: scripts/package.sh [--stable|--dev] [--open]
#
set -euo pipefail
cd "$(dirname "$0")/.."

CHANNEL="${TIC_BUILD_CHANNEL:-development}"
OPEN_APP=false
for arg in "$@"; do
    case "$arg" in
        --stable) CHANNEL=stable ;;
        --dev) CHANNEL=development ;;
        --open) OPEN_APP=true ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done
case "$CHANNEL" in
    stable) DIST="dist/stable"; APP_NAME="Tico"; BUNDLE_ID="com.kasvith.tic"; DISPLAY_NAME="Tico" ;;
    development) DIST="dist/development"; APP_NAME="Tico Dev"; BUNDLE_ID="com.kasvith.tic.dev"; DISPLAY_NAME="Tico 测试版" ;;
    *) echo "Unknown channel: $CHANNEL" >&2; exit 1 ;;
esac
APP="$DIST/$APP_NAME.app"

echo "▸ Building release…"
BUILD_ARGS=(-c release)
if [[ "${TICO_UNIVERSAL:-0}" == "1" ]]; then
    BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi
swift build "${BUILD_ARGS[@]}"
RELEASE_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

echo "▸ Assembling $APP_NAME.app…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$RELEASE_DIR/Tic" "$APP/Contents/MacOS/Tic"
cp "Packaging/Info.plist"   "$APP/Contents/Info.plist"
cp "Assets/AppIcon/Tic.icns" "$APP/Contents/Resources/AppIcon.icns"
cp -R Packaging/Localizations/*.lproj "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

bundles_found=0

# SwiftPM resource bundle(s) (menu-bar icon, dependency privacy manifests, etc.).
# Keep them in Contents/Resources, which is the signed app-bundle resource area.
for bundle in "$RELEASE_DIR"/*.bundle; do
    [ -e "$bundle" ] || continue
    bundles_found=1
    cp -R "$bundle" "$APP/Contents/Resources/"
done

if [ "$bundles_found" -eq 0 ]; then
    echo "error: no SwiftPM resource bundles found in $RELEASE_DIR" >&2
    exit 1
fi

if [ ! -f "$APP/Contents/Resources/Tic_Tic.bundle/MenuBarIcon.png" ] && \
   [ ! -f "$APP/Contents/Resources/Tic_Tic.bundle/Contents/Resources/MenuBarIcon.png" ]; then
    echo "error: missing packaged menu bar icon bundle" >&2
    exit 1
fi

VERSION="${VERSION:-1.0.11}"
echo "▸ Stamping ${CHANNEL} version ${VERSION}…"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_VERSION:-12}" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_ID}" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName ${APP_NAME}" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ${DISPLAY_NAME}" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :TicUpstreamUpdatesEnabled bool false' "$APP/Contents/Info.plist"

echo "▸ Code signing (ad-hoc)…"
codesign --force --sign - "$APP"

echo "▸ Verifying signature…"
codesign --verify --strict "$APP"
if [[ "${TICO_UNIVERSAL:-0}" == "1" ]]; then
    lipo -verify_arch arm64 x86_64 "$APP/Contents/MacOS/Tic"
fi

echo "✓ Built $APP"
codesign -dv "$APP" 2>&1 | sed 's/^/    /' || true

if $OPEN_APP; then
    echo "▸ Launching…"
    open "$APP"
fi
