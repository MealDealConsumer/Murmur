#!/bin/bash
# Builds Murmur.app, signs it with a stable local identity and installs it into /Applications
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

IDENTITY="Murmur Local Signing"
KEYCHAIN="$HOME/Library/Keychains/murmur-signing.keychain-db"
KEYCHAIN_PASS="murmur-local"

# A named identity keeps permissions across rebuilds and without one the app is signed ad hoc
SIGN_AS="-"
if [ -f "$KEYCHAIN" ] && security find-identity -p codesigning | grep -q "$IDENTITY"; then
  security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
  SIGN_AS="$IDENTITY"
fi
echo "signing as: $SIGN_AS"

swift build -c release

APP="$ROOT/build/Murmur.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources/llama"
cp .build/release/Murmur "$APP/Contents/MacOS/Murmur"
cp -R Vendor/whisper.xcframework/macos-arm64_x86_64/whisper.framework "$APP/Contents/Frameworks/"
cp -a Vendor/llama/llama-server Vendor/llama/*.dylib Vendor/llama/LICENSE "$APP/Contents/Resources/llama/"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ ! -f "$ROOT/build/AppIcon.icns" ]; then
  swift scripts/make-icon.swift "$ROOT/build/AppIcon.iconset"
  iconutil -c icns "$ROOT/build/AppIcon.iconset" -o "$ROOT/build/AppIcon.icns"
fi
cp "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

sign() { codesign --force --sign "$SIGN_AS" --timestamp=none "$@"; }
for lib in "$APP"/Contents/Resources/llama/*.dylib; do [ -L "$lib" ] || sign "$lib"; done
sign "$APP/Contents/Resources/llama/llama-server"
sign "$APP/Contents/Frameworks/whisper.framework"
sign --identifier local.murmur.dictation "$APP"
codesign --verify --deep --strict "$APP"
echo "built $APP"

if [ "${1:-}" = "--install" ]; then
  pkill -x Murmur 2>/dev/null || true
  # Murmur quits cleanly on this signal and stops its correction server on the way out
  for _ in $(seq 1 20); do pgrep -x Murmur >/dev/null || break; sleep 0.25; done
  rm -rf /Applications/Murmur.app
  cp -R "$APP" /Applications/Murmur.app
  echo "installed /Applications/Murmur.app"
  # The murmur command lets any terminal or chat change the dictionary
  mkdir -p "$HOME/.local/bin"
  printf '#!/bin/sh\nexec /Applications/Murmur.app/Contents/MacOS/Murmur --dictionary "$@"\n' > "$HOME/.local/bin/murmur"
  chmod +x "$HOME/.local/bin/murmur"
  echo "installed $HOME/.local/bin/murmur"
fi
