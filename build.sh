#!/bin/bash
set -e

DIR="/Users/horse/Desktop/agy-status"

echo "Cleaning up old build..."
rm -rf "$DIR/AgyStatus" "$DIR/AgyStatus.app"

echo "Compiling AgyStatus..."
# Compile Swift code using optimization and the macosx SDK
swiftc -O -sdk "$(xcrun --show-sdk-path --sdk macosx)" "$DIR/main.swift" -o "$DIR/AgyStatus"

echo "Creating App Bundle structure..."
mkdir -p "$DIR/AgyStatus.app/Contents/MacOS"

echo "Moving binary..."
mv "$DIR/AgyStatus" "$DIR/AgyStatus.app/Contents/MacOS/AgyStatus"

echo "Copying Info.plist..."
cp "$DIR/Info.plist" "$DIR/AgyStatus.app/Contents/Info.plist"

echo "Build successful! AgyStatus.app created at $DIR/AgyStatus.app"
