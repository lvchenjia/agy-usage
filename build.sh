#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export TMPDIR="/tmp"
mkdir -p /tmp/clang-module-cache

echo "Cleaning up old build..."
rm -rf "$DIR/AgyUsage" "$DIR/Agy Usage.app" /tmp/AgyUsage

echo "Compiling AgyUsage..."
# Compile modular Swift code using optimization and the macosx SDK
SWIFT_FILES=$(find "$DIR/Sources" -name "*.swift")
swiftc -module-cache-path /tmp/clang-module-cache -O -sdk "$(xcrun --show-sdk-path --sdk macosx)" $SWIFT_FILES -o "/tmp/AgyUsage"

echo "Creating App Bundle structure..."
mkdir -p "$DIR/Agy Usage.app/Contents/MacOS"
mkdir -p "$DIR/Agy Usage.app/Contents/Resources"

echo "Moving binary..."
mv "/tmp/AgyUsage" "$DIR/Agy Usage.app/Contents/MacOS/AgyUsage"

echo "Copying Info.plist..."
cp "$DIR/Info.plist" "$DIR/Agy Usage.app/Contents/Info.plist"

echo "Copying Resources..."
if [ -d "$DIR/Resources" ]; then
    cp "$DIR/Resources/"* "$DIR/Agy Usage.app/Contents/Resources/"
fi

echo "Installing to /Applications..."
rm -rf "/Applications/Agy Usage.app"
cp -R "$DIR/Agy Usage.app" "/Applications/Agy Usage.app"

echo "Build and installation successful! Agy Usage.app is now in /Applications/"
