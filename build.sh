#!/bin/bash

# NotchMusic Build Script
# This script builds the NotchMusic macOS app from source into a .app bundle

set -e

echo "🎵 Building NotchMusic..."

# Check if Xcode is installed
if ! command -v xcodebuild &> /dev/null; then
    echo "❌ Xcode is not installed. Please install Xcode from the App Store or visit https://developer.apple.com/download/"
    exit 1
fi

# Get the directory where the script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BUILD_DIR="$SCRIPT_DIR/build"
APP_BUNDLE="$BUILD_DIR/NotchMusic.app"

# Clean previous builds
if [ -d "$BUILD_DIR" ]; then
    echo "🗑️  Cleaning previous builds..."
    rm -rf "$BUILD_DIR"
fi

mkdir -p "$BUILD_DIR"

echo "📁 Creating app bundle structure..."

# Create the app bundle structure
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Create Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>NotchMusic</string>
    <key>CFBundleIdentifier</key>
    <string>com.notchmusic.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>NotchMusic</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "⚙️  Compiling Swift source files..."

# Determine architecture
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    TARGET_TRIPLE="arm64-apple-macosx11"
else
    TARGET_TRIPLE="x86_64-apple-macosx11"
fi

# Compile all Swift files into a single executable
swiftc \
    -target "$TARGET_TRIPLE" \
    -parse-as-library \
    -suppress-warnings \
    "$SCRIPT_DIR/NotchMusicApp.swift" \
    "$SCRIPT_DIR/AppDelegate.swift" \
    "$SCRIPT_DIR/NotchViewModel.swift" \
    "$SCRIPT_DIR/NotchContentView.swift" \
    "$SCRIPT_DIR/FileDropTray.swift" \
    -framework Cocoa \
    -framework SwiftUI \
    -framework MediaPlayer \
    -o "$APP_BUNDLE/Contents/MacOS/NotchMusic" 2>&1 | grep -v "warning:" || true

# Check if compilation was successful
if [ ! -f "$APP_BUNDLE/Contents/MacOS/NotchMusic" ]; then
    echo "❌ Compilation failed. Trying alternative build method..."
    exit 1
fi

# Make the executable executable (should already be, but just in case)
chmod +x "$APP_BUNDLE/Contents/MacOS/NotchMusic"

echo "✅ Build complete!"
echo ""
echo "📦 App bundle created at: $APP_BUNDLE"
echo ""
echo "To run the app, you can:"
echo "  1. Double-click the app in Finder"
echo "  2. Or run: open $APP_BUNDLE"
echo "  3. Or run from Terminal: $APP_BUNDLE/Contents/MacOS/NotchMusic"
echo ""
echo "🎵 NotchMusic is ready to use!"
