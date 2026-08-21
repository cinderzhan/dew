#!/bin/bash
# SVG → iconset → Dew.icns。改了 dew-icon.svg 之后重跑一次即可。
set -euo pipefail
cd "$(dirname "$0")"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
xcrun swiftc -sdk "$SDK" -target arm64-apple-macosx14.0 -Onone -framework AppKit -o /tmp/RenderIcon RenderIcon.swift
/tmp/RenderIcon dew-icon.svg .
iconutil -c icns Dew.iconset -o Dew.icns
rm -rf Dew.iconset
echo "✓ Dew.icns"
