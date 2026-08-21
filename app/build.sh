#!/bin/bash
# 直接用 swiftc 构建并组装 .app。
# 不走 SwiftPM：纯 Command Line Tools 环境下 PackageDescription 链接是坏的。
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Dew"
BUNDLE_ID="com.cinder.dew"
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
  $(find Sources/Dew -name '*.swift')

echo "→ 图标"
if [ -f "../assets/logo/Dew.icns" ]; then
  cp "../assets/logo/Dew.icns" "$APP/Contents/Resources/Dew.icns"; echo "  Dew.icns 已打入"
else
  echo "  (未找到 ../assets/logo/Dew.icns，先跑 ../assets/logo/render-icon.sh)"
fi

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
  <key>CFBundleIconFile</key><string>Dew</string>
  <!-- 常驻组件：不进 Dock、不抢 App 切换器 -->
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "→ 签名"
# 优先用本机自签的稳定身份「Dew Dev」。
# 身份稳定 = 钥匙串的「始终允许」只需点一次；临时签名(-)每次构建都变，会反复弹窗。
# 没有这个身份时退回临时签名。创建方法见 README「签名身份」。
# 按顺序找可用的稳定签名身份。Dew Dev 是正式的；GlassBar Dev 是改名前留下的，
# 用它签也没问题（身份名用户看不到，要的只是「稳定」）。都没有才退回临时签名。
SIGNED=""
for IDENTITY in "Dew Dev" "GlassBar Dev"; do
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    if codesign --force --deep --sign "$IDENTITY" --options runtime \
                --identifier "$BUNDLE_ID" "$APP" 2>/dev/null; then
      echo "  用 $IDENTITY 签名"; SIGNED=1; break
    fi
  fi
done
if [ -z "$SIGNED" ]; then
  codesign --force --deep --sign - "$APP" 2>/dev/null || true
  echo "  (临时签名，钥匙串授权每次构建会再弹一次)"
fi

echo "✓ 构建完成：$APP"
