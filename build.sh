#!/bin/bash
# 构建 DSH.app（需要 Xcode Command Line Tools：xcode-select --install）
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="DSH"
ROOT="$PWD"
BUILD="$ROOT/build"
APP="$BUILD/$APP_NAME.app"

echo "==> 清理并创建目录"
rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 编译 Swift 源码"
swiftc -O -swift-version 5 \
  -o "$APP/Contents/MacOS/$APP_NAME" \
  "$ROOT/Sources/main.swift" \
  -framework AppKit -framework WebKit -framework ServiceManagement

echo "==> 生成应用图标（DeepSeek 鲸鱼 · Chrome 式白底黑鲸）"
if swift "$ROOT/tools/make_icon.swift" "$ROOT/Resources/whale.svg" "$BUILD/AppIcon.iconset" >/dev/null 2>&1; then
  iconutil -c icns "$BUILD/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
  echo "    图标已生成"
else
  echo "    [警告] 图标生成失败，将使用系统默认图标"
fi

echo "==> 写入 Info.plist"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

echo "==> 复制品牌资源（启动页鲸鱼）"
cp "$ROOT/Resources/whale.svg" "$APP/Contents/Resources/whale.svg"

echo "==> 签名（ad-hoc）"
codesign --force --deep -s - "$APP"

echo ""
echo "构建完成: $APP"
echo "安装:     ./install.sh   （或手动 cp -R \"$APP\" /Applications/）"
