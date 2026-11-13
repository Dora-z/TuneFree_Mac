# TuneFree macOS 后端

把 QQ音乐下载的加密歌曲（`.mflac` / `.mgg`）还原成 `FLAC` / `OGG`，再转成 `MP3`。
**这是纯后端**：没有界面，只提供命令行和 Python API，前端随便用 Qt / SwiftUI / Tauri / 网页壳子接。

## 和 Windows 原版最大的区别

原版（`../main.py` + `hook_qq_music.js`）走的是 Frida 注入：把 JS 注入 `QQMusic.exe`，
借它自己导出的 `EncAndDesMediaFile::Read` 来解密，所以必须有 Windows 版 QQ音乐在运行。
QQ音乐没有 macOS 版能对得上的注入目标，这条路在 Mac 上走不通。

这里的做法是**把算法搬进进程内**：自己解析文件尾部拿到 ekey，用 TC-TEA 派生密钥，
再用 QMC2 的 Map / RC4 密码把音频异或回来。结果是：

| | Windows 原版 | 本后端 |
|---|---|---|
| QQ音乐客户端 | 必须运行并登录 | **不需要** |
| Frida 注入 | 必须 | **不需要** |
| 网络 | 只在检查更新时 | **完全不联网** |
| 平台 | 仅 Windows | macOS（以及任何 Python 3.9+ 平台） |
| 速度 | 依赖进程内调用 | 解密约 **400–480 MB/s** |
| 杀软告警 | 会被当成注入行为 | 无注入行为 |

## 图形界面

`app/` 里是原生 SwiftUI 界面，`bash app/build.sh` 打出自带 Python 和 ffmpeg 的
`dist/TuneFree.app` 与 DMG，用户双击即用。详见 [app/README.md](app/README.md)。

## 快速开始

```bash
brew install ffmpeg                     # 转 MP3 需要；只解 FLAC 可以不装

cd macos
python3 main.py --selftest              # 自检：算法向量 + 端到端 + ffmpeg
python3 main.py -i ~/Music/下载 -o ~/Music/导出 -b 320k
```

没有真实样本也能先跑通全流程：

```bash
python3 tools/make_samples.py --out /tmp/tf-samples --count 2
python3 main.py -i /tmp/tf-samples -o /tmp/tf-samples/_out --verify
```

## 命令行

参数与 Windows 版一致，原有前端可以照旧 spawn 这个进程、照旧解析 `@@PROGRESS`。

| 参数 | 说明 |
|---|---|
| `-i, --input` | 输入目录（递归子目录），默认当前目录 |
| `-o, --output` | 输出根目录，其下自建 `flac/` 与 `mp3/`；默认 `<输入目录>/output` |
| `--flac-dir` / `--mp3-dir` | 分别指定输出目录 |
| `-b, --bitrate` | MP3 比特率，默认 `192k`，上限 `320k` |
| `--keep-flac` | 转完 MP3 后保留解密出的 FLAC/OGG |
| `--no-mp3` | 只要 FLAC（OGG 仍会转成 MP3，因为 OGG 一般不是最终形态） |
| `--force` | 已存在的输出也重做 |
| `-j, --jobs` | 转码并发数，默认 1 |
| `--ekey` | 手动给 ekey（base64），覆盖自动获取 |
| `--authst` / `--uin` | 手动指定 QQ音乐登录凭据（默认读本机登录态） |
| `--no-ekey-fetch` | 不自动调 GetEVkey（只用文件内密钥或 `--ekey`） |
| `--ffmpeg` | 手动指定 ffmpeg 路径 |
| `--no-tags` | 不从文件名回填标签（默认会补全缺失的歌名/歌手） |
| `--verify` | 每个产物做容器校验（OGG 逐页 CRC / FLAC STREAMINFO / MP3 帧头） |
| `--json` | 事件以 JSON 行输出，给新前端解析 |
| `--info` | 只探查尾部结构（QTag / V1 / musicex / qmc1），不解密 |
| `--selftest` | 内置自检 |
| `-v, --version` | 版本号 |

退出码：`0` 正常，`1` 没有产出（目录里没文件 / 全部失败），`130` 被中断。

## 前端怎么接

### 方式 A：子进程 + 进度协议（改动最小）

沿用原版协议，一行一个事件：

```
@@PROGRESS 解密 3/10
@@PROGRESS 转码 1/7
```

日志走 stderr（`HH:MM:SS INFO ...`），进度走 stdout。
想结构化就加 `--json`，得到：

