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

# Relaunch
echo "  Avvio $APP_NAME..."
open "$INSTALL_PATH"

echo ""
echo "🎉 Installazione completata!"
echo "   I permessi FDA sono preservati."
