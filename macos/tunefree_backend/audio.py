# -*- coding: utf-8 -*-
"""ffmpeg 查找与转码。

macOS 上 ffmpeg 通常来自 Homebrew（Apple Silicon 在 /opt/homebrew/bin，
Intel 在 /usr/local/bin），也可能被 App 打包进 Resources。
查找顺序：环境变量 → 程序目录 → PATH → Homebrew 目录 → imageio-ffmpeg 自带的静态版。
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

# 打包成窗口程序后，Windows 上给子进程加 CREATE_NO_WINDOW，避免黑框闪一下
_NO_WINDOW = 0x08000000 if os.name == "nt" else 0

_EXE = "ffmpeg.exe" if os.name == "nt" else "ffmpeg"

_EXTRA_DIRS = [
    "/opt/homebrew/bin",      # Apple Silicon Homebrew
    "/usr/local/bin",         # Intel Homebrew
    "/usr/bin",
    "/opt/local/bin",         # MacPorts
]


class FFmpegMissing(Exception):
    pass


def app_dir():
    """程序所在目录（源码运行 = 本文件的上两级；打包后 = 可执行文件目录）。"""
    if getattr(sys, "frozen", False):  # PyInstaller
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent.parent


def find_ffmpeg():
    """返回 ffmpeg 可执行文件路径；找不到返回 None。"""
    env = os.environ.get("TUNEFREE_FFMPEG")
    if env and os.path.isfile(env) and os.access(env, os.X_OK):
        return env

    base = app_dir()
    candidates = [
        base / _EXE,
        base / "bin" / _EXE,
        base / "Resources" / _EXE,          # macOS .app 内的布局
        Path(getattr(sys, "_MEIPASS", base)) / _EXE,
    ]
    for path in candidates:
        if path.is_file() and os.access(str(path), os.X_OK):
            return str(path)

    found = shutil.which("ffmpeg")
    if found:
        return found

    for folder in _EXTRA_DIRS:
        path = Path(folder) / _EXE
        if path.is_file() and os.access(str(path), os.X_OK):
            return str(path)

    try:  # 可选依赖：pip install imageio-ffmpeg 会带一个静态版 ffmpeg
        import imageio_ffmpeg  # type: ignore

        return imageio_ffmpeg.get_ffmpeg_exe()
    except Exception:
        return None


def require_ffmpeg():
    path = find_ffmpeg()
    if not path:
        raise FFmpegMissing(
            "没找到 ffmpeg。macOS 上装一个即可：brew install ffmpeg；"
            "或者把 ffmpeg 放到本程序同级目录，或设置环境变量 TUNEFREE_FFMPEG 指向它。"
        )
    return path


def _run(cmd, capture_stdout=False):
    return subprocess.run(
        cmd,
        check=True,
        capture_output=True,
        text=not capture_stdout,
        encoding=None if capture_stdout else "utf-8",
        errors=None if capture_stdout else "ignore",
        creationflags=_NO_WINDOW,
        stdin=subprocess.DEVNULL,
    )


def _base_cmd(ffmpeg_path):
    return [ffmpeg_path, "-hide_banner", "-nostdin", "-v", "error", "-y"]


def _mp3_args(bitrate, keep_cover=True, metadata=None):
    args = ["-map", "0:a:0"]
    if keep_cover:
        args += ["-map", "0:v?", "-c:v", "copy"]
    args += [
        "-c:a", "libmp3lame",
        "-b:a", bitrate,
        "-map_metadata", "0",
        "-id3v2_version", "3",
        "-write_id3v1", "1",
    ]
    for key, value in (metadata or {}).items():
        if value:
            args += ["-metadata", "%s=%s" % (key, value)]
    return args


def explain_returncode(code):
    """把 ffmpeg / 系统的返回码翻成人话。"""
    if code in (-13, 4294967283):
        return "权限不足（输出文件不可写，或同名 .mp3 正被别的程序占用）"
    if code in (-2, 4294967294):
        return "找不到输入文件"
    if code in (-1, 4294967295):
        return "ffmpeg 内部错误，通常是输入文件损坏或没有解密完整"
    if code in (-32, 4294967264):
        return "文件正被其他进程占用"
    if code == 1:
        return "ffmpeg 处理失败（输入不是有效音频，或输出路径不可写）"
    if code > 2147483647:
        return "系统层错误(0x%08X)" % code
    return "未知错误"


def transcode_to_mp3(src, dst, ffmpeg_path, bitrate="192k", metadata=None):
    """转码成 MP3，返回 (ok, 错误说明)。

    顺序：直接写目标文件 → 让 ffmpeg 写到 stdout 由 Python 落盘 → 写临时目录再搬。
    后两条在 macOS 上很少用到，但沙盒 / 只读挂载 / 网盘目录里会救命。
    """
    src = str(src)
    dst = str(dst)

    def _try_direct(keep_cover):
        cmd = _base_cmd(ffmpeg_path) + ["-i", src] + _mp3_args(bitrate, keep_cover, metadata) + [dst]
        _run(cmd)

    try:
        _try_direct(True)
        return True, ""
    except FileNotFoundError:
        return False, "ffmpeg 不可执行：%s" % ffmpeg_path
    except subprocess.CalledProcessError as exc:
        code = exc.returncode
        # 封面复制失败（罕见编码）就退一步：只要音频
        stderr = exc.stderr if isinstance(exc.stderr, str) else (exc.stderr or b"").decode("utf-8", "ignore")
        if code == 1 and "map" in stderr.lower():
            try:
                _try_direct(False)
                return True, ""
            except subprocess.CalledProcessError as exc2:
                exc = exc2
                code = exc2.returncode
                stderr = exc2.stderr if isinstance(exc2.stderr, str) else ""

        detail = [line.strip() for line in stderr.splitlines() if line.strip()]

        if code in (-13, 4294967283, -5, 4294967291):
            # 目标不可写：走管道
            try:
                cmd = _base_cmd(ffmpeg_path) + ["-i", src] + _mp3_args(bitrate, True, metadata) + ["-f", "mp3", "pipe:1"]
                proc = _run(cmd, capture_stdout=True)
                data = proc.stdout or b""
                if len(data) < 2048:
                    raise RuntimeError("ffmpeg 只输出了 %d 字节" % len(data))
                Path(dst).write_bytes(data)
                return True, ""
            except Exception:
                pass
            # 再退一步：临时目录中转
            tmp = Path(tempfile.gettempdir()) / ("tf_%d_%s.mp3" % (os.getpid(), Path(dst).stem))
            try:
                _run(_base_cmd(ffmpeg_path) + ["-i", src] + _mp3_args(bitrate, True, metadata) + [str(tmp)])
                shutil.move(str(tmp), dst)
                return True, ""
            except Exception as exc3:
                msg = "返回码 %s（%s）" % (code, explain_returncode(code))
                if detail:
                    msg += "；ffmpeg: " + detail[-1]
                return False, msg + "；%s" % exc3
            finally:
                try:
                    if tmp.exists():
                        tmp.unlink()
                except OSError:
                    pass

        msg = "返回码 %s（%s）" % (code, explain_returncode(code))
        if detail:
            msg += "；ffmpeg: " + " | ".join(detail[-2:])
        return False, msg
    except OSError as exc:
        return False, "无法运行 ffmpeg：%s" % exc


def find_ffprobe(ffmpeg_path=None):
    """找 ffprobe：优先ffmpeg同目录，其次 PATH / Homebrew。"""
    candidates = []
    if ffmpeg_path:
        folder = Path(ffmpeg_path).parent
        candidates += [folder / ("ffprobe.exe" if os.name == "nt" else "ffprobe")]
    found = shutil.which("ffprobe")
    if found:
        candidates.append(Path(found))
    for folder in _EXTRA_DIRS:
        candidates.append(Path(folder) / ("ffprobe.exe" if os.name == "nt" else "ffprobe"))
    for path in candidates:
        if path.is_file() and os.access(str(path), os.X_OK):
            return str(path)
    return None


def read_tags(path, ffmpeg_path=None):
    """读音频容器的现有标签，返回小写键的字典（读不到就是空）。"""
    tool = find_ffprobe(ffmpeg_path)
    if tool is None:
        return {}
    try:
        proc = subprocess.run(
            [tool, "-v", "error", "-show_entries", "format_tags", "-of",
             "default=noprint_wrappers=1", str(path)],
            capture_output=True, text=True, encoding="utf-8", errors="ignore",
            creationflags=_NO_WINDOW, stdin=subprocess.DEVNULL,
        )
    except OSError:
        return {}
    tags = {}
    for line in proc.stdout.splitlines():
        key, _, value = line.partition("=")
        key = key.strip().lower()
        if key.startswith("tag:"):
            key = key[4:]
        if key and value.strip():
            tags[key] = value.strip()
    # ffmpeg 对不同容器的命名不统一，统一到 mp3 常用的几个
    alias = {"album_artist": "albumartist", "albumartist": "albumartist",
             "tracknumber": "track", "date": "date", "year": "date"}
    for src, dst in alias.items():
        if src in tags and dst not in tags:
            tags[dst] = tags[src]
    return tags


_SEP_CANDIDATES = (" - ", "-", "–", "－")


def parse_filename_tags(stem):
    """从「歌手-歌名」的文件名里拆出 artist / title（QQ音乐缓存的文件名就是这形状）。"""
    stem = os.path.splitext(os.path.basename(stem))[0].strip()
    if not stem:
        return {}
    for sep in _SEP_CANDIDATES:
        index = stem.find(sep)
        if index <= 0:
            continue
        artist = stem[:index].strip()
        title = stem[index + len(sep):].strip()
        if artist and title:
            return {"artist": artist, "title": title}
    return {"title": stem}


def merge_tags(existing, stem):
    """用文件名补齐缺失的 title / artist；已有的不动。

    歌手一栏特例：文件里只有「张震岳」，文件名是「张震岳,蔡健雅」时，用文件名的（信息更全）。
    """
    from_name = parse_filename_tags(stem)
    merged = dict(existing or {})
    for key in ("title", "artist"):
        current = merged.get(key, "").strip()
        wanted = from_name.get(key, "").strip()
        if not wanted:
            continue
        if not current:
            merged[key] = wanted
        elif key == "artist" and current and current in wanted and current != wanted:
            merged[key] = wanted
    return merged


def probe_audio(path, ffmpeg_dir=None):
    """用 ffprobe（如果能找到）读时长/采样率，给界面显示用。失败返回 None。"""
    tool = None
    if ffmpeg_dir:
        cand = Path(ffmpeg_dir) / ("ffprobe.exe" if os.name == "nt" else "ffprobe")
        if cand.is_file():
            tool = str(cand)
    if tool is None:
        tool = shutil.which("ffprobe")
    if tool is None:
        for folder in _EXTRA_DIRS:
            cand = Path(folder) / "ffprobe"
            if cand.is_file():
                tool = str(cand)
                break
    if tool is None:
        return None
    try:
        proc = subprocess.run(
            [tool, "-v", "error", "-show_entries",
             "format=duration,format_name:stream=sample_rate,channels,codec_name",
             "-of", "default=noprint_wrappers=1", str(path)],
            capture_output=True, text=True, encoding="utf-8", errors="ignore",
            creationflags=_NO_WINDOW, stdin=subprocess.DEVNULL,
        )
    except OSError:
        return None
    if proc.returncode != 0:
        return None
    info = {}
    for line in proc.stdout.splitlines():
        key, _, value = line.partition("=")
        if key and value:
            info[key.strip()] = value.strip()
    try:
        info["duration"] = float(info.get("duration", "0"))
    except ValueError:
        info["duration"] = 0.0
    return info