```json
{"event":"log","level":"info","message":"..."}
{"event":"progress","phase":"解密","done":3,"total":10,"percent":30.0,"file":"song.mflac"}
{"event":"decrypt-ok","input":"/in/a.mflac","output":"/out/flac/a.flac","info":{...}}
{"event":"transcode-ok","input":"/out/flac/a.flac","output":"/out/mp3/a.mp3"}
{"event":"decrypt-fail","input":"/in/b.mgg","reason":"ekey","message":"..."}   // 另有 transcode-fail
{"event":"result","result":{"files_found":10,"decrypted":9,"decrypt_failed":1,"mp3_ok":9,...}}
```

### 方式 B：进程内调用（推荐，能拿到结构化结果 + 可取消）

```python
from tunefree_backend import Options, Job

opts = Options(input_dir="~/Music/下载", output_root="~/Music/导出",
               bitrate="320k", keep_flac=False, jobs=2)

job = Job(
    opts,
    on_log=lambda level, msg: print(level, msg),      # level: info/warning/error
    on_progress=lambda p: bar.setValue(int(p.percent)),  # p.phase / p.done / p.total / p.current_file
    on_file=lambda ev: table.append(ev),                # 单文件事件，字段同 --json
)
result = job.run()                                     # 阻塞；放到工作线程里跑
# result.ok / result.decrypted / result.decrypt_failed / result.errors / result.to_dict()

job.cancel()      # 从别的线程调用即可中断（当前文件会跑完）
```

回调在工作线程里执行，界面上记得用信号槽 / `QMetaObject.invokeMethod` 切回主线程。
完整示例见 `examples/frontend_usage.py`。

想在做之前先列出「有哪些歌」给界面填表格：

```python
from tunefree_backend import inspect_dir

for row in inspect_dir("/Users/me/Music/下载"):
    print(row["relpath"], row["kind"], row["format"], row["size"])
    # kind: qtag / v1 / musicex / qmc1；format: flac / ogg / mp3
```

## 数据结构

`Options`：`input_dir`、`output_root`、`flac_dir`、`mp3_dir`、`bitrate`、`keep_flac`、
`no_mp3`、`force`、`jobs`、`ekey`、`auto_ekey`、`authst`、`uin`、`tag_from_filename`、
`verify_output`、`ffmpeg_path`。

`Result`：`files_found`、`decrypted`、`decrypt_failed`、`decrypt_skipped`、
`mp3_ok`、`mp3_failed`、`mp3_skipped`、`cancelled`、`errors[]`、`elapsed`、`ok`、
`summary()`、`to_dict()`。

`FileError`：`path`、`stage`（`decrypt` / `transcode` / `verify`）、`reason`、`message`。

`reason` 取值（界面可以据此给不同提示）：

| reason | 含义 | 建议文案 |
|---|---|---|
| `unsupported` | 扩展名不认识 | 跳过这个文件 |
| `empty` | 文件 0 字节 | 可能还没下载完 |
| `io` | 读不了 | 看权限 / 外置磁盘是否挂载 |
| `too-large` | 超过 512 MB | — |
| `ekey` | musicex 取不到密钥（未登录 / 过期 / 接口拒绝） | 按 message 提示，或改用手动 `--ekey` |
| `qmc2` | 尾部结构不对 / 密钥不对 | 按 message 提示 |
| `bad-output` | 解出来的头部不是音频 | 密钥不匹配或文件损坏 |
| `write` | 写盘失败 | 输出目录不可写 |
| `ffmpeg` | 转码失败 | message 里有 ffmpeg 原话 |
| `bad-container` / `bad-mp3` | `--verify` 没过 | 容器损坏 |

## 支持的文件

| 尾部布局 | 有没有 ekey | 说明 |
|---|---|---|
| `QTag` | 有（文件内） | 新客户端下载的主流格式，直接解 |
| `V1` | 有（裸 key） | 老版本，直接解 |
| `musicex` | **没有** | 新版客户端下载的主流格式；密钥用本机登录态自动获取（见下） |
| QMC1（`.qmcflac` / `.qmcogg` / `.qmc0` / `.qmc3`） | 不需要 | 固定异或表 |

### musicex：密钥怎么来

`musicex` 的文件尾部只有 `song_id` / `media_mid` / 资源名，**密钥不在文件里**，
由服务端按「账号 + 这首歌」临时下发（接口 `music.vkey.GetEVkey`）。本后端会自动处理：

1. 读本机 QQ音乐的登录态 —— `~/Library/Preferences/com.tencent.QQMusicMac.plist`
   里的 `AutoLoginUserInfo`（一个 NSKeyedArchiver 编码的 plist，内含 `strAuthst` 和 UIN）。
   只读文件，不注入进程、不抓包。
