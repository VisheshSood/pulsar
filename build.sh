#!/bin/zsh
# Builds Pulsar.app (release) next to this script. Usage: ./build.sh [--run]
set -euo pipefail
cd "${0:A:h}"
swift build -c release
APP=Pulsar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Pulsar "$APP/Contents/MacOS/Pulsar"
# App icon: Assets/icon.png (regenerate from Assets/icon-source.png with tools/make_icon.py)
if [[ -f Assets/icon.png ]]; then
  IS=$(mktemp -d)/Pulsar.iconset; mkdir -p "$IS"
  for s in 16 32 128 256 512; do
    sips -s format png -z $s $s Assets/icon.png --out "$IS/icon_${s}x${s}.png" >/dev/null
    sips -s format png -z $((s*2)) $((s*2)) Assets/icon.png --out "$IS/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$IS" -o "$APP/Contents/Resources/AppIcon.icns"
fi
# Menu bar logo: black-on-transparent PNG at Assets/menubar.png (macOS tints it; ~36px tall works well)
if [[ -f Assets/menubar.png ]]; then
  sips -s format png --resampleHeight 18 Assets/menubar.png --out "$APP/Contents/Resources/MenuBarIcon.png" >/dev/null
  sips -s format png --resampleHeight 36 Assets/menubar.png --out "$APP/Contents/Resources/MenuBarIcon@2x.png" >/dev/null
fi
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Pulsar</string>
  <key>CFBundleDisplayName</key><string>Pulsar</string>
  <key>CFBundleIdentifier</key><string>io.github.visheshsood.pulsar</string>
  <key>CFBundleExecutable</key><string>Pulsar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.2</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSAudioCaptureUsageDescription</key><string>Pulsar listens to what your Mac plays so the logo can flash on the beat. Audio never leaves your Mac and is not recorded.</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>io.github.visheshsood.pulsar</string>
    <key>CFBundleURLSchemes</key><array><string>pulsar</string></array>
  </dict></array>
</dict></plist>
PLIST
# Signing, in order of preference:
#   1. "Developer ID Application" (your Apple Developer account): hardened runtime + timestamp,
#      required for notarization (./build.sh --release).
#   2. "Pulsar Local Signing" (a self-signed cert in your keychain): a stable identity, so macOS
#      keeps granted permissions across rebuilds. Create one with tools/make_local_cert.sh.
#   3. Ad-hoc: works, but macOS asks for permissions again after every rebuild.
DEVID=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $2; exit}')
LOCAL=$(security find-identity -p codesigning 2>/dev/null | awk '/"Pulsar Local Signing"/ {print $2; exit}')
if [[ -n "$DEVID" ]]; then
  codesign --force --options runtime --timestamp --entitlements Pulsar.entitlements --sign "$DEVID" "$APP"
  echo "Signed with Developer ID"
elif [[ "${1:-}" == "--release" ]]; then
  echo "error: --release needs a 'Developer ID Application' certificate in your keychain" >&2; exit 1
elif [[ -n "$LOCAL" ]]; then
  codesign --force --sign "$LOCAL" "$APP"
else
  echo "warning: no signing identity found; signing ad-hoc (macOS will re-ask for permissions)"
  codesign --force --sign - "$APP"
fi
echo "Built $PWD/$APP"

install_app() {
  pkill -x Pulsar 2>/dev/null || true; sleep 1
  rm -rf /Applications/Pulsar.app && ditto "$APP" /Applications/Pulsar.app
  open /Applications/Pulsar.app
  echo "Installed /Applications/Pulsar.app"
}

case "${1:-}" in
  --run) pkill -x Pulsar 2>/dev/null || true; sleep 1; open "$APP" ;;
  --install) install_app ;;
  --release)
    # Notarize: needs credentials saved once with
    #   xcrun notarytool store-credentials pulsar --apple-id <email> --team-id <TEAMID>
    mkdir -p dist
    ditto -c -k --keepParent "$APP" dist/Pulsar-notarize.zip
    xcrun notarytool submit dist/Pulsar-notarize.zip --keychain-profile pulsar --wait
    xcrun stapler staple "$APP"
    rm dist/Pulsar-notarize.zip
    ditto -c -k --keepParent "$APP" dist/Pulsar.zip
    spctl --assess --type execute -v "$APP" && echo "Ready to share: $PWD/dist/Pulsar.zip" ;;
esac
