# TuneFree for Mac（图形界面）

原生 SwiftUI 界面，驱动 `../tunefree_backend`（`--json` 事件流）。
发布出去的 `TuneFree.app` **自带 Python 运行时和 ffmpeg**，用户机器上什么都不用装。

## 打包

```bash
cd macos
bash app/build.sh                  # → dist/TuneFree.app 与 dist/TuneFree-<版本>-<架构>.dmg
bash app/build.sh --reuse-backend  # 后端没改时，跳过 PyInstaller，快很多
bash app/build.sh --no-dmg         # 只要 .app
```

只需要 Xcode 命令行工具（`xcode-select --install`）。脚本会：

1. 用 PyInstaller 把后端打成 `TuneFreeBackend/`（内置 Python 3.9 运行时），再塞一份静态 ffmpeg；
2. `swift build -c release` 编界面。新版 SDK 的 `@State` 是宏、宏插件只随完整 Xcode 提供，
   所以没有 Xcode 时脚本会自动挑一个能编过的 SDK；
3. 画图标（`Support/make_icon.swift`）、组装 `.app`、由内到外签名、跑一遍包内自检、做 DMG。

签名默认是 ad-hoc。别人第一次打开要「右键 → 打开」（或 系统设置 → 隐私与安全性 → 仍要打开）。
有开发者证书时：`CODESIGN_ID="Developer ID Application: …" bash app/build.sh`，会开启 hardened runtime，之后可以去公证。

产物只适用于构建机的 CPU 架构（Apple 芯片打出来就是 arm64）。

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

## 用到的后端事件

`info`（`--info --json`，列表里的格式/布局/是否需要登录态）、`progress`、`log`、
`decrypt-ok` / `decrypt-skip` / `decrypt-fail`、`transcode-ok` / `transcode-skip` / `transcode-fail`、`result`。
停止按钮发 SIGINT，后端做完当前这首后退出（退出码 130）。