2. 用这两个值调 `https://u.y.qq.com/cgi-bin/musicu.fcg`
   （`module=music.vkey.GetEVkey`、`method=CgiGetEVkey`，带 `media_mid` 与含扩展名的资源名），
   拿回这首歌的 ekey。
3. ekey 只在内存里用于当前这批文件，不写盘。

前置条件：QQ音乐在这台机器上登录过（下载这些文件的那次登录）。凭据过期时会明确报
「登录态过期」，重开一次 QQ音乐即可刷新；也可以手动顶：

```bash
python3 main.py -i ~/iQmc -o ~/out --authst "Q_H_L_..." --uin 123456789
python3 main.py -i ~/iQmc -o ~/out --ekey "<base64>"      # 单个文件直接给密钥
python3 main.py -i ~/iQmc -o ~/out --no-ekey-fetch        # 完全不联网
```

拿到的 ekey 长度决定走哪条密码：≤300 字节走 Map，>300 字节走 RC4。
缺密钥/取不到时会明确报 `ekey` 类错误，不会写出坏文件。

## 自检与校验

```bash
python3 main.py --selftest
```

跑的是**外部参考实现的公开测试向量**，不是自己跟自己比：

- TC-TEA：官方 ekey 向量（必须派生出 `This is a test key for test purpose :D`）
- QMC2 Map：偏移 0 与 `0x7FFF` 边界两组向量
- QMC2 RC4：首段向量 + hash base 向量
- QMC1：掩码流头部推导
- 端到端：QTag（EncV1）、QTag（EncV2 + RC4 长 key）、V1 三种布局各一条闭环
- ffmpeg 是否可用

`--verify` 会额外做容器级校验：OGG 逐页 CRC（能发现「只错一个字节」这种问题）、
FLAC STREAMINFO、MP3 帧头。

## 标签回填

QQ音乐的缓存文件经常不带标签（`.mgg` 里常常一个标签都没有），转出来的 MP3 在播放器里
就是「未知歌手 / 未知标题」。所以转码时会做一次合并：

- 先读源文件已有的标签（ffprobe）；
- 缺失的 `title` / `artist` 从文件名补 —— QQ音乐的缓存名就是 `歌手-歌名`；
- 歌手一栏如果文件名信息更全（源文件只写了「张震岳」，文件名是「张震岳,蔡健雅」），用文件名的。

不想要就在命令行加 `--no-tags`。

## 发给别人用

### 打一个发布包

```bash
bash ship/build_app.sh
# → dist/TuneFree-<版本>-<架构>.zip   （约 24 MB）
```

包里自带 **Python 运行时 + ffmpeg + 双击启动器 + 使用者说明**，对方什么都不用装。
体积构成：ffmpeg 47 MB（压缩后约一半）+ Python 运行时 8 MB + 程序本体 1.3 MB。

### 对方要做的四步

1. 解压 zip
2. 在 `TuneFree.command` 上**右键 → 打开**（首次一次，之后双击就行。因为包没做签名/公证）
3. 依次点四个对话框：选输入文件夹（默认已指到 QQ音乐缓存目录）→ 选输出文件夹 →
   选音质 → 要不要保留无损
4. 等进度跑完，自动弹出输出文件夹，里面的 `mp3/` 就是成品

对方**不需要**：Python、pip、ffmpeg、Homebrew、终端命令。
对方**需要**：QQ音乐在这台 Mac 上登录过（`musicex` 文件的密钥按账号现取，见上一节）。

### 三个必须提前知道的点

1. **架构**：在 arm64 Mac 上打出来的包只给 arm64 用（Intel 机器跑 `bash ship/build_app.sh`
   或用 `ARCH=x86_64` 配 x86_64 的 Python 重打一次）。架构不对时启动器会直接说人话，不会哑掉。
2. **签名**：没有开发者证书，所以首次打开会被 Gatekeeper 拦一次，右键 → 打开即可；
   启动器自己会清掉解压带来的隔离标记。
3. **账号绑定**：别人转发给你的 `musicex` 文件（新版客户端下载的）解不开，因为密钥绑的是
   下载它的那个账号 —— 只有 `QTag` / `V1` 布局的老文件能跨账号。

## 实测（真实文件）

两个从 QQ音乐 macOS 客户端缓存的真实文件（`iQmc/`）：

