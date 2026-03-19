#!/bin/bash
set -euo pipefail

# RustyMacBackup — Swift Build Script
# Builds the native .app bundle

APP_NAME="RustyMacBackup"
VERSION="1.0.0"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
BINARY="$BUILD_DIR/$APP_NAME"
SWIFT_FILES=$(find Sources -name "*.swift" -type f)
MACOS_TARGET="arm64-apple-macos14.0"

echo "🔨 Building $APP_NAME v$VERSION..."

# Create build directory
mkdir -p "$BUILD_DIR"

# Compile all Swift files
echo "  Compiling Swift sources..."
swiftc \
    -O \
    -target "$MACOS_TARGET" \
    -framework Cocoa \
    -framework UserNotifications \
    -framework IOKit \
    -o "$BINARY" \
    $SWIFT_FILES

echo "  ✅ Compilation successful"

# Create .app bundle structure
echo "  Creating .app bundle..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy Info.plist
cp Sources/App/Info.plist "$APP_BUNDLE/Contents/"

# Copy icons
if [ -d "Resources/icons" ]; then
    cp Resources/icons/*.png "$APP_BUNDLE/Contents/Resources/" 2>/dev/null || true
fi
if [ -f "Resources/AppIcon.icns" ]; then
    cp Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/"
fi

echo "  ✅ Bundle created: $APP_BUNDLE"
echo ""
echo "🎉 Build complete!"
echo "   App: $APP_BUNDLE"
echo "   CLI: $BINARY version → $($BINARY version 2>/dev/null || echo 'N/A')"
