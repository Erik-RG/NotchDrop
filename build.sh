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
    -framework CoreGraphics

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
    <key>CFBundleIdentifier</key>
    <string>com.local.NotchDrop</string>
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
</dict>
</plist>
EOF
fi

# 3. Ad-hoc code sign the app bundle (Mandatory for macOS execution)
echo "Signing app bundle..."
codesign --force --deep --sign - "$BUILD_DIR/$APP_NAME.app"

echo "Build complete! App is located at $BUILD_DIR/$APP_NAME.app"