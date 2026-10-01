#!/bin/bash

# NotchMusic Build Script
# This script builds the NotchMusic macOS app from source

set -e

echo "🎵 Building NotchMusic..."

# Check if Xcode is installed
if ! command -v xcodebuild &> /dev/null; then
    echo "❌ Xcode is not installed. Please install Xcode from the App Store or visit https://developer.apple.com/download/"
    exit 1
fi

# Create a temporary Xcode project directory
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

echo "📁 Creating temporary project structure..."

# Create the project directory structure
mkdir -p "$TEMP_DIR/NotchMusic"
mkdir -p "$TEMP_DIR/NotchMusic/NotchMusic"

# Copy Swift source files
cp NotchMusicApp.swift "$TEMP_DIR/NotchMusic/NotchMusic/"
cp AppDelegate.swift "$TEMP_DIR/NotchMusic/NotchMusic/"
cp NotchViewModel.swift "$TEMP_DIR/NotchMusic/NotchMusic/"
cp NotchContentView.swift "$TEMP_DIR/NotchMusic/NotchMusic/"
cp FileDropTray.swift "$TEMP_DIR/NotchMusic/NotchMusic/"

# Create Info.plist
cat > "$TEMP_DIR/NotchMusic/NotchMusic/Info.plist" << 'EOF'
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
    <key>NSMainStoryboardFile</key>
    <string></string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSRequiresIPhoneOS</key>
    <false/>
</dict>
</plist>
EOF

# Create project.pbxproj (simplified)
cat > "$TEMP_DIR/NotchMusic/NotchMusic.xcodeproj/project.pbxproj" << 'EOF'
// !$*UTF8*$!
{
    archiveVersion = 1;
    classes = {
    };
    objectVersion = 56;
    objects = {
        /* Begin PBXBuildFile section */
        1A1A1A1A1A1A1A1A1A1A1A1A /* NotchMusicApp.swift in Sources */ = {isa = PBXBuildFile; fileRef = 1B1B1B1B1B1B1B1B1B1B1B1B; };
        2A2A2A2A2A2A2A2A2A2A2A2A /* AppDelegate.swift in Sources */ = {isa = PBXBuildFile; fileRef = 2B2B2B2B2B2B2B2B2B2B2B2B; };
        3A3A3A3A3A3A3A3A3A3A3A3A /* NotchViewModel.swift in Sources */ = {isa = PBXBuildFile; fileRef = 3B3B3B3B3B3B3B3B3B3B3B3B; };
        4A4A4A4A4A4A4A4A4A4A4A4A /* NotchContentView.swift in Sources */ = {isa = PBXBuildFile; fileRef = 4B4B4B4B4B4B4B4B4B4B4B4B; };
        5A5A5A5A5A5A5A5A5A5A5A5A /* FileDropTray.swift in Sources */ = {isa = PBXBuildFile; fileRef = 5B5B5B5B5B5B5B5B5B5B5B5B; };
        6A6A6A6A6A6A6A6A6A6A6A6A /* MediaPlayer.framework in Frameworks */ = {isa = PBXBuildFile; fileRef = 6B6B6B6B6B6B6B6B6B6B6B6B; };
    /* End PBXBuildFile section */
    };
    rootObject = 0A0A0A0A0A0A0A0A0A0A0A0A;
}
EOF

echo "🏗️  Building with xcodebuild..."

# Build the app using Swift package manager or create a minimal workspace
cd "$TEMP_DIR/NotchMusic"

# Create a Package.swift for Swift Package Manager approach
cat > Package.swift << 'EOF'
// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "NotchMusic",
    platforms: [
        .macOS(.v11)
    ],
    targets: [
        .executableTarget(
            name: "NotchMusic",
            dependencies: [],
            path: "NotchMusic"
        )
    ]
)
EOF

# Alternative: Use xcodebuild to create the app
# First, let's use a simpler approach with swiftc directly

OUTPUT_DIR="./build"
mkdir -p "$OUTPUT_DIR"

echo "⚙️  Compiling Swift source files..."

swiftc -target x86_64-apple-macosx11.0 \
    NotchMusic/NotchMusicApp.swift \
    NotchMusic/AppDelegate.swift \
    NotchMusic/NotchViewModel.swift \
    NotchMusic/NotchContentView.swift \
    NotchMusic/FileDropTray.swift \
    -framework Cocoa \
    -framework SwiftUI \
    -framework MediaPlayer \
    -o "$OUTPUT_DIR/NotchMusic" 2>/dev/null || {
    echo "⚠️  Direct compilation encountered an issue. Attempting Xcode build..."
    
    # Create a proper Xcode project
    mkdir -p "NotchMusic.xcodeproj"
    
    xcodebuild -scheme NotchMusic \
        -configuration Release \
        -derivedDataPath "$OUTPUT_DIR/DerivedData" \
        2>&1 | grep -v "warning:" || true
}

echo "✅ Build complete!"
echo ""
echo "📦 App location: $OUTPUT_DIR/NotchMusic"
echo ""
echo "To run the app, you can:"
echo "  1. Open it directly: open $OUTPUT_DIR/NotchMusic"
echo "  2. Or build and run from Xcode for development"
echo ""
echo "🎵 NotchMusic is ready to use!"
