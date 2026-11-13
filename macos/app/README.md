# TuneFree for Mac（图形界面）

原生 SwiftUI 界面，驱动 `../tunefree_backend`（`--json` 事件流）。
发布出去的 `TuneFree.app` **自带 Python 运行时和 ffmpeg**，用户机器上什么都不用装。

## 打包

```bash
cd macos
bash app/build.sh                    # 两种芯片都打 → dist/<架构>/TuneFree.app 与 dist/TuneFree-<版本>-<架构>.dmg
bash app/build.sh --arch arm64       # 只打 Apple 芯片版
bash app/build.sh --arch x86_64      # 只打 Intel 版
bash app/build.sh --reuse-backend    # 后端没改时，跳过 PyInstaller，快很多
bash app/build.sh --no-dmg           # 只要 .app
```

只需要 Xcode 命令行工具（`xcode-select --install`）。脚本会：

1. 用 PyInstaller 把后端打成 `TuneFreeBackend/`（内置 Python 运行时：arm64 用 3.9，x86_64 用 3.12），再塞一份静态 ffmpeg；
2. `swift build -c release` 编界面。新版 SDK 的 `@State` 是宏、宏插件只随完整 Xcode 提供，
   所以没有 Xcode 时脚本会自动挑一个能编过的 SDK；
3. 画图标（`Support/make_icon.swift`）、组装 `.app`、由内到外签名、跑一遍包内自检、做 DMG。

签名默认是 ad-hoc。别人第一次打开要「右键 → 打开」（或 系统设置 → 隐私与安全性 → 仍要打开）。
有开发者证书时：`CODESIGN_ID="Developer ID Application: …" bash app/build.sh`，会开启 hardened runtime，之后可以去公证。

### 两种芯片

每种芯片单独一个包（不做通用二进制，单个下载更小）：arm64 版约 26 MB，x86_64 版约 38 MB（Intel 版 ffmpeg 更大）。

- **界面**：`swift build --arch <架构>` 直接交叉编译。
- **后端**：PyInstaller 只能打「运行它的那个 Python」的架构。arm64 默认用系统 `python3`；
  x86_64 默认用 [uv](https://github.com/astral-sh/uv) 管理的独立版 CPython 3.12
  （没有就自动 `uv python install cpython-3.12-macos-x86_64-none`），在 Rosetta 下运行。
  也可以用 `BUILD_PYTHON_ARM64=…` / `BUILD_PYTHON_X86_64=…` 指定解释器。
- 在 Apple 芯片上交叉打 Intel 版需要 Rosetta（`softwareupdate --install-rosetta`），包内自检也在 Rosetta 下跑。
  脚本会给 `lipo` 等工具套一层，让它们原生运行（命令行工具的 `libxcrun` 只有 arm64）。
- 每个包组装后都会检查主程序、后端和 ffmpeg 的架构是否对得上。

## 开发

```bash
cd macos/app
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift run   # 没有 Xcode 时指定 SDK
```

`swift run` 时没有 App 包，界面会顺着可执行文件往上找 `macos/main.py`，用系统 `python3` 跑源码后端。
也可以用 `TUNEFREE_BACKEND_SRC=/path/to/macos` 指定。

调试用环境变量（不影响正常使用）：

| 变量 | 作用 |
|---|---|
| `TUNEFREE_DEBUG_OPEN=<目录>` | 启动后自动载入这个文件夹 |
| `TUNEFREE_DEBUG_OUTPUT=<目录>` | 本次的导出目录（不写入偏好设置） |
| `TUNEFREE_DEBUG_AUTORUN=1` | 载入完成后自动开始 |
| `TUNEFREE_DEBUG_ONBOARDING=1` | 强制弹出首次使用说明（调试运行时默认不弹） |
| `TUNEFREE_DEBUG_VERSION=<版本>` | 假装当前是这个版本，用来测检查更新（如 `2.1.3-mac.1`） |
| `TUNEFREE_DEBUG_SNAPSHOT=<目录>` | 每秒把窗口截成 PNG，共 `TUNEFREE_DEBUG_SHOTS` 张后退出 |

## 结构

```
app/
├── Package.swift
├── build.sh                    打包脚本
├── Support/Info.plist          App 元数据（版本号由脚本填）
├── Support/make_icon.swift     画 1024px 图标
└── Sources/TuneFree/
    ├── TuneFreeApp.swift       入口、菜单、窗口样式
    ├── Model/Backend.swift     找后端、起进程、逐行解析 JSON 事件
    ├── Model/AppModel.swift    状态机：选目录 → 探查 → 运行 → 结果
    ├── Model/Track.swift       曲目与状态
    └── Views/                  界面（极光背景、曲目列表、设置面板、进度条、结果卡片、日志）
```

## 检查更新与首次说明

- **检查更新**（`Model/Updater.swift`）：启动 3 秒后自动查一次、之后每 24 小时一次（设置 ⌘, 里可关，默认开）；
  菜单「TuneFree → 检查更新…」手动查。先问 GitHub API 拿版本和更新说明，API 不通时退回
  `releases/latest` 的跳转拿 tag。版本号按数字逐段比较（`2.1.3-mac.5` → 2,1,3,5），
  「下载新版本」直接打开对应芯片的 DMG（`TuneFree-<版本>-arm64|x86_64.dmg`），所以发布时要保持这个命名。
  转换进行中不弹窗，只在顶栏显示「新版本」提示。
- **首次说明**（`Views/OnboardingView.swift`）：首次打开弹出使用说明 + 免责声明，勾选同意才能继续；
  免责声明有改动时把 `disclaimerVersion` 加一，所有人会再看到一次。之后可从「帮助」菜单再次查看。

## 用到的后端事件

`info`（`--info --json`，列表里的格式/布局/是否需要登录态）、`progress`、`log`、
`decrypt-ok` / `decrypt-skip` / `decrypt-fail`、`tags`（最终标签 + 封面路径，列表里显示封面和专辑）、
`transcode-ok` / `transcode-skip` / `transcode-fail`、`result`。
停止按钮发 SIGINT，后端做完当前这首后退出（退出码 130）。
