#!/bin/bash
# ==================================
# GSBWIFI Manager - Swift Build Script
# ==================================
# Compiles the Swift app into a macOS .app bundle using swiftc.
# No Xcode IDE required — only the Xcode Command Line Tools.
#
# Usage:
#   ./build.sh          # Build the app
#   ./build.sh run      # Build and run
#   ./build.sh clean    # Remove build artifacts

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$SCRIPT_DIR/build"
APP_NAME="GSBWiFiManager"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "======================================"
echo "  GSBWIFI Manager — Swift Build"
echo "======================================"

# --- Clean ---
if [ "${1:-}" = "clean" ]; then
    echo -e "${YELLOW}🧹 Cleaning build artifacts...${NC}"
    rm -rf "$BUILD_DIR"
    echo -e "${GREEN}✅ Clean complete.${NC}"
    exit 0
fi

# --- Check toolchain ---
if ! command -v swiftc &> /dev/null; then
    echo -e "${RED}❌ swiftc not found! Install Xcode Command Line Tools:${NC}"
    echo "   xcode-select --install"
    exit 1
fi

SWIFT_VERSION=$(swiftc --version | head -1)
echo "Swift: $SWIFT_VERSION"

# --- Create .app bundle structure ---
echo -e "${YELLOW}📦 Creating app bundle...${NC}"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# --- Create Info.plist ---
cat > "$APP_BUNDLE/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>GSBWiFiManager</string>
    <key>CFBundleIdentifier</key>
    <string>tr.gov.gsb.wifimanager</string>
    <key>CFBundleName</key>
    <string>GSBWIFI Manager</string>
    <key>CFBundleDisplayName</key>
    <string>GSBWIFI Manager</string>
    <key>CFBundleVersion</key>
    <string>2.0</string>
    <key>CFBundleShortVersionString</key>
    <string>2.0.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
    <key>NSUserNotificationAlertStyle</key>
    <string>banner</string>
</dict>
</plist>
PLIST

# --- Copy Assets ---
if [ -f "$SCRIPT_DIR/AppIcon.png" ]; then
    cp "$SCRIPT_DIR/AppIcon.png" "$APP_BUNDLE/Contents/Resources/AppIcon.png"
    echo "  AppIcon.png copied to bundle"
fi

# --- Compile Swift ---
echo -e "${YELLOW}🔨 Compiling Swift sources...${NC}"

SWIFT_FILES=(
    "$SCRIPT_DIR/FileLogger.swift"
    "$SCRIPT_DIR/PortalClient.swift"
    "$SCRIPT_DIR/WiFiManager.swift"
    "$SCRIPT_DIR/GSBWiFiApp.swift"
)

# Check all files exist
for f in "${SWIFT_FILES[@]}"; do
    if [ ! -f "$f" ]; then
        echo -e "${RED}❌ Missing source file: $f${NC}"
        exit 1
    fi
done

swiftc \
    -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
    -target "$(uname -m)-apple-macosx13.0" \
    -sdk "$(xcrun --show-sdk-path)" \
    -framework SwiftUI \
    -framework AppKit \
    -framework Network \
    -framework UserNotifications \
    -framework SystemConfiguration \
    -framework CoreWLAN \
    -O \
    -whole-module-optimization \
    "${SWIFT_FILES[@]}"

echo -e "${GREEN}✅ Build successful!${NC}"
echo "   App: $APP_BUNDLE"

# --- Run ---
if [ "${1:-}" = "run" ]; then
    echo ""
    echo -e "${YELLOW}🚀 Launching $APP_NAME...${NC}"
    open "$APP_BUNDLE"
fi

echo ""
echo "Commands:"
echo "  ./build.sh         Build"
echo "  ./build.sh run     Build & run"
echo "  ./build.sh clean   Clean"
