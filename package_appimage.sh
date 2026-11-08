#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
APPIMAGETOOL="${APPIMAGETOOL:-appimagetool}"
APPIMAGE_NAME="Emoji-ga.me-x86_64.AppImage"
APPDIR="$(mktemp -d "$ROOT_DIR/.appimage-work.XXXXXX")"
trap 'rm -rf "$APPDIR"' EXIT HUP INT TERM

if [ ! -x "$ROOT_DIR/emoji-ga_me" ]; then
    echo "Missing launcher binary: run python3 build_bin.py first." >&2
    exit 1
fi
if ! command -v "$APPIMAGETOOL" >/dev/null 2>&1 && [ ! -x "$APPIMAGETOOL" ]; then
    TOOL_CACHE="${TMPDIR:-/tmp}/emojiga-appimagetool-x86_64.AppImage"
    if [ ! -x "$TOOL_CACHE" ]; then
        if ! command -v curl >/dev/null 2>&1; then
            echo "curl is required to download appimagetool." >&2
            exit 1
        fi
        echo "Downloading appimagetool from the official AppImage release..."
        curl -L --fail --retry 3 \
            --output "$TOOL_CACHE.part" \
            https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
        chmod +x "$TOOL_CACHE.part"
        mv "$TOOL_CACHE.part" "$TOOL_CACHE"
    fi
    APPIMAGETOOL="$TOOL_CACHE"
fi
export APPIMAGE_EXTRACT_AND_RUN=1

mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/share/applications" \
    "$APPDIR/usr/share/icons/hicolor/scalable/apps" "$APPDIR/usr/lib/swift" \
    "$ROOT_DIR/dist"
cp "$ROOT_DIR/emoji-ga_me" "$APPDIR/usr/bin/emoji-ga_me"
cp "$ROOT_DIR/packaging/appimage/emoji-ga_me.desktop" "$APPDIR/"
cp "$ROOT_DIR/packaging/appimage/emoji-ga_me.desktop" \
    "$APPDIR/usr/share/applications/emoji-ga_me.desktop"
cp "$ROOT_DIR/packaging/appimage/emoji-ga_me.svg" "$APPDIR/"
cp "$ROOT_DIR/packaging/appimage/emoji-ga_me.svg" \
    "$APPDIR/usr/share/icons/hicolor/scalable/apps/emoji-ga_me.svg"
cp "$ROOT_DIR/packaging/appimage/emoji-ga_me.png" "$APPDIR/"
cp "$ROOT_DIR/packaging/appimage/AppRun" "$APPDIR/AppRun"

if [ -x "$ROOT_DIR/swift/.build/release/swift" ] && command -v swiftc >/dev/null 2>&1; then
    SWIFT_LIB_DIR="$(swiftc -print-target-info \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["paths"]["runtimeLibraryPaths"][0])')"
    if [ -d "$SWIFT_LIB_DIR" ]; then
        ldd "$ROOT_DIR/swift/.build/release/swift" \
            | awk '$2 == "=>" && $3 ~ /^\// { print $3 }' \
            | while IFS= read -r LIB; do
                case "$LIB" in
                    "$SWIFT_LIB_DIR"/*.so)
                        cp -L "$LIB" "$APPDIR/usr/lib/swift/"
                        ;;
                esac
            done
    fi
fi

chmod +x "$APPDIR/AppRun" "$APPDIR/usr/bin/emoji-ga_me"
chmod -R a+rX "$APPDIR"

ARCH=x86_64 "$APPIMAGETOOL" "$APPDIR" "$ROOT_DIR/dist/$APPIMAGE_NAME"
chmod +x "$ROOT_DIR/dist/$APPIMAGE_NAME"
echo "Built $ROOT_DIR/dist/$APPIMAGE_NAME"
