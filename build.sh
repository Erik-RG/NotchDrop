#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

APP_NAME="NotchDrop"
BUILD_DIR="build"
CONTENTS_DIR="$BUILD_DIR/$APP_NAME.app/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "Building $APP_NAME..."

# Create app bundle structure
rm -rf "$BUILD_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# 1. Compile Swift code with all required macOS frameworks and -parse-as-library for @main
swiftc -o "$MACOS_DIR/$APP_NAME" \
    NotchDrop.swift \
    -parse-as-library \
    -target arm64-apple-macos13.0 \
    -framework SwiftUI \
    -framework AppKit \
    -framework ScriptingBridge \
    -framework CoreGraphics \
    -framework EventKit \
    -framework UserNotifications

# Ensure executable permissions
chmod +x "$MACOS_DIR/$APP_NAME"

# 2. Copy or Auto-Generate Info.plist
if [ -f "Info.plist" ]; then
    cp Info.plist "$CONTENTS_DIR/Info.plist"
    echo "Using existing Info.plist..."
else
    echo "Generating Info.plist..."
    cat << 'EOF' > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>NotchDrop</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.notchdrop.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>NotchDrop</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>NotchDrop uses Apple Events to control playback and read the currently playing track in Music or Spotify.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>NotchDrop shows your upcoming calendar events in the notch so you can see what is next at a glance. Events are only read, never changed or sent anywhere.</string>
    <key>NSCalendarsUsageDescription</key>
    <string>NotchDrop shows your upcoming calendar events in the notch so you can see what is next at a glance. Events are only read, never changed or sent anywhere.</string>
</dict>
</plist>
EOF
fi

# 3. Copy the app icon (must happen BEFORE signing)
if [ -f "AppIcon.icns" ]; then
    cp AppIcon.icns "$RESOURCES_DIR/AppIcon.icns"
    echo "Added app icon..."
else
    echo "Warning: AppIcon.icns not found next to build.sh; building without a custom icon."
fi

# ==============================================================================
# NEW: Copy Custom Non-Commercial License (Must happen BEFORE signing)
# ==============================================================================
if [ -f "LICENSE" ]; then
    cp LICENSE "$RESOURCES_DIR/LICENSE"
    echo "Bundled LICENSE into Resources directory..."
elif [ -f "LICENSE.txt" ]; then
    cp LICENSE.txt "$RESOURCES_DIR/LICENSE.txt"
    echo "Bundled LICENSE.txt into Resources directory..."
else
    echo "Warning: No LICENSE file found next to build.sh; building without license notice."
fi
# ==============================================================================

# 4. Ad-hoc code sign the app bundle (mandatory for macOS execution)
#
# macOS ties permissions (Calendar, ...) to the bundle ID + code signature.
# Keep CFBundleIdentifier in Info.plist unchanged between builds, and sign with a
# FIXED designated requirement (the bundle ID) instead of the default per-build hash.
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$CONTENTS_DIR/Info.plist" 2>/dev/null || echo "com.notchdrop.app")"

echo "Signing app bundle (ad-hoc, fixed requirement for $BUNDLE_ID)..."
codesign --force --deep --sign - \
    --requirements "=designated => identifier \"$BUNDLE_ID\"" \
    "$BUILD_DIR/$APP_NAME.app"

# Show the requirement macOS will use to recognise this app (should NOT be a cdhash).
codesign -d -r- "$BUILD_DIR/$APP_NAME.app" 2>&1 | grep "designated" || true

# Nudge Finder to refresh the icon
touch "$BUILD_DIR/$APP_NAME.app"

echo "Build complete! App is located at $BUILD_DIR/$APP_NAME.app"