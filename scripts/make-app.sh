#!/bin/bash
# 打包選單列 App：SideScreen42.app（LSUIElement，沒有 Dock 圖示），裝到 /Applications 並打開
# 簽章：有 Apple Development／Developer ID 憑證就用（重建後「螢幕與系統錄音」授權不會失效），沒有才 ad-hoc
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${APP:-/Applications/SideScreen42.app}"
BIN=".build/release/SideScreen42"
VERSION="1.1.0"

swift build -c release --product SideScreen42 2>&1 | tail -1
[ -x "$BIN" ] || { echo "✗ 建置失敗：找不到 $BIN" >&2; exit 1; }

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | grep -Eo '"(Developer ID Application|Apple Development): [^"]+"' | head -1 | tr -d '"' || true)}"
IDENTITY="${IDENTITY:--}"

osascript -e 'tell application "SideScreen42" to quit' 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x SideScreen42 >/dev/null || break; sleep 0.5; done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SideScreen42"
cp receiver/index.html "$APP/Contents/Resources/SideScreen-receiver.html"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>SideScreen42</string>
  <key>CFBundleDisplayName</key><string>SideScreen42</string>
  <key>CFBundleIdentifier</key><string>com.okle42.sidescreen42</string>
  <key>CFBundleExecutable</key><string>SideScreen42</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleDevelopmentRegion</key><string>zh-Hant</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$(git rev-list --count HEAD 2>/dev/null || echo 1)</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Okle42 · MIT</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "✅ 已裝到 ${APP}（簽章：${IDENTITY}）"
open "$APP"
