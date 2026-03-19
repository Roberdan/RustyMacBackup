#!/bin/bash
set -euo pipefail

echo "🧪 Running RustyMacBackup Tests..."
mkdir -p build

declare -a SOURCES=()
declare -a TESTS=()

while IFS= read -r file; do
    SOURCES+=("$file")
done < <(find Sources -name "*.swift" -type f ! -path "Sources/App/main.swift")

while IFS= read -r file; do
    TESTS+=("$file")
done < <(find Tests -name "*.swift" -type f)

if [ ${#TESTS[@]} -eq 0 ]; then
    echo "No test files found in Tests/"
    exit 1
fi

echo "  Compiling tests..."
swiftc \
    -target arm64-apple-macos14.0 \
    -framework Cocoa \
    -framework UserNotifications \
    -framework IOKit \
    -o build/RustyMacBackupTests \
    "${SOURCES[@]}" "${TESTS[@]}"

echo "  ✅ Compilation successful"
echo ""
echo "  Running tests..."
./build/RustyMacBackupTests
