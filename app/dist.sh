#!/bin/bash
# 打一个可以直接发给同事的 zip。
# 免费路线：本机自签 + 不公证。收件人第一次打开需要右键 →「打开」一次，之后正常双击。
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/GlassBar.app/Contents/Info.plist)
OUT="dist/GlassBar-$VERSION.zip"
mkdir -p dist && rm -f "$OUT"
# ditto 保留签名与资源叉，zip 命令会弄丢
ditto -c -k --keepParent build/GlassBar.app "$OUT"
echo "✓ $OUT  ($(du -h "$OUT" | cut -f1))"
echo
echo "发给同事时附这句话："
echo "  解压后把 GlassBar.app 拖到「应用程序」，第一次用 右键 → 打开（不是双击），之后就正常了。"
