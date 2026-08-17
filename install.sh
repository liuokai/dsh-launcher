#!/bin/bash
# 安装/更新 DSH.app 到 /Applications
# 一键流程：退出运行中的旧版 → 旧版移入废纸篓（可回滚）→ 复制新版 → 重签名 → 重新启动
# 用法：先 ./build.sh 再 ./install.sh（或 ./build.sh && ./install.sh）
set -euo pipefail
cd "$(dirname "$0")"

APP="$PWD/build/DSH.app"
DEST="/Applications/DSH.app"

if [ ! -d "$APP" ]; then
  echo "未找到 $APP，请先运行 ./build.sh"
  exit 1
fi

# 1) 退出正在运行的实例（必须先退出：一是运行中替换文件不可靠，
#    二是 App 有单实例检查，旧版不退的话新版启动会自动退出）
if pgrep -f "MacOS/DSH" >/dev/null 2>&1; then
  echo "==> 退出正在运行的 DSH"
  osascript -e 'tell application "DSH" to quit' 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f "MacOS/DSH" >/dev/null 2>&1 || break
    sleep 0.5
  done
  # 仍未退出（例如被对话框卡住）则强制结束
  pkill -f "MacOS/DSH" 2>/dev/null || true
fi

# 2) 旧版移入废纸篓（保留回滚途径，不做永久删除）
if [ -d "$DEST" ]; then
  BAK="$HOME/.Trash/DSH.app.bak-$(date +%Y%m%d-%H%M%S)"
  echo "==> 旧版移入废纸篓：$BAK"
  mv "$DEST" "$BAK"
fi

# 3) 清理旧命名遗留（同样移废纸篓）
if [ -d "/Applications/DSHLauncher.app" ]; then
  mv "/Applications/DSHLauncher.app" "$HOME/.Trash/DSHLauncher.app.bak-$(date +%Y%m%d-%H%M%S)"
fi

# 4) 安装新版并重新签名（ad-hoc）
echo "==> 安装新版"
cp -R "$APP" /Applications/
codesign --force --deep -s - "$DEST"
echo "已安装到 $DEST"

# 5) 重新启动
open "$DEST"
echo "==> 已重新启动，更新完成"
