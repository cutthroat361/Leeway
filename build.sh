#!/usr/bin/env bash
# Builds Leeway.app for macOS 11 Big Sur and newer: one universal app (Apple Silicon + Intel)
# when your Apple tools can still build for Intel, otherwise Apple Silicon only.
#
#   bash build.sh              build into ./build
#   bash build.sh --install    build, copy to /Applications, and open it
#
# Optional settings, for sharing the app with other people:
#   VERSION=1.2.0                                                   version shown in the app
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"    sign with your Apple Developer ID
#   NOTARY_PROFILE=leeway                                           notarize with a saved login (see README)
#   NOTARY_APPLE_ID, NOTARY_TEAM_ID, NOTARY_PASSWORD                 or notarize with these (used by GitHub releases)
set -euo pipefail

APP_NAME="Leeway"
BUNDLE_ID="${BUNDLE_ID:-io.github.cutthroat361.leeway}"
VERSION="${VERSION:-1.3.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
MIN_MACOS="11.0"

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/$APP_NAME.app"
WIDGET_NAME="LeewayWidget"
APPEX="$APP/Contents/PlugIns/$WIDGET_NAME.appex"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Swift isn't installed yet. Run this, wait for it to finish, then try again:"
  echo "  xcode-select --install"
  exit 1
fi
SDK="$(xcrun --sdk macosx --show-sdk-path)"

rm -rf "$BUILD"
mkdir -p "$BUILD/obj" "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APPEX/Contents/MacOS"

# The app, then its widget: a small separate program that macOS runs in a sandbox.
compile() {
  xcrun swiftc \
    -O \
    -swift-version 5 \
    -sdk "$SDK" \
    -target "$1-apple-macos$MIN_MACOS" \
    -module-name "$APP_NAME" \
    "$ROOT"/Sources/*.swift "$ROOT"/Shared/*.swift \
    -o "$BUILD/obj/$APP_NAME-$1" &&
  xcrun swiftc \
    -O \
    -swift-version 5 \
    -sdk "$SDK" \
    -target "$1-apple-macos$MIN_MACOS" \
    -module-name "$WIDGET_NAME" \
    -parse-as-library \
    -application-extension \
    "$ROOT"/Widget/*.swift "$ROOT"/Shared/*.swift \
    -o "$BUILD/obj/$WIDGET_NAME-$1"
}

echo "Compiling for Apple Silicon (arm64)..."
compile arm64

# Apple's newest tools (macOS 27 and later) can't build for Intel Macs any more.
# Then the app is built for Apple Silicon only, unless REQUIRE_UNIVERSAL=1.
echo "Compiling for Intel (x86_64)..."
if compile x86_64 > "$BUILD/obj/x86_64.log" 2>&1; then
  echo "Combining into one universal app..."
  lipo -create "$BUILD/obj/$APP_NAME-arm64" "$BUILD/obj/$APP_NAME-x86_64" \
    -output "$APP/Contents/MacOS/$APP_NAME"
  lipo -create "$BUILD/obj/$WIDGET_NAME-arm64" "$BUILD/obj/$WIDGET_NAME-x86_64" \
    -output "$APPEX/Contents/MacOS/$WIDGET_NAME"
elif [[ "${REQUIRE_UNIVERSAL:-0}" == "1" ]]; then
  cat "$BUILD/obj/x86_64.log"
  echo "The Intel build failed and REQUIRE_UNIVERSAL=1 is set. Stopping."
  exit 1
else
  echo "These Apple tools can't build for Intel Macs, so this build is for Apple Silicon only."
  echo "(That's fine for your own Mac. GitHub releases are built for both.)"
  cp "$BUILD/obj/$APP_NAME-arm64" "$APP/Contents/MacOS/$APP_NAME"
  cp "$BUILD/obj/$WIDGET_NAME-arm64" "$APPEX/Contents/MacOS/$WIDGET_NAME"
fi
rm -rf "$BUILD/obj"

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>$BUNDLE_ID</string>
      <key>CFBundleURLSchemes</key><array><string>leeway</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

cat > "$APPEX/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$WIDGET_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$WIDGET_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID.widget</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>NSExtension</key>
  <dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string>
  </dict>
</dict>
</plist>
PLIST

# The widget may only read the summary Leeway saves in its Application Support folder.
WIDGET_ENTITLEMENTS="$BUILD/widget.entitlements"
cat > "$WIDGET_ENTITLEMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.temporary-exception.files.home-relative-path.read-only</key>
  <array><string>/Library/Application Support/Leeway/</string></array>
</dict>
</plist>
PLIST

# Sign the widget first, then the app around it.
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  echo "Signing with: $SIGN_IDENTITY"
  codesign --force --options runtime --timestamp --entitlements "$WIDGET_ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" "$APPEX"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
  echo "Signing for this Mac only (ad-hoc)..."
  codesign --force --entitlements "$WIDGET_ENTITLEMENTS" --sign - "$APPEX"
  codesign --force --sign - "$APP"
fi
rm -f "$WIDGET_ENTITLEMENTS"

ZIP="$BUILD/$APP_NAME-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

# (A yes/no flag instead of checking the array's size: macOS ships bash 3.2,
# which treats an empty array as unset under "set -u".)
NOTARIZE=0
if [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_TEAM_ID:-}" && -n "${NOTARY_PASSWORD:-}" ]]; then
  NOTARIZE=1
  NOTARY_ARGS=(--apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD")
elif [[ -n "${NOTARY_PROFILE:-}" ]]; then
  NOTARIZE=1
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
fi

if [[ "$NOTARIZE" == "1" ]]; then
  if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    echo "Notarization needs SIGN_IDENTITY too. Skipping notarization."
  else
    echo "Sending to Apple for notarization (a few minutes)..."
    xcrun notarytool submit "$ZIP" "${NOTARY_ARGS[@]}" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
  fi
fi

echo
echo "Built $APP"
lipo -info "$APP/Contents/MacOS/$APP_NAME"
echo "Zip for sharing: $ZIP"

if [[ "${1:-}" == "--install" ]]; then
  echo "Installing to /Applications..."
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 1
  rm -rf "/Applications/$APP_NAME.app"
  ditto "$APP" "/Applications/$APP_NAME.app"
  # Tell macOS about the widget now, so it shows up in the widget gallery right away.
  pluginkit -a "/Applications/$APP_NAME.app/Contents/PlugIns/$WIDGET_NAME.appex" 2>/dev/null || true
  open "/Applications/$APP_NAME.app"
  echo "Done. Look for Leeway in your menu bar."
fi
