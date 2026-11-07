#!/bin/bash
# Builds Bearing with just Xcode's command line tools. No paid developer account needed.
# ./build.sh [--open] [--dmg] [--test]
set -euo pipefail
cd "$(dirname "$0")"
V=1.2.0
A="$HOME/Applications/Bearing.app"
B="build/Bearing"
mkdir -p build
# Google sign-in client. Kept out of the public repo, so only builds with google-client.local can sign in.
GOOGLE_ID=""; GOOGLE_SECRET=""
[ -f google-client.local ] && . ./google-client.local
echo "enum GoogleClient { static let id = \"$GOOGLE_ID\", secret = \"$GOOGLE_SECRET\" }" > build/GoogleClient.swift
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos26 Sources/*.swift build/GoogleClient.swift -o "$B"

rm -rf "$A"; mkdir -p "$A/Contents/MacOS" "$A/Contents/Resources"
cp "$B" "$A/Contents/MacOS/Bearing"
[ -d Resources/Music ] && cp -R Resources/Music "$A/Contents/Resources/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$A/Contents/Resources/"
[ -f Resources/Assets.car ] && cp Resources/Assets.car "$A/Contents/Resources/"
cat > "$A/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.tapariapurv.bearing</string>
<key>CFBundleName</key><string>Bearing</string>
<key>CFBundleExecutable</key><string>Bearing</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIconName</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$V</string>
<key>CFBundleVersion</key><string>$V</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSCalendarsFullAccessUsageDescription</key><string>Bearing shows your calendar and saves time blocks to it.</string>
<key>NSMicrophoneUsageDescription</key><string>Bearing records your voice notes and brain dumps.</string>
<key>NSSpeechRecognitionUsageDescription</key><string>Bearing turns your voice notes into text on this Mac.</string>
<key>NSAppleEventsUsageDescription</key><string>Bearing plays and pauses Spotify or Apple Music during focus sessions.</string>
</dict></plist>
EOF
codesign -fs "${ID:--}" "$A"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$A"

for arg in "$@"; do case "$arg" in
  --test) "$A/Contents/MacOS/Bearing" --selftest ;;
  --open) pkill -x Bearing || true; open "$A" ;;
  --dmg)
    S=build/dmg; rm -rf "$S" build/Bearing.dmg; mkdir -p "$S"
    ditto "$A" "$S/Bearing.app"; ln -s /Applications "$S/Applications"
    hdiutil create -volname Bearing -srcfolder "$S" -fs HFS+ -format UDZO build/Bearing.dmg >/dev/null
    rm -rf "$S"; echo build/Bearing.dmg ;;
esac; done
