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
| `TUNEFREE_DEBUG_OPEN_AFTER=<秒>` | 延迟多久再载入 `TUNEFREE_DEBUG_OPEN` 的文件夹 |
| `TUNEFREE_DEBUG_START_AFTER=<秒>` | 载入完成后等多久再自动开始（默认 1.5） |
| `TUNEFREE_DEBUG_RECORD=<目录>` | 录屏：按 `TUNEFREE_DEBUG_RECORD_FPS`（默认 30）截窗口帧，录 `TUNEFREE_DEBUG_RECORD_SECONDS` 秒后退出，帧时间写在 `frames.txt` |
| `TUNEFREE_DEBUG_SHOWLOG=1` | 启动时打开日志面板 |
| `TUNEFREE_DEBUG_UPDATE_DMG=<路径>` | 用本地 DMG 当「新版本」（校验值现场算），测更新 / 回滚 |
| `TUNEFREE_DEBUG_BREAK_UPDATE=1` | 校验通过后故意弄坏新版，测「新版起不来 → 自动恢复旧版」 |
| `TUNEFREE_DEBUG_AUTOUPDATE=1` | 发现新版本就直接走一键更新（配合 `TUNEFREE_DEBUG_VERSION` 做端到端测试，建议在 App 的副本上跑） |
| `-appearanceMode light` / `dark` | 命令行参数：这次运行固定浅色 / 深色（截图对比两种外观用） |
| `TUNEFREE_DEBUG_ONBOARDING=1` | 强制弹出首次使用说明（调试运行时默认不弹） |
| `TUNEFREE_DEBUG_VERSION=<版本>` | 假装当前是这个版本，用来测检查更新（如 `2.9.0`） |
| `TUNEFREE_DEBUG_SNAPSHOT=<目录>` | 每秒把窗口截成 PNG，共 `TUNEFREE_DEBUG_SHOTS` 张后退出；`TUNEFREE_DEBUG_SHOT_TIMES=5,12,40` 指定在第几秒截 |
| `TUNEFREE_DEBUG_SNAPSHOT_OFFSCREEN=1` | 截图只在进程内渲染（`cacheDisplay`），一定不会触发「屏幕录制」授权；有弹出页时截弹出页 |
| `TUNEFREE_DEBUG_SHEET=settings` | 启动后打开某个弹出页（`settings` / `update` / `about` / `onboarding`） |

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
    └── Views/
        ├── CoverWall.swift     封面墙、封面状态、虚化封面背景、浮动滚动条
        ├── Sidebar.swift       右侧：导出设置卡片 + 进度 / 结果卡片
        ├── SettingsView.swift  设置页（⌘,）：版本、仓库、检查更新、外观、运行环境、缓存
        └── …                   顶栏、首页、更新窗口、首次说明、日志
