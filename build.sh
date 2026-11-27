#!/bin/zsh
# Builds SonyMenu.app (universal: Apple Silicon + Intel).
#   ./build.sh            build into build/SonyMenu.app
#   ./build.sh --install  also copy to ~/Applications and launch
#   ./build.sh --zip      also make build/SonyMenu.zip for a release
set -euo pipefail
cd "${0:A:h}"

swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/SonyMenu

APP=build/SonyMenu.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SonyMenu"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
for l in Resources/*.lproj; do cp -R "$l" "$APP/Contents/Resources/"; done
# Sign with a fixed local certificate when there is one, so macOS keeps Accessibility and
# microphone permissions across rebuilds (an ad-hoc signature looks like a new app each time).
# Create it once with ./make-signing-cert.sh.
SIGN_DIR="$HOME/.sonymenu-signing"
if [ -f "$SIGN_DIR/signing.keychain-db" ] && [ -f "$SIGN_DIR/pass" ]; then
    security unlock-keychain -p "$(cat "$SIGN_DIR/pass")" "$SIGN_DIR/signing.keychain-db"
    codesign --force --sign "SonyMenu Local Signing" --keychain "$SIGN_DIR/signing.keychain-db" "$APP"
else
    codesign --force --sign - "$APP"
fi
echo "Built: $PWD/$APP"

case "${1:-}" in
  --install)
    mkdir -p ~/Applications
    # Quit normally so the headphone control channel is closed (a killed app leaves it
    # open and the next launch waits for it to time out).
    ( osascript -e 'tell application id "local.sonymenu" to quit' >/dev/null 2>&1 &) ; sleep 2
    sleep 1
    pkill -x SonyMenu 2>/dev/null || true
    rm -rf ~/Applications/SonyMenu.app
    # Move (not copy) so Launchpad shows only one SonyMenu.
    mv "$APP" ~/Applications/
    open ~/Applications/SonyMenu.app
    echo "Installed: ~/Applications/SonyMenu.app"
    ;;
  --zip)
    rm -f build/SonyMenu.zip
    ditto -c -k --keepParent "$APP" build/SonyMenu.zip
    echo "Archive: $PWD/build/SonyMenu.zip"
    ;;
esac
