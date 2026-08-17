# DSH — DeepSeek Harness Mac 启动器

一个原生 macOS App（Swift + AppKit + WKWebView），双击即启动 DeepSeek Harness，无需再在终端敲 `npx @deepseek-ai/dsh web` 并手动打开浏览器。

> 非 DeepSeek 官方产品，社区个人工具。

## 功能特性

- 🚀 **一键启动**：自动运行 `npx --yes @deepseek-ai/dsh web --port 3080`（与终端命令等价）
- 🖥️ **内嵌窗口**：服务就绪后在 App 内直接打开 Web GUI，无需浏览器
- 🔗 **智能连接**：端口已有 dsh 服务时直接连接，不会重复启动
- 🧹 **生命周期管理**：退出 App 自动停止服务进程（可关闭该行为）
- 🌙 **原生深色外观**：窗口与页面主题无缝融合，圆角浮层面板 + Safari 风格工具栏
- 🐋 **品牌启动页**：启动/重启时显示鲸鱼 logo、实时日志卡片
- 🔔 **登录时自动启动**：菜单一键开启（SMAppService）
- 🧪 **无头自测**：`--selftest` 端到端验证启动链路

## 截图

（待补充：应用主界面 / 启动页 / 全屏效果）

## 快速开始

### 方式一：直接下载（推荐）

从 [Releases](../../releases) 下载 `DSH.app.zip`，解压后拖入「应用程序」文件夹，双击运行。

### 方式二：从源码构建

```bash
git clone https://github.com/liuokai/dsh-launcher.git && cd dsh-launcher
./build.sh        # 编译并生成 build/DSH.app（需 Xcode Command Line Tools）
./install.sh      # 一键安装/更新到 /Applications（自动退出旧版、留底废纸篓并重启）
```

日常迭代只需 `./build.sh && ./install.sh`；也可以跳过安装，直接运行 `build/DSH.app` 测试。

## 使用说明

| 功能 | 入口 |
|---|---|
| 在系统浏览器打开 | 右上角工具栏「浏览器打开」或 ⌘O |
| 刷新页面 | 右上角工具栏「刷新」或 ⌘R |
| 重启服务 | 右上角工具栏「重启服务」或 ⇧⌘R |
| 显示/隐藏服务日志 | 右下角「日志」按钮或 ⌘L |
| 修改端口 | 菜单「服务器 → 端口设置…」 |
| 退出时保留服务 | 菜单「服务器 → 退出时保留服务进程」 |
| 登录时自动启动 | 菜单「服务器 → 登录时自动启动」（需 App 位于 /Applications） |

## 工作原理

1. 启动时探测 `http://127.0.0.1:<port>/`：若返回 DeepSeek Harness 页面（检测 `__DSH_BOOT__` 标记），直接内嵌连接。
2. 否则定位 npx：Finder 启动的 App 环境 PATH 很干净，App 依次尝试 `zsh -l` / `zsh -i` / `bash -l` 的 `command -v npx`，再兜底常见安装路径（Homebrew、`.local/bin`、hermes、volta、fnm 等）。
3. 以登录 shell 的 PATH 启动 `npx --yes @deepseek-ai/dsh web --port <port>`，轮询直到页面就绪（首次运行 npx 需下载 dsh 包）。
4. 退出时若服务由本 App 启动，发送 SIGTERM（2.5s 后 SIGKILL 兜底）。

## 高级配置

```bash
# 默认端口（也可用菜单改）
defaults write com.deepseek.dsh port 8080

# 追加传给 dsh web 的额外参数（空格分隔）
defaults write com.deepseek.dsh extraArgs "--trusted-host 192.168.1.5"
```

## 无头自测

```bash
./build/DSH.app/Contents/MacOS/DSH --selftest
# 可选指定端口：--selftest --port 3456
```

自测流程：定位 npx → 在隔离 HOME 中启动 dsh web → 轮询就绪 → 停止进程，全部通过输出 `SELFTEST READY ...` / `SELFTEST STOPPED OK`。

## 项目结构

```
DSH/
├── Sources/
│   └── main.swift        # 全部源码：窗口/面板/状态栏/服务管理/自测
├── Resources/
│   ├── Info.plist        # App 配置
│   └── whale.svg         # 鲸鱼标识（品牌资产，见版权说明）
├── tools/
│   └── make_icon.swift   # 图标生成器（SVG → iconset → icns）
├── build.sh              # 构建脚本（编译/图标/打包/签名）
├── install.sh            # 安装脚本（/Applications）
└── README.md
```

## 常见问题

- **提示「未找到 npx」**：未安装 Node.js，或 npx 只配置在非登录 shell。安装后重试：`brew install node`。
- **提示「端口被其他程序占用」**：菜单「服务器 → 端口设置…」换端口。
- **登录时自动启动失败**：需要把 App 移到 /Applications 目录。
- **窗口关闭 = 退出 App**：会连带停止服务（除非勾选「退出时保留服务进程」）。
- **下载的 Release 提示「无法验证开发者」**：App 为 ad-hoc 签名，首次打开请右键 → 打开，或执行 `xattr -dr com.apple.quarantine /Applications/DSH.app`。

## 环境要求

- macOS 13.0+（Apple Silicon / Intel）
- 构建需要 Xcode Command Line Tools（`xcode-select --install`），无需完整 Xcode
- 运行需要 Node.js 环境（npx 可用即可）

---

## 版权与许可

### 项目许可

本项目以 [MIT License](LICENSE) 开源：你可以自由使用、修改、复制、分发，包括商用，但需保留版权声明与许可文本。作者不对使用本软件产生的任何后果承担责任。

### 商标与品牌资产

- **「DSH」名称**：本项目命名为 DSH，仅为 DeepSeek Harness 的缩写指代，与 DeepSeek 无隶属关系；**DeepSeek 及其标识是深度求索（DeepSeek）公司的商标**，MIT 许可不授予商标使用权。请勿以可能造成混淆的方式暗示本项目为 DeepSeek 官方产品。
- **鲸鱼标识（`Resources/whale.svg`）**：取自 DeepSeek Harness 官方前端资源（`@deepseek-ai/dsh-web-frontend` 的 favicon），**版权归 DeepSeek 所有**，不属于本项目 MIT 许可范围。本项目仅将其作为个人工具的应用图标与启动页标识使用。如需公开发布、商用或二次分发，请自行评估品牌资产使用规范；更稳妥的做法是替换为自己的原创图标。

### 如何应用本项目

1. **日常使用**：下载 Release 或源码构建（见上文「快速开始」），双击即可，无需终端操作。
2. **个人二次开发**：克隆仓库，修改 `Sources/main.swift` 后运行 `./build.sh && ./install.sh`。MIT 许可允许修改与再分发，但修改后的版本需保留原始版权声明。
3. **学习参考**：本项目的服务进程管理（定位 npx、探测端口、生命周期控制）、原生窗口美化（深色外观、圆角面板、统一工具栏）都是可复用的模式，欢迎参考借鉴；引用代码时注明出处即可。
4. **集成到其他项目**：MIT 许可允许将代码并入其他项目（含闭源），同样需保留版权声明。
5. **注意事项**：再分发时请勿使用 DeepSeek 官方鲸鱼标识作为默认图标（见上），并避免宣称官方关联。

### 第三方依赖

运行时仅调用系统框架（AppKit / WebKit / ServiceManagement）与 DeepSeek Harness 的 `npx @deepseek-ai/dsh` 命令，无其他第三方库。DeepSeek Harness 本身为 MIT 许可开源项目（[deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)）。
