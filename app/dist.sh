#!/bin/bash
# 打可分发的安装包：
#   dist/Dew.dmg          ← 给用户的主包，文件名固定，README 的下载按钮永远指向
#                            releases/latest/download/Dew.dmg，发新版不用改链接
#   dist/Dew-<版本>.zip   ← 备用
# 免费路线：本机自签 + 不公证。第一次打开要绕过 Gatekeeper，见 README「安装」。
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/Dew.app/Contents/Info.plist)
mkdir -p dist

ZIP="dist/Dew-$VERSION.zip"
rm -f "$ZIP"
# ditto 保留签名与资源叉，zip 命令会弄丢
ditto -c -k --keepParent build/Dew.app "$ZIP"

DMG="dist/Dew.dmg"
rm -f "$DMG"
STAGE=$(mktemp -d)
cp -R build/Dew.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"      # 打开 dmg 就能把 Dew 拖进去
hdiutil create -quiet -volname "Dew $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

echo "✓ $DMG  ($(du -h "$DMG" | cut -f1))"
echo "✓ $ZIP  ($(du -h "$ZIP" | cut -f1))"
echo
echo "发版："
echo "  gh release create v$VERSION dist/Dew.dmg $ZIP --title \"Dew $VERSION\" --notes-file <说明>"
