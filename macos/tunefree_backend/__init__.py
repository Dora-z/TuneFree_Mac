# -*- coding: utf-8 -*-
"""TuneFree macOS 后端：把 QQ音乐下载的 .mflac / .mgg 解成本地可播放的音频。

与 Windows 原版最大的不同：**完全不依赖 QQ音乐客户端和 Frida**。
原版通过注入 QQ音乐进程、借它自己的解密函数来还原音频；这里直接在进程内
用纯 Python 复现 QMCv1 / QMCv2 的算法（ekey → TC-TEA → Map/RC4），
所以 macOS（以及任何 Python 3.9+ 平台）都能跑，且不需要 QQ音乐在运行。

典型调用：

    from tunefree_backend import Options, Job

    opts = Options(input_dir="~/Music/下载", output_root="~/Music/导出",
                   bitrate="320k", keep_flac=False)
    job = Job(opts, on_log=lambda lvl, msg: print(lvl, msg),
              on_progress=lambda p: print(p.phase, p.done, p.total))
    result = job.run()
    print(result.summary())
"""
from __future__ import annotations

from . import audio, decrypt, ekey, qmc1, qmc2, tea, verify
from .decrypt import (OUTPUT_EXT, SUPPORTED_EXTS, DecryptError, decrypt_file,
                      inspect_dir, probe)
from .job import FileError, Job, Options, Progress, Result, normalize_bitrate, run, scan_inputs
from .selftest import run_selftest

VERSION = "2.1.3-mac.2"

__all__ = [
    "VERSION",
    "Options",
    "Job",
    "Result",
    "Progress",
    "FileError",
    "run",
    "run_selftest",
    "scan_inputs",
    "normalize_bitrate",
    "decrypt_file",
    "probe",
    "inspect_dir",
    "DecryptError",
    "OUTPUT_EXT",
    "SUPPORTED_EXTS",
    "audio",
    "decrypt",
    "qmc1",
    "qmc2",
    "tea",
    "verify",
    "ekey",
]
