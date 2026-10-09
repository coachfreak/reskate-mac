#!/bin/zsh
# Builds build/ReSkate.app (Apple Silicon). Needs Xcode command line tools.
set -euo pipefail
cd "${0:A:h}"

APP=build/ReSkate.app
ZSTD_VERSION=1.5.7

# Standalone zstd decompressor (macOS tar can't read .zst); built once from source
if [[ ! -x Resources/zstd ]]; then
  mkdir -p Resources .cache
  curl -fsSL -o .cache/zstd.tar.gz "https://github.com/facebook/zstd/releases/download/v$ZSTD_VERSION/zstd-$ZSTD_VERSION.tar.gz"
  tar -xzf .cache/zstd.tar.gz -C .cache
  make -C ".cache/zstd-$ZSTD_VERSION/programs" zstd-decompress MOREFLAGS="-arch arm64 -arch x86_64 -mmacosx-version-min=13.0" -j8 >/dev/null
  cp ".cache/zstd-$ZSTD_VERSION/programs/zstd-decompress" Resources/zstd
fi

# Fonts the ReSkate launcher uses (Montserrat: OFL, Permanent Marker: Apache 2.0)
if [[ ! -f Resources/Fonts/PermanentMarker-Regular.ttf ]]; then
  mkdir -p Resources/Fonts
  for w in ExtraBold Bold SemiBold Medium; do
    curl -fsSL -o "Resources/Fonts/Montserrat-$w.ttf" "https://github.com/JulietaUla/Montserrat/raw/master/fonts/ttf/Montserrat-$w.ttf"
  done
  curl -fsSL -o Resources/Fonts/Montserrat-OFL.txt https://github.com/JulietaUla/Montserrat/raw/master/OFL.txt
  curl -fsSL -o Resources/Fonts/PermanentMarker-LICENSE.txt https://raw.githubusercontent.com/google/fonts/main/apache/permanentmarker/LICENSE.txt
  curl -fsSL -o Resources/Fonts/PermanentMarker-Regular.ttf https://raw.githubusercontent.com/google/fonts/main/apache/permanentmarker/PermanentMarker-Regular.ttf
fi

[[ -d build ]] && rm -r ./build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/AppIcon.iconset

swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 Sources/*.swift -o "$APP/Contents/MacOS/ReSkate"
cp Resources/zstd "$APP/Contents/Resources/zstd"
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"

swift Icon/make_icon.swift build/icon.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon.png --out "build/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) build/icon.png --out "build/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ReSkate</string>
  <key>CFBundleDisplayName</key><string>ReSkate</string>
  <key>CFBundleIdentifier</key><string>local.reskate.maclauncher</string>
  <key>CFBundleExecutable</key><string>ReSkate</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>ATSApplicationFontsPath</key><string>Fonts</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string></array>
</dict>
</plist>
EOF

codesign --force --deep -s - "$APP"
echo "Built: $APP"

# Release disk image: app + Applications shortcut on a styled background (dmgbuild writes the layout, no Finder scripting)
[[ -x .cache/venv/bin/dmgbuild ]] || { python3 -m venv .cache/venv && .cache/venv/bin/pip install -q dmgbuild; }
swift Icon/make_dmg_background.swift Resources/Fonts build/dmg-bg.png build/dmg-bg@2x.png
tiffutil -cathidpicheck build/dmg-bg.png build/dmg-bg@2x.png -out build/dmg-bg.tiff 2>/dev/null
.cache/venv/bin/dmgbuild -s dmg_settings.py -D app="$APP" -D background=build/dmg-bg.tiff "ReSkate" build/ReSkate.dmg >/dev/null
echo "Built: build/ReSkate.dmg"