| 文件 | 布局 | 结果 |
|---|---|---|
| `许茹芸-泪海.mgg` (3.4 MB) | musicex，自动取 ekey，RC4 | 793 页 Ogg **逐页 CRC 全对**，44.1 kHz 立体声 Vorbis，298.00 s |
| `张震岳,蔡健雅-思念是一种病.mflac` (29 MB) | musicex，自动取 ekey，RC4 | 解出 PCM 的 **MD5 与 FLAC STREAMINFO 里的校验值一致**，44.1 kHz / 16 bit / 255.72 s |

FLAC 那条是最硬的证据：STREAMINFO 里存着整段 PCM 的 MD5，解完再算一次完全相等，
说明每一个采样都对得上，不是「听起来没问题」而已。

## 性能

解密走 `int` 大整数异或 + 预计算掩码表，实测 40 MB 文件 **0.08 s（约 480 MB/s）**，
CPU 占用单核。瓶颈在 ffmpeg 转码，用 `-j 4` 可以并行。

## 复用上游界面（`TuneFree.py`）要改的三处

如果你打算把上游那套 PySide6 界面搬到 Mac，只需要动后端相关的部分：

1. **后端的路径**：上游 `TuneFree.py` 会找同目录的 `main.exe`，找不到再退回
   `python main.py`。把 `self.dev_script` 指向本目录的 `main.py` 即可，参数不用改。
2. **ffmpeg 的存在性检查**：上游检查的是 `ffmpeg.exe`，Mac 上要换成
   `tunefree_backend.audio.find_ffmpeg()`（Homebrew 路径、PATH、App 内 Resources 都会找）。
3. **提示文案**：上游有「请确保 QQ音乐客户端正在运行」这类文案，本后端不需要客户端，
   这类文案可以整段删掉；`@@PROGRESS` 和日志格式不用改。

界面的其余部分（进度条、目录选择、日志框、退出码处理）可以原样保留。

## 与 Windows 版的行为差异

1. **不检查 QQ音乐音质档位**。原版要求「标准 / HQ / SQ」，因为高音质走的是另一条流；
   离线解密只看文件本身，文件里是什么就解什么，解出来不是音频会明确报错。
2. **不联网**。没有更新检查、没有任何外部请求。
3. **不需要 QQ音乐在跑**，所以也不存在「先把 QQ音乐打开再点开始」这一步。
   例外是 `musicex` 布局的文件：它要读本机登录态去取密钥，需要这台机器上登录过
   QQ音乐（不用开着）。
4. 输出目录默认是 `<输入目录>/output`（原版是 `<当前目录>/output`）；显式传 `-o` 时两者一致。
5. 文件名按原样保留，不做 NFC/NFD 归一化。
6. `.mmp4` 等 QQ音乐「视频/其他容器」的加密文件不支持（上游也不支持），会被当成不认识的文件跳过。

## 首次运行可能遇到的系统提示

- 从「下载目录 / 桌面 / 文稿」读文件时，macOS 会弹「想访问…」，允许即可；外置磁盘同理。
  拒绝过就得到 `系统设置 → 隐私与安全性 → 文件与文件夹` 里重新打开。
- `brew install ffmpeg` 之后如果 `which ffmpeg` 有输出但程序找不到，用 `--ffmpeg /opt/homebrew/bin/ffmpeg`
  或设 `TUNEFREE_FFMPEG` 环境变量。

## 目录结构

```
macos/
├── main.py                      命令行入口（参数与 Windows 版一致）
├── tunefree_backend/
│   ├── tea.py                   TC-TEA（腾讯版 TEA）
│   ├── qmc2.py                  ekey 派生 + Map/RC4 密码 + 尾部识别
│   ├── qmc1.py                  QMC1 固定异或表
│   ├── decrypt.py               文件级解密、原子落盘、扩展名映射
│   ├── ekey.py                  musicex 取密钥：读本机登录态 + 调 GetEVkey
│   ├── audio.py                 ffmpeg/ffprobe 查找、转码（三重回退）、标签回填
│   ├── job.py                   扫描 → 解密 → 转码的编排，进度/取消/并发
│   ├── verify.py                OGG/FLAC/MP3 容器校验
│   └── selftest.py              向量 + 端到端自检
├── tools/make_samples.py        造调试样本（真音频 + 真加密）
├── examples/frontend_usage.py   前端接入示例
└── tests/                       42 个单元 / 集成测试
```

跑测试：

```bash
python3 -m unittest discover -s tests -v
```

## 许可

与仓库根目录一致，MIT。同样遵守根目录 `README.md` 里的免责声明：
只处理本机已合法下载的文件，供自己在自有设备上播放。
