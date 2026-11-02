#!/bin/sh
# Builds Pliable.app (with its Quick Look extension) into ./build. Does not install it or change any file associations.
#   VERSION=1.2.0 ./build.sh     set CFBundleShortVersionString / CFBundleVersion
#   UNIVERSAL=1 ./build.sh       build for arm64 and x86_64
set -eu
cd "$(dirname "$0")"

ARCH_FLAGS=""
if [ "${UNIVERSAL:-0}" = "1" ]; then
    ARCH_FLAGS="--arch arm64 --arch x86_64"
fi

for product in Pliable PliableQuickLook; do
    # shellcheck disable=SC2086
    swift build -c release --product "$product" $ARCH_FLAGS
done
# shellcheck disable=SC2086
BIN_DIR="$(swift build -c release $ARCH_FLAGS --show-bin-path)"

APP=build/Pliable.app
APPEX="$APP/Contents/PlugIns/PliableQuickLook.appex"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APPEX/Contents/MacOS"
cp "$BIN_DIR/Pliable" "$APP/Contents/MacOS/Pliable"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp "$BIN_DIR/PliableQuickLook" "$APPEX/Contents/MacOS/PliableQuickLook"
cp Resources/QuickLook-Info.plist "$APPEX/Contents/Info.plist"
if [ -n "${VERSION:-}" ]; then
    for plist in "$APP/Contents/Info.plist" "$APPEX/Contents/Info.plist"; do
        plutil -replace CFBundleShortVersionString -string "$VERSION" "$plist"
        plutil -replace CFBundleVersion -string "$VERSION" "$plist"
    done
fi
# Sign inside out: the extension (sandboxed, as macOS requires for app extensions) before the app that contains it.
codesign --force --sign - --entitlements Resources/QuickLook.entitlements "$APPEX"
codesign --force --sign - "$APP"
echo "Built $APP"
