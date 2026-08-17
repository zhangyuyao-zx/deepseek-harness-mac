#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="DeepSeek助手.app"
BUNDLE="$APP/Contents"
BIN="$BUNDLE/MacOS/DeepSeekAssistant"

# 本机 CLT 的 26.5 SDK 与 Swift 编译器版本不匹配（6.3.2/6.3.3），改用 15.4 SDK
SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
export TMPDIR="$PWD/.cache/tmp"
mkdir -p "$TMPDIR" .cache/module
CACHE="$(cd .cache && pwd)"

# 不批量删除：直接原地覆盖旧产物，避免误删风险
mkdir -p "$BUNDLE/MacOS" "$BUNDLE/Resources" out/AppIcon.iconset

echo "[1/4] 编译 Swift…"
swiftc -sdk "$SDK" -module-cache-path "$CACHE/module" \
  -O -swift-version 5 -framework AppKit -framework WebKit \
  -o "$BIN" src/main.swift src/UsagePanel.swift

echo "[2/4] 生成图标…"
if [ -f "icon-source.png" ]; then
  sips -s format png -z 1024 1024 "icon-source.png" --out "out/icon_1024.png" >/dev/null
elif [ -f "icon-source.jpg" ]; then
  sips -s format png -z 1024 1024 "icon-source.jpg" --out "out/icon_1024.png" >/dev/null
else
  swift -sdk "$SDK" -module-cache-path "$CACHE/module" make-icon.swift "out/icon_1024.png"
fi
cp out/icon_1024.png "out/AppIcon.iconset/icon_512x512@2x.png"
for spec in "16 16" "16 32" "32 32" "32 64" "128 128" "128 256" "256 256" "256 512" "512 512"; do
  set -- $spec
  if [ "$1" = "$2" ]; then
    name="icon_${1}x${1}"
  else
    name="icon_${1}x${1}@2x"
  fi
  sips -z "$2" "$2" out/icon_1024.png --out "out/AppIcon.iconset/${name}.png" >/dev/null
done
iconutil -c icns out/AppIcon.iconset -o "$BUNDLE/Resources/AppIcon.icns"

echo "[3/4] Info.plist…"
cp Info.plist "$BUNDLE/Info.plist"

echo "[4/4] ad-hoc 签名…"
codesign --force --deep -s - "$APP"

echo ""
echo "完成：$(pwd)/$APP"
codesign -dv "$APP" 2>&1 | head -3
