#!/bin/bash
set -euo pipefail

# RustyMacBackup — In-place installer
# Updates /Applications/RustyMacBackup.app WITHOUT removing it,
# so macOS FDA (Full Disk Access) permission is preserved.

APP_NAME="RustyMacBackup"
INSTALL_PATH="/Applications/$APP_NAME.app"
BUILD_PATH="build/$APP_NAME.app"

# Build first
./build.sh

if [ ! -d "$BUILD_PATH" ]; then
    echo "❌ Build failed — no .app found"
    exit 1
fi

# Kill running instance
PID=$(pgrep -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true)
if [ -n "$PID" ]; then
    echo "  Chiudo $APP_NAME..."
    kill "$PID" 2>/dev/null || true
    sleep 1
fi

if [ -d "$INSTALL_PATH" ]; then
    # UPDATE in-place: only replace Contents, keep .app wrapper
    echo "  Aggiornamento in-place..."
    rsync -a --delete "$BUILD_PATH/Contents/" "$INSTALL_PATH/Contents/"
else
    # First install: copy whole .app
    echo "  Prima installazione..."
    cp -R "$BUILD_PATH" "$INSTALL_PATH"
fi

echo "  ✅ Installato: $INSTALL_PATH"

# Sync .app + .pkg to backup disk so the app is recoverable from the backup itself
BACKUP_DEST_DIR=$(awk -F'"' '/^path *=/{print $2}' ~/.config/rusty-mac-backup/config.toml 2>/dev/null || true)
if [ -n "$BACKUP_DEST_DIR" ] && [ -d "$BACKUP_DEST_DIR" ]; then
    echo "  Aggiorno disco di backup: $BACKUP_DEST_DIR..."
    rsync -a --delete "$BUILD_PATH/Contents/" "$BACKUP_DEST_DIR/$APP_NAME.app/Contents/"
    echo "  ✅ .app aggiornata sul disco di backup"
    # Copy latest .pkg if present
    PKG=$(ls ${APP_NAME}-*.pkg build/${APP_NAME}-*.pkg 2>/dev/null | sort -V | tail -1 || true)
    if [ -n "$PKG" ]; then
        cp "$PKG" "$BACKUP_DEST_DIR/"
        echo "  ✅ $(basename "$PKG") copiato sul disco di backup"
    fi
else
    echo "  ⚠️  Disco di backup non montato, skip sync"
fi

# Relaunch
echo "  Avvio $APP_NAME..."
open "$INSTALL_PATH"

echo ""
echo "🎉 Installazione completata!"
echo "   I permessi FDA sono preservati."
