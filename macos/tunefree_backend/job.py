# -*- coding: utf-8 -*-
"""任务编排：扫描 → 解密 → 转码。前端只需要调这里。

最小用法：

    from tunefree_backend import Options, Job

    opts = Options(input_dir="~/Music/下载", output_root="~/Music/导出", bitrate="320k")
    job = Job(opts, on_log=print, on_progress=lambda p: ...)
    result = job.run()          # 阻塞；在后台线程里跑就行
    job.cancel()                # 想中断时从别的线程调

进度回调参数是 ``Progress(phase, done, total, current_file)``，
phase 取值 ``"解密"`` / ``"转码"``，与命令行输出的 ``@@PROGRESS`` 一一对应。
"""
from __future__ import annotations

import os
import threading
import time
from concurrent.futures import ThreadPoolExecutor

from . import audio, decrypt, verify


class Progress(object):
    __slots__ = ("phase", "done", "total", "current_file")

    def __init__(self, phase, done, total, current_file=""):
        self.phase = phase
        self.done = done
        self.total = total
        self.current_file = current_file

    @property
    def percent(self):
        if not self.total:
            return 0.0
        return min(100.0, 100.0 * self.done / self.total)

    def __repr__(self):
        return "Progress(%s %d/%d %s)" % (self.phase, self.done, self.total, self.current_file)


class FileError(object):
    __slots__ = ("path", "stage", "reason", "message")

    def __init__(self, path, stage, reason, message):
        self.path = path
        self.stage = stage
        self.reason = reason
        self.message = message

    def to_dict(self):
        return {"path": self.path, "stage": self.stage,
                "reason": self.reason, "message": self.message}

    def __repr__(self):
        return "FileError(%s, %s)" % (self.path, self.message)


class Result(object):
    def __init__(self):
        self.files_found = 0
        self.decrypted = 0
        self.decrypt_failed = 0
        self.decrypt_skipped = 0
        self.mp3_ok = 0
        self.mp3_failed = 0
        self.mp3_skipped = 0
        self.cancelled = False
        self.errors = []          # [FileError]
        self.started_at = 0.0
        self.finished_at = 0.0

    @property
    def elapsed(self):
        return (self.finished_at or time.time()) - self.started_at

    @property
    def ok(self):
        if self.cancelled:
            return False
        if self.files_found == 0:
            return False
        return self.decrypted + self.decrypt_skipped > 0

    def to_dict(self):
        return {
            "files_found": self.files_found,
            "decrypted": self.decrypted,
            "decrypt_failed": self.decrypt_failed,
            "decrypt_skipped": self.decrypt_skipped,
            "mp3_ok": self.mp3_ok,
            "mp3_failed": self.mp3_failed,
            "mp3_skipped": self.mp3_skipped,
            "cancelled": self.cancelled,
            "errors": [e.to_dict() for e in self.errors],
            "elapsed": round(self.elapsed, 3),
        }

    def summary(self):
        parts = ["找到 %d 个加密文件" % self.files_found]
        parts.append("解密 %d 成功 / %d 失败 / %d 已存在跳过"
                     % (self.decrypted, self.decrypt_failed, self.decrypt_skipped))
        if self.mp3_ok or self.mp3_failed or self.mp3_skipped:
            parts.append("MP3 %d 生成 / %d 失败 / %d 跳过"
                         % (self.mp3_ok, self.mp3_failed, self.mp3_skipped))
        if self.cancelled:
            parts.append("（已中断）")
        return "；".join(parts)


class Options(object):
    def __init__(self, input_dir=None, output_root=None, flac_dir=None, mp3_dir=None,
                 bitrate="192k", keep_flac=False, no_mp3=False, force=False,
                 jobs=1, ekey=None, verify_output=False, ffmpeg_path=None,
                 auto_ekey=True, authst=None, uin=None, tag_from_filename=True):
        self.input_dir = os.path.abspath(os.path.expanduser(input_dir or os.getcwd()))
        root = os.path.abspath(os.path.expanduser(output_root or os.path.join(self.input_dir, "output")))
        self.output_root = root
        self.flac_dir = os.path.abspath(os.path.expanduser(flac_dir)) if flac_dir else os.path.join(root, "flac")
        self.mp3_dir = os.path.abspath(os.path.expanduser(mp3_dir)) if mp3_dir else os.path.join(root, "mp3")
        self.bitrate = normalize_bitrate(bitrate)
        self.keep_flac = bool(keep_flac)
        self.no_mp3 = bool(no_mp3)
        self.force = bool(force)
        self.jobs = max(1, int(jobs or 1))
        self.ekey = ekey
        self.auto_ekey = bool(auto_ekey)
        self.authst = authst
        self.uin = uin
        self.tag_from_filename = bool(tag_from_filename)
        self.verify_output = bool(verify_output)
        self.ffmpeg_path = ffmpeg_path


