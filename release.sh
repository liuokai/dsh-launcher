#!/bin/bash
# 打包 DSH.app 并发布到 GitHub Release
# 用法: ./release.sh            # 版本号取自 Info.plist（当前 1.0）
#       ./release.sh 1.1        # 或显式指定版本
set -euo pipefail
cd "$(dirname "$0")"

REPO="liuokai/dsh-launcher"

echo "==> 构建最新版本"
if ! ./build.sh >/dev/null 2>&1; then
  echo "构建失败"
  exit 1
fi

APP="build/DSH.app"
if [ ! -d "$APP" ]; then
  echo "构建失败：未找到 $APP"
  exit 1
fi

VERSION="${1:-$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")}"
TAG="v$VERSION"
ZIP="dist/DSH.app.zip"

echo "==> 打包 ${APP}（版本 ${VERSION}）"
mkdir -p dist
rm -f "$ZIP"
ditto -c -k --keepParent --sequesterRsrc "$APP" "$ZIP"
echo "    产物: ${ZIP}（$(du -h "$ZIP" | cut -f1)）"

# 从 macOS 钥匙串读取 GitHub 凭据（git credential helper 已配置）
TOKEN=$(printf "protocol=https\nhost=github.com\n\n" | git credential fill | sed -n 's/^password=//p')
if [ -z "$TOKEN" ]; then
  echo "错误：未找到 GitHub 凭据，请先执行一次 git push 完成认证"
  exit 1
fi

BODY="DSH — DeepSeek Harness Mac 启动器 v$VERSION

### 更新内容

**修复「重新启动服务」无效的问题**
- 修复内部状态冲突导致点击「重新启动服务」后服务被停止却不会重启的 bug（该问题自 v1.0 存在）
- 停止服务时兜底清理仍占用端口的残留进程（杀 npm 父进程后 node 子进程可能存活占端口）

**版本与升级机制（绝不自动升级）**
- 启动只调起当前版本：直接调起本地 \`~/.npm/_npx\` 缓存中已装的最高版本 dsh，零联网、不解析 latest。不再出现上游发新版时被静默全量重新下载、卡在「等待服务就绪」的问题
- 自动检测：服务就绪后后台比对 npm 最新版本，发现新版仅在菜单「服务器 → 检查更新…」标注提示，不下载、不切换
- 手动升级：通过「检查更新…」确认后才下载新版本（进度见日志面板），完成后自动重启服务生效
- 状态栏显示当前使用的 dsh 版本号

**其他改进**
- 首次安装（下载依赖）的等待超时由 150 秒放宽至 600 秒，并增加「正在下载依赖」进度提示
- \`--selftest\` 适配新的启动链路

### 安装
下载 \`DSH.app.zip\`，解压后把 DSH.app 拖入「应用程序」文件夹，双击运行。

> 首次打开如提示「无法验证开发者」：右键 App → 打开；或执行
> \`xattr -dr com.apple.quarantine /Applications/DSH.app\`

完整功能介绍见仓库 README。"

echo "==> 创建 GitHub Release $TAG"
TMPJSON=$(mktemp)
python3 - "$TAG" "$BODY" > "$TMPJSON" <<'PYEOF'
import json, sys
print(json.dumps({'tag_name': sys.argv[1], 'name': sys.argv[1], 'body': sys.argv[2]}))
PYEOF
RELEASE_JSON=$(curl -s -X POST "https://api.github.com/repos/$REPO/releases" \
  -H "Authorization: token $TOKEN" \
  -H "Accept: application/vnd.github+json" \
  --data @"$TMPJSON")
rm -f "$TMPJSON"

RELEASE_ID=$(echo "$RELEASE_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("id",""))')
if [ -z "$RELEASE_ID" ]; then
  echo "创建失败：$(echo "$RELEASE_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("message","未知错误"))')"
  exit 1
fi
echo "    Release ID: $RELEASE_ID"

echo "==> 上传 $ZIP"
ASSET=$(curl -s -X POST "https://uploads.github.com/repos/$REPO/releases/$RELEASE_ID/assets?name=$(basename "$ZIP")" \
  -H "Authorization: token $TOKEN" \
  -H "Content-Type: application/zip" \
  --data-binary @"$ZIP")
ASSET_NAME=$(echo "$ASSET" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("name",""))')
if [ -z "$ASSET_NAME" ]; then
  echo "上传失败：$(echo "$ASSET" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("message","未知错误"))')"
  exit 1
fi

echo ""
echo "完成 ✅  Release: https://github.com/$REPO/releases/tag/$TAG"
