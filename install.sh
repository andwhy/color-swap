#!/bin/zsh
# Собирает ColorSwap.app и добавляет пункт в меню PDF ▾ диалога печати
# («Print without Black» / «Ohne Schwarz drucken» / «Печать без чёрного» … — на языке системы).
# ./install.sh            — собрать и установить
# ./install.sh uninstall  — удалить
set -euo pipefail
cd "${0:A:h}"

APP="$HOME/Applications/ColorSwap.app"
SERVICES="$HOME/Library/PDF Services"

remove_links() {  # все пункты меню, которые ведут на приложение (на любом языке)
  [[ -d "$SERVICES" ]] && find "$SERVICES" -maxdepth 1 -type l -lname "$APP" -delete
  return 0
}

if [[ "${1:-}" == "uninstall" ]]; then
  remove_links
  rm -rf "$APP"
  defaults delete local.colorswap 2>/dev/null || true
  echo "Removed."
  exit 0
fi

BUILD=build/ColorSwap.app
rm -rf build
mkdir -p "$BUILD/Contents/MacOS"

for arch in arm64 x86_64; do
  swiftc -O -target $arch-apple-macos13 main.swift -o build/ColorSwap-$arch
done
lipo -create build/ColorSwap-arm64 build/ColorSwap-x86_64 -output "$BUILD/Contents/MacOS/ColorSwap"
rm build/ColorSwap-*
cp -R Resources "$BUILD/Contents/Resources"

cat > "$BUILD/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>ColorSwap</string>
  <key>CFBundleIdentifier</key><string>local.colorswap</string>
  <key>CFBundleName</key><string>ColorSwap</string>
  <key>CFBundleDisplayName</key><string>Print without Black</string>
  <key>LSHasLocalizedDisplayName</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>PDF</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>com.adobe.pdf</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$BUILD" >/dev/null

mkdir -p "$HOME/Applications" "$SERVICES"
remove_links
rm -rf "$APP"
cp -R "$BUILD" "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"

NAME="$("$APP/Contents/MacOS/ColorSwap" --menu-name)"
ln -sfn "$APP" "$SERVICES/$NAME"

echo "Installed: $APP"
echo "Print dialog → PDF ▾ → «$NAME»"