def normalize_bitrate(value):
    """只接受 128k / 320k 这种写法；越界就夹回合理区间。"""
    text = (value or "192k").strip().lower()
    if not text.endswith("k") or not text[:-1].isdigit():
        return "192k"
    kbps = int(text[:-1])
    if kbps > 320:
        return "320k"
    if kbps < 32:
        return "192k"
    return "%dk" % kbps


def scan_inputs(root):
    """递归找所有受支持的加密文件，按路径排序（结果稳定，方便断点续跑）。"""
    return decrypt.scan(root)


def _force_remove(path, attempts=5, delay=0.2):
    for _ in range(attempts):
        try:
            if os.path.exists(path):
                os.unlink(path)
            return True
        except OSError:
            time.sleep(delay)
    return False


class Job(object):
    def __init__(self, options, on_log=None, on_progress=None, on_file=None):
        self.options = options
        self.on_log = on_log or (lambda level, message: None)
        self.on_progress = on_progress or (lambda progress: None)
        self.on_file = on_file or (lambda event: None)
        self._cancel = False
        self.result = Result()

    # ---------------------------------------------------------- 控制 ----
    def cancel(self):
        self._cancel = True

    def log(self, message, level="info"):
        self.on_log(level, message)

    # ------------------------------------------------------------ 主流程 ----
    def run(self):
        opts = self.options
        result = self.result
        result.started_at = time.time()

        if not os.path.isdir(opts.input_dir):
            self.log("输入目录不存在：%s" % opts.input_dir, "error")
            result.finished_at = time.time()
            return result

        os.makedirs(opts.flac_dir, exist_ok=True)
        os.makedirs(opts.mp3_dir, exist_ok=True)

        self.log("输入目录：%s" % opts.input_dir)
        self.log("FLAC 输出：%s" % opts.flac_dir)
        self.log("MP3 输出：%s" % opts.mp3_dir)

        files = scan_inputs(opts.input_dir)
        result.files_found = len(files)
        if not files:
            self.log("没有找到 .mflac / .mgg（或 .qmcflac 等）加密文件", "warning")
            result.finished_at = time.time()
            return result

        self.log("找到 %d 个文件，开始解密…" % len(files))
        self._decrypt_stage(files)

        if self._cancel:
            result.cancelled = True
            self.log("已中断", "warning")
            result.finished_at = time.time()
            return result

        self._transcode_stage()

        result.finished_at = time.time()
        return result

    # -------------------------------------------------------- 解密阶段 ----
    def _decrypt_stage(self, files):
        opts = self.options
        result = self.result
        total = len(files)
        used = {}   # 输出路径 → 源文件，给不同子目录里的同名歌曲去重

        for index, src in enumerate(files, 1):
            if self._cancel:
                result.cancelled = True
                break

            name = os.path.basename(src)
            ext = decrypt.output_extension(src) or "bin"
            stem = os.path.splitext(name)[0]
            dst, deduped = _unique_path(opts.flac_dir, stem, ext, used, src)
            if deduped:
                self.log("同名冲突，改名为 %s" % os.path.basename(dst), "warning")

            if os.path.exists(dst) and not opts.force:
                result.decrypt_skipped += 1
                self.on_progress(Progress("解密", index, total, name))
                self.on_file({"event": "decrypt-skip", "input": src, "output": dst})
                continue

            try:
                info = decrypt.decrypt_file(src, dst, ekey=opts.ekey, overwrite=True,
                                            auto_ekey=opts.auto_ekey,
                                            authst=opts.authst, uin=opts.uin)
            except decrypt.DecryptError as exc:
                result.decrypt_failed += 1
                result.errors.append(FileError(src, "decrypt", exc.reason, str(exc)))
                self.log("解密失败：%s — %s" % (name, exc), "error")
                self.on_file({"event": "decrypt-fail", "input": src,
                              "reason": exc.reason, "message": str(exc)})
            except Exception as exc:  # 兜底，别让一个文件打断整批
                result.decrypt_failed += 1
                result.errors.append(FileError(src, "decrypt", "unexpected", str(exc)))
                self.log("解密异常：%s — %s" % (name, exc), "error")
                self.on_file({"event": "decrypt-fail", "input": src,
                              "reason": "unexpected", "message": str(exc)})
            else:
                result.decrypted += 1
                note = ""
                if opts.verify_output:
                    check = verify.verify_file(dst)
                    note = "，容器校验 %s" % ("通过" if check.get("ok") else "未通过")
                    if not check.get("ok"):
                        result.errors.append(FileError(src, "verify", "bad-container",
                                                       str(check.get("detail"))))
                self.log("解密成功：%s → %s%s" % (name, os.path.basename(dst), note))
                self.on_file({"event": "decrypt-ok", "input": src, "output": dst, "info": info})

            self.on_progress(Progress("解密", index, total, name))

        if result.decrypted or result.decrypt_skipped:
            self.log("解密阶段完成：成功 %d，失败 %d，跳过 %d"
                     % (result.decrypted, result.decrypt_failed, result.decrypt_skipped))
        elif result.decrypt_failed:
            self.log("解密全部失败，没有可转码的文件", "error")

    # -------------------------------------------------------- 转码阶段 ----
    def _transcode_stage(self):
        opts = self.options
        result = self.result

        try:
            flac_files = sorted(f for f in os.listdir(opts.flac_dir) if f.lower().endswith(".flac"))
            ogg_files = sorted(f for f in os.listdir(opts.flac_dir) if f.lower().endswith(".ogg"))
        except OSError as exc:
            self.log("读不了 FLAC 目录：%s" % exc, "error")
            return

        jobs = [(os.path.join(opts.flac_dir, f), f) for f in flac_files + ogg_files]
        if not jobs:
            self.log("没有可转码的 FLAC/OGG 文件")
            return

        ffmpeg_path = opts.ffmpeg_path
        need_ffmpeg = not opts.no_mp3 or bool(ogg_files)
        if need_ffmpeg:
            try:
                ffmpeg_path = ffmpeg_path or audio.require_ffmpeg()
            except audio.FFmpegMissing as exc:
                self.log(str(exc), "error")
                result.mp3_failed = len(jobs) if not opts.no_mp3 else len(ogg_files)
                return
            self.log("ffmpeg：%s" % ffmpeg_path)

        total = len(jobs)
        self.log("找到 %d 个音频，开始转码…" % total)

        tally = _Tally()

        def handle(item):
            src, name = item
            if self._cancel:
                return
            ext = os.path.splitext(name)[1].lower()
            mp3_path = os.path.join(opts.mp3_dir, os.path.splitext(name)[0] + ".mp3")

            if opts.no_mp3 and ext == ".flac":
                tally.add("ok")
                self.on_progress(Progress("转码", tally.done, total, name))
                self.on_file({"event": "transcode-skip", "input": src, "reason": "no-mp3"})
                return

            keep_source = False if opts.no_mp3 else opts.keep_flac

            if os.path.exists(mp3_path) and not opts.force:
                tally.add("skip")
                if not keep_source:
                    _force_remove(src)
                self.on_progress(Progress("转码", tally.done, total, name))
                self.on_file({"event": "transcode-skip", "input": src, "output": mp3_path})
                return

            metadata = None
            if opts.tag_from_filename:
                metadata = audio.merge_tags(audio.read_tags(src, ffmpeg_path), name)
            ok, message = audio.transcode_to_mp3(src, mp3_path, ffmpeg_path, opts.bitrate,
                                                metadata=metadata)
            if ok:
                tally.add("ok")
                if not keep_source:
                    _force_remove(src)
                note = ""
                if opts.verify_output:
                    check = verify.verify_file(mp3_path)
                    note = "，校验 %s" % ("通过" if check.get("ok") else "未通过")
                    if not check.get("ok"):
                        self.result.errors.append(
                            FileError(src, "verify", "bad-mp3", str(check.get("detail"))))
                self.log("转码成功：%s%s" % (os.path.basename(mp3_path), note))
                self.on_file({"event": "transcode-ok", "input": src, "output": mp3_path})
            else:
                tally.add("fail")
                self.result.errors.append(FileError(src, "transcode", "ffmpeg", message))
                self.log("转码失败：%s — %s" % (name, message), "error")
                self.on_file({"event": "transcode-fail", "input": src,
                              "reason": "ffmpeg", "message": message})

            self.on_progress(Progress("转码", tally.done, total, name))

        if opts.jobs > 1 and total > 1:
            with ThreadPoolExecutor(max_workers=opts.jobs) as pool:
                list(pool.map(handle, jobs))
        else:
            for item in jobs:
                handle(item)

        result.mp3_ok = tally.ok
        result.mp3_failed = tally.fail
        result.mp3_skipped = tally.skip
        self.log("转码阶段完成：成功 %d，失败 %d，跳过 %d"
                 % (result.mp3_ok, result.mp3_failed, result.mp3_skipped))


def _unique_path(folder, stem, ext, used, src):
    """输出目录是平铺的：不同子目录里同名的歌会撞车，这里加序号区分。"""
    candidate = os.path.join(folder, "%s.%s" % (stem, ext))
    if used.get(candidate, src) == src:
        used[candidate] = src
        return candidate, False
    index = 2
    while True:
        candidate = os.path.join(folder, "%s (%d).%s" % (stem, index, ext))
        if candidate not in used or used[candidate] == src:
            used[candidate] = src
            return candidate, True
        index += 1


class _Tally(object):
    """转码阶段的线程安全计数器（functools 的并发回调会撞线程）。"""

    def __init__(self):
        self._lock = threading.Lock()
        self.ok = 0
        self.fail = 0
        self.skip = 0
        self.done = 0

    def add(self, kind):
        with self._lock:
            self.done += 1
            if kind == "ok":
                self.ok += 1
            elif kind == "fail":
                self.fail += 1
            else:
                self.skip += 1


def run(options, on_log=None, on_progress=None, on_file=None):
    """一行跑完整流程。"""
    return Job(options, on_log=on_log, on_progress=on_progress, on_file=on_file).run()
