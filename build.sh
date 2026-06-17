#!/bin/bash
set -e

DIR="/Users/horse/Desktop/agy-usage"

echo "Cleaning up old build..."
rm -rf "$DIR/AgyUsage" "$DIR/Agy Usage.app"

echo "Compiling AgyUsage..."
# Compile Swift code using optimization and the macosx SDK
swiftc -O -sdk "$(xcrun --show-sdk-path --sdk macosx)" "$DIR/main.swift" -o "$DIR/AgyUsage"

echo "Creating App Bundle structure..."
mkdir -p "$DIR/Agy Usage.app/Contents/MacOS"
mkdir -p "$DIR/Agy Usage.app/Contents/Resources"

echo "Moving binary..."
mv "$DIR/AgyUsage" "$DIR/Agy Usage.app/Contents/MacOS/AgyUsage"

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
