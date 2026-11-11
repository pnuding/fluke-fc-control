#!/bin/bash
# Builds the release binary and wraps it into a standalone, double-clickable .app bundle. No Xcode
# project needed - built entirely via Swift Package Manager, then hand-wrapped.
#
# The .app wrapper isn't optional: the Bluetooth permission prompt only works for a real app bundle,
# not for a bare `swift run` binary.
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Fluke FC Control.app"
APP="$DIR/$APP_NAME"
BIN_NAME="FlukeFCControl"

echo "Building release binary..."
(cd "$DIR" && swift build -c release)
# Resolved, not hardcoded: the build output lands in an architecture-specific directory.
BIN_PATH="$(cd "$DIR" && swift build -c release --show-bin-path)"

echo "Bundling $APP_NAME ..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/$BIN_NAME" "$APP/Contents/MacOS/$BIN_NAME"
if [ -f "$DIR/icon.icns" ]; then
    cp "$DIR/icon.icns" "$APP/Contents/Resources/icon.icns"
fi

# Localizable.strings live outside Sources/ (not an SPM target resource) so SPM never wraps them in its own
# nested Bundle.module resource bundle - they're copied straight into Contents/Resources/<locale>.lproj here,
# like a classic Xcode-built app, so plain Bundle.main-based lookups (String(localized:), SwiftUI's Text and
# .help()) find them with no bundle plumbing in the source.
cp -R "$DIR/Localization/"*.lproj "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$BIN_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.fluke.fc.control</string>
    <key>CFBundleName</key>
    <string>Fluke FC Control</string>
    <key>CFBundleDisplayName</key>
    <string>Fluke FC Control</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleIconFile</key>
    <string>icon.icns</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>de</string>
        <string>es</string>
        <string>ca</string>
        <string>fr</string>
        <string>pt-PT</string>
        <string>nl</string>
        <string>it</string>
        <string>pl</string>
        <string>cs</string>
        <string>da</string>
        <string>sv</string>
        <string>nb</string>
        <string>fi</string>
        <string>zh-Hans</string>
        <string>ja</string>
        <string>pt-BR</string>
        <string>ko</string>
    </array>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Fluke FC Control connects to your Fluke Connect multimeters and adapters over Bluetooth to show their live readings. The only thing it sends is the connection number the meter shows as ID#; it never changes a meter's settings.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built: $APP"
du -sh "$APP"
