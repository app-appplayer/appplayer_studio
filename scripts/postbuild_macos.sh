#!/usr/bin/env bash
#
# Post-build patch for the macOS .app bundle. Two adjustments:
#
# 1. `ffmpeg_kit_flutter_new`'s arm64 slice links `libz` against the
#    Homebrew install path that gets baked into the upstream build
#    (`/opt/homebrew/opt/zlib/lib/libz.1.dylib`). Most user machines
#    don't have Homebrew zlib at that exact path, so the framework
#    fails to load on launch. We rewrite the install-name to the
#    system zlib (`/usr/lib/libz.1.dylib`) which every macOS ships.
#
# 2. Codesign is invalidated by the install_name_tool rewrite —
#    re-sign with ad-hoc identity so Gatekeeper still loads the
#    app on dev machines.
#
# Run after every `flutter build macos --release`. CI / package
# distribution should also call this before shipping the .app.

set -e

DEFAULT_APP="$(cd "$(dirname "$0")/.." && pwd)/build/macos/Build/Products/Release/vibe_studio.app"
APP="${1:-$DEFAULT_APP}"

if [ ! -d "$APP" ]; then
  echo "Not a directory: $APP" >&2
  exit 1
fi

FRAMEWORKS="$APP/Contents/Frameworks"
if [ ! -d "$FRAMEWORKS" ]; then
  echo "Frameworks dir missing — wrong app path? $FRAMEWORKS" >&2
  exit 1
fi

echo "Patching ffmpeg_kit dylibs in: $APP"
patched=0
for f in "$FRAMEWORKS"/*.framework/Versions/A/*; do
  if [ ! -f "$f" ]; then continue; fi
  if otool -L "$f" 2>/dev/null | grep -q "/opt/homebrew/opt/zlib"; then
    install_name_tool \
      -change /opt/homebrew/opt/zlib/lib/libz.1.dylib \
              /usr/lib/libz.1.dylib \
      "$f" 2>/dev/null
    echo "  patched: $(basename "$(dirname "$(dirname "$f")")")"
    patched=$((patched + 1))
  fi
done

if [ "$patched" -gt 0 ]; then
  echo "Re-signing $patched dylib(s) with ad-hoc identity..."
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1
  echo "Done."
else
  echo "No dylibs needed patching."
fi
