#!/bin/zsh
# Builds a release .app bundle (menu-bar only, no Dock icon).
set -e
cd "$(dirname "$0")"
# Record the current SDK so macOS applies the latest window chrome (Liquid Glass traffic lights).
SDKV=$(xcrun --sdk macosx --show-sdk-version)
swift build -c release -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker $SDKV
APP=build/WinV.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/WinV "$APP/Contents/MacOS/"

# App icon from the Icon Composer file (Resources/Clipboard.icon) → Assets.car with the
# Liquid Glass icon (light/dark/tinted variants) plus a Clipboard.icns fallback.
xcrun actool Resources/Clipboard.icon --compile "$APP/Contents/Resources" --app-icon Clipboard \
  --platform macosx --target-device mac --minimum-deployment-target 14.0 \
  --output-partial-info-plist build/icon.plist >/dev/null
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>WinV</string>
  <key>CFBundleDisplayName</key><string>WinV</string>
  <key>CFBundleIdentifier</key><string>app.local.clipboard</string>
  <key>CFBundleExecutable</key><string>WinV</string>
  <key>CFBundleIconFile</key><string>Clipboard</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleIconName</key><string>Clipboard</string>
  <key>UIDesignRequiresCompatibility</key><false/>
</dict></plist>
PLIST
# Stable local identity keeps the Accessibility grant across rebuilds; falls back to ad-hoc.
ID=$(security find-identity -p codesigning | awk '/Clipboard Local Signing/{print $2; exit}')
codesign --force --sign "${ID:--}" $APP
echo "Built $APP"
# DMG with drag-to-Applications shortcut
S=build/dmg && rm -rf $S && mkdir -p $S && cp -R $APP $S/ && ln -s /Applications $S/Applications
hdiutil create -volname WinV -srcfolder $S -ov -format UDZO build/WinV.dmg >/dev/null && rm -rf $S
echo "Built build/WinV.dmg"
