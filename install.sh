#!/bin/bash
set -euo pipefail

echo ""
echo "  RustyMacBackup — Installer"
echo "  ─────────────────────────────"
echo ""

# Check macOS
if [[ "$(uname)" != "Darwin" ]]; then
    echo "❌ This tool is macOS only."
    exit 1
fi

# Check for Rust
if ! command -v cargo &>/dev/null; then
    echo "📦 Rust not found. Installing via rustup..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
fi

# Check for swiftc
if ! command -v swiftc &>/dev/null; then
    echo "❌ Xcode Command Line Tools required."
    echo "   Run: xcode-select --install"
    exit 1
fi

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "1/4  Building backup engine..."
cd "$REPO_DIR"
cargo build --release --quiet

echo "2/4  Installing rustyback to ~/.local/bin/"
mkdir -p "$HOME/.local/bin"
cp target/release/rustyback "$HOME/.local/bin/rustyback"
chmod +x "$HOME/.local/bin/rustyback"

# Ensure ~/.local/bin is in PATH
if ! echo "$PATH" | grep -q "$HOME/.local/bin"; then
    echo ""
    echo "⚠  Add ~/.local/bin to your PATH:"
    echo "   echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc"
    echo ""
fi

echo "3/4  Building menu bar app..."
bash menubar/build.sh

echo "4/4  Setup..."
echo ""

# Check if config exists
if [[ -f "$HOME/.config/rusty-mac-backup/config.toml" ]]; then
    echo "✅ Config found at ~/.config/rusty-mac-backup/config.toml"
else
    echo "📝 Running initial setup..."
    "$HOME/.local/bin/rustyback" init
fi

echo ""
echo "  ─────────────────────────────"
echo "  ✅ Installation complete!"
echo ""
echo "  CLI:      rustyback backup"
echo "  Menu app: open /Applications/RustyBackMenu.app"
echo ""
echo "  ⚠  IMPORTANT: Grant Full Disk Access to both:"
echo "     1. Your terminal (Terminal.app / iTerm / etc.)"
echo "     2. /Applications/RustyBackMenu.app"
echo ""
echo "     System Settings → Privacy & Security → Full Disk Access"
echo ""
