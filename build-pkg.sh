#!/bin/bash
set -euo pipefail

VERSION="1.0.0"
APP_NAME="RustyMacBackup"
PKG_ID="com.roberdan.rusty-mac-backup"

echo "📦 Building $APP_NAME v$VERSION installer..."

# Step 1: Build the app
./build.sh

# Step 2: Create staging directory
PKG_ROOT=$(mktemp -d)
SCRIPTS_DIR=$(mktemp -d)
trap "rm -rf $PKG_ROOT $SCRIPTS_DIR" EXIT

# Stage .app to /Applications
mkdir -p "$PKG_ROOT/Applications"
cp -R "build/$APP_NAME.app" "$PKG_ROOT/Applications/"

# Step 3: Create postinstall script
cat > "$SCRIPTS_DIR/postinstall" << 'POSTINSTALL'
#!/bin/bash
# Open FDA settings reminder
open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" 2>/dev/null || true
# Launch the app
open "/Applications/RustyMacBackup.app" 2>/dev/null || true
exit 0
POSTINSTALL
chmod +x "$SCRIPTS_DIR/postinstall"

# Step 4: Build .pkg
pkgbuild \
    --root "$PKG_ROOT" \
    --identifier "$PKG_ID" \
    --version "$VERSION" \
    --install-location "/" \
    --scripts "$SCRIPTS_DIR" \
    "$APP_NAME-$VERSION.pkg"

echo ""
echo "🎉 Package built: $APP_NAME-$VERSION.pkg"
echo "   Install with: sudo installer -pkg $APP_NAME-$VERSION.pkg -target /"
