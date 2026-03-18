#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="RustyBackMenu"
BUNDLE="${SCRIPT_DIR}/${APP_NAME}.app"
INSTALL_DIR="/Applications"

echo "🔨 Building ${APP_NAME}..."

# Clean previous build
rm -rf "${BUNDLE}"

# Compile
swiftc \
    -O \
    -target arm64-apple-macos13.0 \
    -framework Cocoa \
    -framework UserNotifications \
    -o "${SCRIPT_DIR}/${APP_NAME}" \
    "${SCRIPT_DIR}/main.swift"

echo "✅ Compiled successfully"

# Create .app bundle structure
mkdir -p "${BUNDLE}/Contents/MacOS"
mkdir -p "${BUNDLE}/Contents/Resources"

mv "${SCRIPT_DIR}/${APP_NAME}" "${BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "${SCRIPT_DIR}/Info.plist" "${BUNDLE}/Contents/Info.plist"

# Copy PNG icons to Resources
if [ -d "${SCRIPT_DIR}/icons" ]; then
    cp "${SCRIPT_DIR}"/icons/*.png "${BUNDLE}/Contents/Resources/" 2>/dev/null && \
        echo "🎨 Icons copied to Resources" || \
        echo "⚠️  No PNG icons found in icons/"
fi

echo "📦 Bundle created: ${BUNDLE}"

# Copy to /Applications
if [ -w "${INSTALL_DIR}" ]; then
    rm -rf "${INSTALL_DIR}/${APP_NAME}.app"
    cp -R "${BUNDLE}" "${INSTALL_DIR}/${APP_NAME}.app"
    echo "📲 Installed to ${INSTALL_DIR}/${APP_NAME}.app"
else
    echo "📲 Installing to ${INSTALL_DIR} (requires sudo)..."
    sudo rm -rf "${INSTALL_DIR}/${APP_NAME}.app"
    sudo cp -R "${BUNDLE}" "${INSTALL_DIR}/${APP_NAME}.app"
    echo "✅ Installed to ${INSTALL_DIR}/${APP_NAME}.app"
fi

# Add to Login Items (optional, only if --login-item flag passed)
if [[ "${1:-}" == "--login-item" ]]; then
    echo "🔑 Adding to Login Items..."
    osascript -e "
        tell application \"System Events\"
            if not (exists login item \"${APP_NAME}\") then
                make login item at end with properties {path:\"${INSTALL_DIR}/${APP_NAME}.app\", hidden:false}
            end if
        end tell
    " && echo "✅ Added to Login Items" || echo "⚠️  Could not add to Login Items (grant Accessibility permissions)"
fi

echo ""
echo "🎉 Done! Launch with:"
echo "   open ${INSTALL_DIR}/${APP_NAME}.app"
echo ""
echo "To add as Login Item:"
echo "   bash $0 --login-item"
