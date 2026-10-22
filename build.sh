#!/bin/bash
# Builds Showrunner.app into ~/Applications and puts the `sr` command on the PATH.
set -e
cd "$(dirname "$0")"
APP="$HOME/Applications/Showrunner.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -o "$APP/Contents/MacOS/Showrunner" Show.swift Actions.swift Model.swift Views.swift main.swift 2>&1 | grep -E "error|warning: unre" || true
[ -x "$APP/Contents/MacOS/Showrunner" ] || { echo "build failed"; exit 1; }
cp examples/template.show.md "$APP/Contents/Resources/template.md"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Showrunner</string>
  <key>CFBundleIdentifier</key><string>local.showrunner</string>
  <key>CFBundleExecutable</key><string>Showrunner</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSAppleEventsUsageDescription</key><string>Showrunner brings Chrome tabs, Keynote slides and videos forward as you move through a show.</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>Show</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>CFBundleTypeExtensions</key><array><string>json</string><string>md</string></array>
    <key>LSHandlerRank</key><string>Alternate</string>
  </dict></array>
</dict></plist>
PLIST
codesign --force -s - "$APP" >/dev/null 2>&1 || true
mkdir -p "$HOME/.local/bin"
ln -sf "$PWD/sr.py" "$HOME/.local/bin/sr"
echo "built $APP"
