#!/bin/bash
# Builds ClipFarm.app. Pass --install to put it in /Applications and launch it.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP_NAME="ClipFarm"
BUNDLE_ID="dev.haelp.clipfarm"
VERSION="1.0.0"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

echo "Compiling"
swift build -c release --arch arm64 --arch x86_64 2>/dev/null \
  || swift build -c release

BINARY="$(swift build -c release --show-bin-path)/$APP_NAME"
[ -f "$BINARY" ] || { echo "No binary at $BINARY"; exit 1; }

echo "Assembling the bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Screen recording permission is tied to the signature. An ad-hoc signature changes
# on every build, so macOS treats each build as a different app and asks again. Signing
# with a stable certificate keeps the grant across rebuilds.
#
# SIGN_IDENTITY picks the certificate. Scripts/make-signing-identity.sh creates a local
# one if you do not have a Developer ID.
SIGN_IDENTITY="${SIGN_IDENTITY:-ClipFarm Local Signing}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
  echo "Signing as $SIGN_IDENTITY"
else
  echo "Signing ad hoc, since no $SIGN_IDENTITY certificate was found"
  echo "  macOS will ask for screen recording permission again after each build."
  echo "  Run Scripts/make-signing-identity.sh once to avoid that."
  SIGN_IDENTITY="-"
fi

codesign --force --deep --sign "$SIGN_IDENTITY" \
  --entitlements "$ROOT/Resources/ClipFarm.entitlements" \
  --options runtime \
  "$APP" 2>&1 | sed 's/^/  /'

codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/  /'
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
  echo "Installing to /Applications"
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 1
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" "/Applications/$APP_NAME.app"
  # Clear the quarantine flag so the copy opens without a Gatekeeper prompt.
  xattr -dr com.apple.quarantine "/Applications/$APP_NAME.app" 2>/dev/null || true
  echo "Installed /Applications/$APP_NAME.app"
  open "/Applications/$APP_NAME.app"
  echo "Launched"
fi
