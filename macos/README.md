# TuneFree 后端（tunefree_backend）

把 QQ音乐下载的加密歌曲（`.mflac` / `.mgg` 等）还原成 `FLAC` / `OGG`，再转成 `MP3`。
这里是**后端**：命令行 + Python API。图形界面在 [`app/`](app/README.md)，它通过 `--json` 事件流驱动这个后端。

## 原理

**算法在进程内复现**，不注入 QQ音乐、也不需要它在运行：解析文件尾部拿到 ekey，
用 TC-TEA 派生密钥，再用 QMC2 的 Map / RC4 密码把音频异或回来；老格式 QMC1 用固定异或表。

- 纯 Python 标准库，零第三方依赖（Python 3.9+）
- 解密约 **400–480 MB/s**，瓶颈在 ffmpeg 转码
- 只有 `musicex` 布局的文件需要联网：用本机 QQ音乐登录态向官方接口取这首歌的 ekey（见下文）

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
| `--no-online-tags` | 不联网补全标签（默认按歌曲 ID 查封面、专辑、年份、歌词） |
| `--lrc` | 另存一份 `.lrc` 同步歌词（与 MP3 同名） |
| `--verify` | 每个产物做容器校验（OGG 逐页 CRC / FLAC STREAMINFO / MP3 帧头） |
| `--json` | 事件以 JSON 行输出，给新前端解析 |
| `--info` | 只探查尾部结构（QTag / V1 / musicex / qmc1），不解密 |
| `--selftest` | 内置自检 |
| `-v, --version` | 版本号 |

退出码：`0` 正常，`1` 没有产出（目录里没文件 / 全部失败），`130` 被中断。

## 前端怎么接

### 方式 A：子进程 + 进度协议

一行一个事件：

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
{"event":"decrypt-fail","input":"/in/b.mgg","reason":"ekey","message":"..."}
{"event":"tags","input":"/out/flac/a.flac","online":true,"title":"...","artist":"甲/乙","album":"...","year":"2007","cover":"~/Library/Caches/TuneFree/covers/xxx.jpg","lyrics":true}
{"event":"result","result":{"files_found":10,"decrypted":9,"decrypt_failed":1,"mp3_ok":9,...}}
```

另有 `decrypt-skip` / `transcode-skip` / `transcode-fail`；`--info --json` 输出 `info` 事件。

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

## 标签

QQ音乐的缓存文件经常不带标签（`.mgg` 里常常一个都没有），或者只有部分（只写第一个歌手、没有封面）。
转码时每首歌按下面的优先级算出最终标签，**显式写入**（不整体拷源标签，OGG 里的 QQ音乐私有字段不会带出来）：

1. **联网结果**（`meta.py`）：文件尾部有 song_id（QTag / musicex）就直接查歌曲详情；没有（V1 / QMC1）
   就用「歌手 + 歌名」搜一次。查到的结果**歌名、歌手、时长都要和文件对得上**才用（时长差 6 秒以内），
   对不上就当没查到 —— 宁可少补也不写错。连续 3 次连不上就停用，本批剩下的歌直接用本地标签。
2. **源文件标签**（`tags.py` 直接解析 FLAC / OGG 的 Vorbis comment，不依赖 ffprobe）。
3. **文件名**：缺的 `title` / `artist` 从 `歌手-歌名` 补；文件名里歌手更全时用文件名的。

写入内容：歌名、歌手（多位用 `/` 分隔）、专辑、专辑艺人、年份、曲序、碟号、流派、唱片公司；
专辑封面（800×800 JPEG，缓存在 `~/Library/Caches/TuneFree/covers/`）；歌词 ——
MP3 写标准 `USLT` 帧（纯文本，`id3.py`；ffmpeg 自己写的是播放器不认的 `TXXX`），
保留的 FLAC 写 `LYRICS`（带时间戳的 LRC）并同样嵌封面；加 `--lrc` 另存一份 `.lrc`。

`--no-online-tags` 只用本地标签，`--no-tags` 再关掉文件名回填。

## 打包发布

推荐发图形界面版：`bash app/build.sh` → `dist/<架构>/TuneFree.app` + 每种芯片一个 DMG，内置 Python 运行时和 ffmpeg，
详见 [app/README.md](app/README.md)。

不要界面的话，`bash ship/build_app.sh` 会打一个命令行版 zip（双击 `TuneFree.command`，
用系统对话框选目录）。

两种包都需要注意：

1. **架构**：`app/build.sh` 默认同时打 arm64 和 x86_64（Intel 版在 Apple 芯片上借助 Rosetta 交叉打包）；
   `ship/build_app.sh` 的命令行版只打构建机自己的架构。
2. **签名**：没有开发者证书时是 ad-hoc 签名，首次打开要右键 → 打开。
3. **账号绑定**：`musicex` 文件的密钥绑定下载它的那个账号，别人转发的这类文件解不开；
   `QTag` / `V1` / QMC1 的文件不受影响。

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

## 注意事项

- **不检查音质档位**：文件里是什么就解什么，解出来不是音频会明确报错（`bad-output`）。
- 输出目录默认是 `<输入目录>/output`。
- 文件名按原样保留，不做 NFC/NFD 归一化；不同子目录里的同名歌曲会自动加序号。
- `.mmp4` 等视频/其他容器的加密文件不支持，会被当成不认识的文件跳过。

## 首次运行可能遇到的系统提示

- 从「下载目录 / 桌面 / 文稿」读文件时，macOS 会弹「想访问…」，允许即可；外置磁盘同理。
  拒绝过就得到 `系统设置 → 隐私与安全性 → 文件与文件夹` 里重新打开。
- `brew install ffmpeg` 之后如果 `which ffmpeg` 有输出但程序找不到，用 `--ffmpeg /opt/homebrew/bin/ffmpeg`
  或设 `TUNEFREE_FFMPEG` 环境变量。

## 目录结构

```
macos/
├── main.py                      命令行入口
├── tunefree_backend/
│   ├── tea.py                   TC-TEA（腾讯版 TEA）
│   ├── qmc2.py                  ekey 派生 + Map/RC4 密码 + 尾部识别
│   ├── qmc1.py                  QMC1 固定异或表
│   ├── decrypt.py               文件级解密、原子落盘、扩展名映射
│   ├── ekey.py                  musicex 取密钥：读本机登录态 + 调 GetEVkey
│   ├── audio.py                 ffmpeg 查找、转码（三重回退）、写标签 / 封面
│   ├── tags.py                  直接解析 FLAC / OGG 的标签与时长
│   ├── meta.py                  联网补全标签：歌曲详情、搜索、封面、歌词，结果校验
│   ├── id3.py                   给 MP3 写标准 USLT 歌词帧
│   ├── job.py                   扫描 → 解密 → 转码的编排，进度/取消/并发
│   ├── verify.py                OGG/FLAC/MP3 容器校验
│   └── selftest.py              向量 + 端到端自检
├── app/                         SwiftUI 图形界面 + 打包脚本
├── ship/                        命令行版发布包（TuneFree.command）
├── tools/make_samples.py        造调试样本（真音频 + 真加密）
├── examples/frontend_usage.py   前端接入示例
└── tests/                       单元 / 集成测试
```

跑测试：

```bash
python3 -m unittest discover -s tests -v
```

## 许可

MIT，见仓库根目录 `LICENSE`。只处理本机已合法下载的文件，供自己在自有设备上播放。