```

## 检查更新与首次说明

- **检查更新**（`Model/Updater.swift`）：启动 3 秒后自动查一次、之后每 24 小时一次（设置 ⌘, 里可关，默认开）；
  菜单「TuneFree → 检查更新…」手动查。先问 GitHub API 拿版本和更新说明，API 不通时退回
  `releases/latest` 的跳转拿 tag。版本号按数字逐段比较（`3.0.1` → 3,0,1；旧的 `2.1.3-mac.12` → 2,1,3,12，所以 3.0.0 一定比所有旧版新），
  「立即更新」（`Model/UpdateInstaller.swift`）由 App 自己下载对应芯片的 DMG（`TuneFree-<版本>-arm64|x86_64.dmg`，
  发布时要保持这个命名）→ 用 GitHub API 返回的资产 `digest`（SHA-256）校验 → 挂载并拷出 App，检查签名
  （`codesign --strict`）、包名、版本、架构 → `replaceItemAt` 替换当前 App → 等自己退出后 `open` 新版本。
  App 自己下载的文件没有隔离标记，所以不会被 Gatekeeper 拦；正因为绕过了这一层，上面任何一步不通过都不安装，
  改为提示「手动下载」。从「下载」位置直接运行（App Translocation）或目录不可写时也只能手动更新。
  - **不留垃圾**：所有临时文件都在 `~/Library/Caches/TuneFree/update/<随机名>/`，DMG 解出 App 后立刻删；
    成功、失败、取消、回滚都会卸载挂载的 DMG 并删掉整个目录；下载走不落盘缓存的会话；
    启动时还会清理 15 分钟前因崩溃 / 断电中断留下的目录。
  - **失败自动回滚**：旧版先挪到备份（不删），换上新版后由一个小脚本等当前进程退出、打开新版
    （环境变量里的 `TUNEFREE_DEBUG_*` 会被去掉）；新版启动时看到 `pending` 就写 `healthy` 报到。
    25 秒内没报到（崩溃 / 打不开 / 被拦）就杀掉新版、恢复备份并重新打开旧版，旧版提示一次
    「更新没有成功，已自动恢复」，并且不再自动推这个版本（手动检查仍可见）。
  - **失败自动降级为手动更新**：一键更新在任何一步失败（下载、校验、签名、替换、不能原地更新），
    或者新版起不来被回滚后，都会自动用浏览器下载对应芯片的 DMG（原来的手动更新方式），并告诉用户怎么装。
    用户自己点「取消」不会触发。调试时设 `TUNEFREE_DEBUG_FALLBACK_LOG=<文件>` 只记录网址、不打开浏览器，
    `TUNEFREE_DEBUG_BAD_DIGEST=1` 可以模拟校验失败。
  转换进行中不弹窗，只在顶栏显示「新版本」提示。
- **首次说明**（`Views/OnboardingView.swift`）：首次打开弹出使用说明 + 免责声明，勾选同意才能继续；
  免责声明有改动时把 `disclaimerVersion` 加一，所有人会再看到一次。之后可从「帮助」菜单再次查看。

## 用到的后端事件

`info`（`--info --json`，列表里的格式/布局/是否需要登录态）、`progress`、`log`、
`decrypt-ok` / `decrypt-skip` / `decrypt-fail`、`tags`（最终标签 + 封面路径，列表里显示封面和专辑）、
`transcode-ok` / `transcode-skip` / `transcode-fail`、`result`。
停止按钮发 SIGINT，后端做完当前这首后退出（退出码 130）。

## 导入与失败重试

- 文件选择器与拖放均支持多个歌曲文件、多个文件夹以及混合选择；重叠路径去重。单文件不会扩大到所在目录。
- 预览和转换均通过 `--input-list <JSON 文件>` 传入已扫描的文件清单。JSON 的 `files` 是本次处理路径，`batch_files` 是原批次路径（均为绝对路径）；后者保证同名歌曲重试时沿用原输出名称。
- 转码只处理本次解密成功或跳过的产物，不扫描输出目录中的无关音频。
- 「仅重试失败项」只重新生成失败歌曲的输出，成功歌曲保留原状态；结果统计反映本次重试。
- 转换时手动滚动会暂停跟随，可点「回到正在处理」恢复；也可主动点「暂停跟随」。
- 解密与转码在本地进行；标签/封面获取及部分新版歌曲的密钥请求可能联网，不上传歌曲文件。

## 首页唱片陈列

启动时从 QQ音乐下载目录随机取样最多 12 个受支持文件，先查已缓存封面，再根据「联网补全标签」设置获取缺失封面，最多展示 3 张不同专辑封面。首页活跃时每 12 秒尝试刷新一组，预解码后以 0.9 秒交叉淡化切换；离开首页或窗口不活跃时暂停定时刷新；读取过程不改变当前批次，也不解密或转码。目录不可读或未找到封面时使用系统唱片图标。`--home-covers --json -i <目录> --no-online-tags` 可验证仅缓存模式。开发时 `TUNEFREE_DEBUG_HOME=<目录>` 可替换取样目录。

首页、工作区使用静态清浅底色，深色继续跟随外观设置；右侧导出设置与结果共用完整面板，上部设置在空间不足时可滚动，底部操作保留。
