#!/bin/bash
set -euo pipefail

VERSION="0.1.0"
PKG_ID="com.roberdan.rusty-mac-backup"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/pkg-build"
OUTPUT="${SCRIPT_DIR}/RustyMacBackup-${VERSION}.pkg"

echo ""
echo "  Building RustyMacBackup v${VERSION} installer package"
echo "  ────────────────────────────────────────────────────"
echo ""

# Step 1: Build everything (skip if already built in CI)
if [ ! -f "${SCRIPT_DIR}/target/release/rustyback" ]; then
    echo "1/5  Building backup engine..."
    cd "$SCRIPT_DIR"
    cargo build --release --quiet
else
    echo "1/5  Binary already built, skipping..."
fi

if [ ! -d "${SCRIPT_DIR}/menubar/RustyBackMenu.app" ]; then
    echo "2/5  Building menu bar app..."
    bash menubar/build.sh 2>&1 | tail -1
else
    echo "2/5  Menu bar app already built, skipping..."
fi

# Step 3: Create package staging area
echo "3/5  Staging package contents..."
rm -rf "$BUILD_DIR"
mkdir -p "${BUILD_DIR}/payload/usr/local/bin"
mkdir -p "${BUILD_DIR}/payload/Applications"
mkdir -p "${BUILD_DIR}/scripts"

# CLI binary
cp target/release/rustyback "${BUILD_DIR}/payload/usr/local/bin/rustyback"
chmod 755 "${BUILD_DIR}/payload/usr/local/bin/rustyback"

# Menu bar app bundle
cp -R menubar/RustyBackMenu.app "${BUILD_DIR}/payload/Applications/RustyBackMenu.app"

# Post-install script: launch app + show FDA reminder
cat > "${BUILD_DIR}/scripts/postinstall" << 'POSTINSTALL'
#!/bin/bash

# Ensure CLI is accessible
if [ -d "/opt/homebrew/bin" ]; then
    ln -sf /usr/local/bin/rustyback /opt/homebrew/bin/rustyback 2>/dev/null || true
fi

# Open the menu bar app
open /Applications/RustyBackMenu.app 2>/dev/null || true

# Show reminder about Full Disk Access
osascript -e '
display dialog "RustyMacBackup installed successfully!\n\nIMPORTANT: Grant Full Disk Access to:\n• /Applications/RustyBackMenu.app\n• Your terminal app\n\nSystem Settings → Privacy & Security → Full Disk Access" buttons {"Open Settings", "OK"} default button "OK" with title "RustyMacBackup" with icon note
set result to button returned of result
if result is "Open Settings" then
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
end if
' 2>/dev/null || true

exit 0
POSTINSTALL
chmod 755 "${BUILD_DIR}/scripts/postinstall"

# Step 4: Build the .pkg
echo "4/5  Building .pkg..."
pkgbuild \
    --root "${BUILD_DIR}/payload" \
    --scripts "${BUILD_DIR}/scripts" \
    --identifier "$PKG_ID" \
    --version "$VERSION" \
    --install-location "/" \
    "$OUTPUT" \
    2>&1 | grep -v "^$"

# Cleanup
rm -rf "$BUILD_DIR"

echo "5/5  Done!"
echo ""
PKG_SIZE=$(ls -lh "$OUTPUT" | awk '{print $5}')
echo "  ✅ ${OUTPUT}"
echo "     Size: ${PKG_SIZE}"
echo ""
echo "  Double-click to install, or:"
echo "     sudo installer -pkg ${OUTPUT} -target /"
echo ""
