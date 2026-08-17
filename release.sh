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

**日志面板重构为底部抽屉**
- 日志面板停靠在网页与状态栏之间，打开时网页区域自动上移让位，不再遮挡输入框等页面内容
- 修复了服务就绪后日志面板无法唤出的问题（旧版悬浮面板随启动浮层一起被隐藏）
- 启动/重启服务时自动展开并实时显示日志，服务就绪后自动收起
- 连接外部启动的服务（非本 App 托管）时，日志面板会明确提示无进程日志

**日志入口优化**
- 移除工具栏中冗余的「日志」「复制地址」按钮；窗口右下角「日志」圆角按钮为唯一按钮入口，并带状态高亮（展开时强调色 + 实心图标）
- 快捷键 ⌘L 与菜单「服务器 → 显示/隐藏日志」保留

**工具栏调整**
- 刷新、浏览器打开、重启服务整体移至窗口右上角
- 「重启服务」图标由逆时针箭头改为电源符号，与「刷新」一眼可辨

**一键更新脚本**
- \`install.sh\` 升级为一键更新：自动退出运行中的旧版 → 旧版移入废纸篓留底 → 安装新版 → 重签名 → 自动重启，迭代只需 \`./build.sh && ./install.sh\`
- 不再使用 \`rm -rf\` 永久删除

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
