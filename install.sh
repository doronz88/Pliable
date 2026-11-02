#!/bin/sh
# Builds Pliable.app and installs it into /Applications (or $DEST), then registers it with Launch Services so
# Finder offers it for plists and Quick Look picks up its preview extension. Does not change file associations
# (use Pliable → Make Pliable the Default Plist Editor for that).
#   ./install.sh                        build and install into /Applications
#   DEST=~/Applications ./install.sh    install somewhere else
#   NO_BUILD=1 ./install.sh             install the existing build/Pliable.app
#   VERSION=1.2.0 ./install.sh          version to stamp (default: the latest v* git tag)
# A copy installed by this script is replaced; any other existing copy is moved to the Trash. A running Pliable is asked to quit first.
set -eu
cd "$(dirname "$0")"

DEST="${DEST:-/Applications}"
TARGET="$DEST/Pliable.app"
APPEX="$TARGET/Contents/PlugIns/PliableQuickLook.appex"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Version: $VERSION, else the latest release tag (so a local build doesn't look older than the release it replaces).
if [ -z "${VERSION:-}" ]; then
    VERSION=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//') || VERSION=""
fi
[ "${NO_BUILD:-0}" = "1" ] || VERSION="$VERSION" ./build.sh
[ -d build/Pliable.app ] || { echo "build/Pliable.app is missing; run ./build.sh" >&2; exit 1; }
mkdir -p "$DEST"

# Quit a running Pliable normally (it asks about unsaved changes) and wait for it.
if pgrep -xq Pliable; then
    echo "Quitting Pliable…"
    osascript -e 'tell application id "com.doronz88.Pliable" to quit' >/dev/null 2>&1 || true
    i=0
    while pgrep -xq Pliable; do
        i=$((i + 1))
        if [ $i -gt 30 ]; then echo "Pliable is still running; quit it and run again." >&2; exit 1; fi
        sleep 1
    done
fi

# A copy this script installed earlier (tagged below) is replaced; anything else (e.g. a Homebrew install) goes
# to the Trash so it can be recovered.
MARK=com.doronz88.pliable.install-sh
if [ -e "$TARGET" ]; then
    if xattr -p "$MARK" "$TARGET" >/dev/null 2>&1; then
        "$LSREGISTER" -u "$TARGET" 2>/dev/null || true
        rm -rf "$TARGET"
    else
        old="$HOME/.Trash/Pliable $(date +%Y-%m-%d\ %H.%M.%S).app"
        mv "$TARGET" "$old"
        "$LSREGISTER" -u "$old" 2>/dev/null || true
        echo "Moved the previous $TARGET to the Trash"
    fi
fi
ditto build/Pliable.app "$TARGET"
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
xattr -w "$MARK" 1 "$TARGET"

"$LSREGISTER" -f -R -trusted "$TARGET"
pluginkit -a "$APPEX" 2>/dev/null || true

# Checks: signature, version, and that macOS sees the Quick Look extension.
codesign --verify --deep --strict "$TARGET"
version=$(defaults read "$TARGET/Contents/Info.plist" CFBundleShortVersionString)
echo "Installed Pliable $version at $TARGET"
if pluginkit -m -p com.apple.quicklook.preview 2>/dev/null | grep -q com.doronz88.Pliable.QuickLook; then
    echo "Quick Look extension registered (press Space on a plist in Finder)"
else
    echo "Quick Look extension not registered yet: open Pliable once, or enable it in System Settings → General → Login Items & Extensions → Quick Look" >&2
fi
