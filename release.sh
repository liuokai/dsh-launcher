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

### 安装
下载 \`DSH.app.zip\`，解压后把 DSH.app 拖入「应用程序」文件夹，双击运行。

> 首次打开如提示「无法验证开发者」：右键 App → 打开；或执行
> \`xattr -dr com.apple.quarantine /Applications/DSH.app\`

### 功能
- 一键启动 \`npx --yes @deepseek-ai/dsh web\` 并内嵌打开 Web GUI
- 原生深色外观、圆角浮层面板、品牌化启动页
- 服务生命周期管理、端口配置、登录自启
- 详见仓库 README"

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
