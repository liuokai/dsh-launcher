#!/bin/bash
# 安装 DSH.app 到 /Applications
set -euo pipefail
cd "$(dirname "$0")"

APP="$PWD/build/DSH.app"
if [ ! -d "$APP" ]; then
  echo "未找到 $APP，请先运行 ./build.sh"
  exit 1
fi

rm -rf "/Applications/DSHLauncher.app"   # 清理旧名遗留
rm -rf "/Applications/DSH.app"
cp -R "$APP" /Applications/
codesign --force --deep -s - "/Applications/DSH.app"

echo "已安装到 /Applications/DSH.app"
echo "运行: open /Applications/DSH.app"
