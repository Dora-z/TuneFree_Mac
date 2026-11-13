<p align="center">
  <img src="assets/icon.png" width="128" alt="TuneFree 图标">
</p>

<h1 align="center">TuneFree for Mac</h1>

<p align="center">
  <b>把 QQ音乐下载的加密歌曲（<code>.mflac</code> / <code>.mgg</code>）变成任何播放器都能放的 <code>MP3</code> / <code>FLAC</code>。</b><br>
  原生 macOS 应用 · 本机离线解密 · 不需要 QQ音乐在运行
</p>

<p align="center">
  <a href="https://github.com/Dora-z/TuneFree_Mac/releases/latest"><img src="https://img.shields.io/github/v/release/Dora-z/TuneFree_Mac?color=2ea043&label=release" alt="Release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-111?logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Apple%20芯片-arm64-6e7781" alt="Apple Silicon">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/Dora-z/TuneFree_Mac?color=8957e5" alt="License"></a>
</p>

<p align="center">
  <a href="https://github.com/Dora-z/TuneFree_Mac/releases/latest"><b>⬇️ 下载最新版</b></a> · <a href="README.en.md">English</a>
</p>

<p align="center">
  <img src="assets/screenshot-library.png" width="860" alt="TuneFree 主界面：曲目列表与输出设置">
</p>

## 它解决什么问题

QQ音乐下载的部分歌曲是加密容器，只有 QQ音乐自己能放：

| 扩展名 | 实际内容 |
|---|---|
| `.mflac` / `.mflac0` | 加密的 `FLAC`（无损） |
| `.mgg` / `.mgg1` / `.mggl` | 加密的 `OGG` |
| `.qmcflac` / `.qmcogg` / `.qmc0` / `.qmc3` | 老版本客户端的加密格式 |

拷到车机、MP3、手机或别的播放器里就是「格式不支持」。TuneFree 在你自己的 Mac 上把它们还原成普通音频，再转成 `MP3`：

```
.mflac / .mgg  ──解密──▶  .flac / .ogg  ──转码──▶  .mp3
```

## 三步就能用

1. 下载 [`TuneFree-…-arm64.dmg`](https://github.com/Dora-z/TuneFree_Mac/releases/latest)，把 TuneFree 拖进「应用程序」
2. 打开 TuneFree，把放着加密歌曲的文件夹拖进窗口（或点「打开 QQ音乐缓存」）
3. 选好输出格式和音质，点 **开始转换**，完成后点「在 Finder 中打开」

App 里自带 Python 运行时和 ffmpeg，**不需要另外安装任何东西**。

<p align="center">
  <img src="assets/screenshot-done.png" width="860" alt="转换完成后的结果卡片">
</p>

## 功能

- 🎵 批量处理，自动查找子文件夹
- 🎚 三种输出：仅 MP3 / MP3 + 无损 FLAC / 仅无损；MP3 可选 128k、192k、320k
- 🏷 自动补标签：QQ音乐缓存文件常常没有标签，从「歌手-歌名」文件名回填
- ✅ 可选容器校验：OGG 逐页 CRC、FLAC STREAMINFO、MP3 帧头
- ⚡ 已转好的歌下次自动跳过；可并行转码
- 📋 实时显示每首歌的状态，失败给出原因和处理建议，附完整日志

## 系统要求

- macOS 14 (Sonoma) 或更新
- Apple 芯片（M1 及以后）。Intel Mac 需要自己在 Intel 机器上[从源码打包](#从源码构建)
- 新版 QQ音乐下载的 `musicex` 格式需要这台 Mac **登录过 QQ音乐**（不用开着，见下方说明）

## 第一次打开

App 没有经过 Apple 公证，第一次打开会提示「无法验证开发者」：

1. 打开「应用程序」，在 TuneFree 上**右键 → 打开**
2. 弹窗里再点一次「打开」

还是打不开：系统设置 → 隐私与安全性 → 往下翻，点「仍要打开」。只需要做一次。

## 常见问题

### 提示「取不到密钥」或「登录态过期」

新版 QQ音乐下载的歌，文件里**不带密钥**（列表里标着 `musicex`）。TuneFree 会读取本机 QQ音乐的登录状态，向 QQ音乐官方接口取这首歌的密钥。

打开 QQ音乐登录一次，再回到 TuneFree 点「再次转换」即可。别人转发给你的这类文件解不开，因为密钥绑定的是下载它的账号。

### 弹窗说 TuneFree 想访问「下载」「桌面」或「文稿」

点「允许」。拒绝过的话，到 系统设置 → 隐私与安全性 → 文件与文件夹 里重新打开。

### 有少数歌转不出来

点结果卡片里的「问题」查看原因，或用右上角按钮（⌘L）打开日志。常见原因：文件没下载完（0 字节）、文件损坏、不是音频（比如 `.mmp4` 视频）。

### 联网吗？会上传我的歌吗？

不上传任何歌曲。唯一的网络请求是给 `musicex` 格式的歌向 QQ音乐官方接口要密钥，其他格式完全离线处理。

## 从源码构建

只需要 Xcode 命令行工具（`xcode-select --install`）：

```bash
git clone https://github.com/Dora-z/TuneFree_Mac.git
cd TuneFree_Mac/macos
bash app/build.sh          # → dist/TuneFree.app 与 dist/TuneFree-<版本>-<架构>.dmg
```

只想用命令行：

```bash
cd macos
python3 main.py -i ~/Music/QQ音乐下载 -o ~/Music/导出 -b 320k
python3 main.py --selftest
```

命令行参数、`--json` 事件协议和 Python API 见 [macos/README.md](macos/README.md)；界面与打包细节见 [macos/app/README.md](macos/app/README.md)。

## 原理

不注入 QQ音乐进程，算法在本地复现：解析文件尾部拿到 ekey → TC-TEA 派生密钥 → QMC2 的 Map / RC4 密码把音频还原；老格式 QMC1 用固定异或表。解密约 400–480 MB/s，再交给 ffmpeg 转码。

## 项目结构

```
TuneFree_Mac/
├── macos/
│   ├── app/                 SwiftUI 图形界面 + 打包脚本（build.sh）
│   ├── tunefree_backend/    解密 / 转码后端（纯 Python 标准库）
│   ├── main.py              命令行入口
│   ├── ship/                命令行版发布包（无界面）
│   ├── tests/               单元 / 集成测试
│   ├── tools/               调试样本生成
│   └── examples/            后端接入示例
├── assets/                  README 用图
└── LICENSE
```

## 免责声明

本工具仅供**个人学习交流**使用，用于解密本机已合法下载的音乐文件，方便在自己拥有的设备上播放。

请勿用于传播、二次分发或商业用途。使用产生的一切法律责任由使用者自行承担。

## 许可与致谢

代码以 [MIT License](LICENSE) 开源。MIT 授权的是代码，不改变上面免责声明对使用场景的限制。

- 基于 [zksbx/TuneFree](https://github.com/zksbx/TuneFree)（Windows 版，作者 曾困睡不醒）
- [FFmpeg](https://ffmpeg.org/) — 音频转码
- [Unlock Music](https://github.com/unlock-music/unlock-music) — 加密格式的解析经验
- [PyInstaller](https://pyinstaller.org/) — 打包 Python 运行时
