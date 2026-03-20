#!/bin/bash
set -euo pipefail

VERSION="${VERSION:-2.1.0}"
APP_NAME="RustyMacBackup"
PKG_ID="com.roberdan.rusty-mac-backup"

echo "📦 Building $APP_NAME v$VERSION installer..."

# Step 1: Build the app (VERSION is passed through env)
VERSION="$VERSION" ./build.sh

# Step 2: Create .app.zip for auto-update (in-place, no admin required)
echo "  Creating .app.zip…"
(cd build && zip -qr "../$APP_NAME-$VERSION.app.zip" "$APP_NAME.app")
echo "  ✅ $APP_NAME-$VERSION.app.zip ($(du -sh "$APP_NAME-$VERSION.app.zip" | cut -f1))"

# Step 3: Create staging directory for .pkg
PKG_ROOT=$(mktemp -d)
SCRIPTS_DIR=$(mktemp -d)
trap "rm -rf $PKG_ROOT $SCRIPTS_DIR" EXIT

mkdir -p "$PKG_ROOT/Applications"
cp -R "build/$APP_NAME.app" "$PKG_ROOT/Applications/"

# Step 4: postinstall — open FDA settings and launch
cat > "$SCRIPTS_DIR/postinstall" << 'POSTINSTALL'
#!/bin/bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" 2>/dev/null || true
open "/Applications/RustyMacBackup.app" 2>/dev/null || true
exit 0
POSTINSTALL
chmod +x "$SCRIPTS_DIR/postinstall"

# Step 5: Build .pkg
pkgbuild \
    --root "$PKG_ROOT" \
    --identifier "$PKG_ID" \
    --version "$VERSION" \
    --install-location "/" \
    --scripts "$SCRIPTS_DIR" \
    "$APP_NAME-$VERSION-arm64.pkg"

echo ""
echo "🎉 Artifacts:"
echo "   $APP_NAME-$VERSION-arm64.pkg  (first install — requires admin)"
echo "   $APP_NAME-$VERSION.app.zip    (auto-update — no admin needed)"
