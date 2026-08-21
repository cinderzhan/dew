#!/bin/bash
# 直接用 swiftc 构建并组装 .app。
# 不走 SwiftPM：纯 Command Line Tools 环境下 PackageDescription 链接是坏的。
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="GlassBar"
BUNDLE_ID="com.cinder.glassbar"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
TARGET="arm64-apple-macosx14.0"
OUT="build"
APP="$OUT/$APP_NAME.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ 编译"
mkdir -p "$OUT"
# shellcheck disable=SC2046
xcrun swiftc \
  -sdk "$SDK" \
  -target "$TARGET" \
  -swift-version 5 \
  -Onone \
  -framework AppKit -framework SwiftUI -framework Combine \
  -o "$APP/Contents/MacOS/$APP_NAME" \
  $(find Sources/GlassBar -name '*.swift')

echo "→ 写 Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- 常驻组件：不进 Dock、不抢 App 切换器 -->
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "→ 签名"
# 优先用本机自签的稳定身份「GlassBar Dev」。
# 身份稳定 = 钥匙串的「始终允许」只需点一次；临时签名(-)每次构建都变，会反复弹窗。
# 没有这个身份时退回临时签名。创建方法见 README「签名身份」。
IDENTITY="GlassBar Dev"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  codesign --force --deep --sign "$IDENTITY" --options runtime \
           --identifier "$BUNDLE_ID" "$APP" 2>&1 | grep -v "replacing existing" || true
  echo "  用 $IDENTITY 签名"
else
  codesign --force --deep --sign - "$APP" 2>/dev/null || true
  echo "  (临时签名，钥匙串授权每次构建会再弹一次)"
fi

echo "✓ 构建完成：$APP"
