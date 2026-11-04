#!/bin/zsh
# Builds "Fulbright Study Tours.app" into ./dist (release build, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/Fulbright Study Tours.app"
swift build -c release --product StudyTours

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Logos"
cp "$(swift build -c release --show-bin-path)/StudyTours" "$APP/Contents/MacOS/StudyTours"
cp Resources/Logos/* "$APP/Contents/Resources/Logos/" 2>/dev/null || true
# organisation config (not part of the open-source code)
if [[ -f config/studytours.config.json ]]; then
  cp config/studytours.config.json "$APP/Contents/Resources/config.json"
else
  echo "Note: config/studytours.config.json not found — the app will ask for it (see config/studytours.config.example.json)."
fi

# App icon (optional): Resources/AppIcon.png, else the Fulbright globe from Resources/Logos if present.
SRC=""
if [[ -f Resources/AppIcon.png ]]; then SRC="Resources/AppIcon.png"
elif [[ -f Resources/Logos/Fulbright_Globe_RGB_FullColor.png ]]; then SRC="Resources/Logos/Fulbright_Globe_RGB_FullColor.png"; fi
ICON_PLIST=""
if [[ -n "$SRC" ]]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$SRC" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  ICON_PLIST="<key>CFBundleIconFile</key><string>AppIcon</string>"
else
  echo "Note: no app icon found (Resources/AppIcon.png) — building without icon."
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Fulbright Study Tours</string>
  <key>CFBundleDisplayName</key><string>Fulbright Study Tours</string>
  <key>CFBundleIdentifier</key><string>org.fulbright.studytours</string>
  <key>CFBundleExecutable</key><string>StudyTours</string>
  ICON_PLACEHOLDER
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
</dict></plist>
PLIST
/usr/bin/sed -i '' "s|ICON_PLACEHOLDER|${ICON_PLIST}|" "$APP/Contents/Info.plist"

codesign --force --deep --sign - "$APP"
echo "Built: $APP"
