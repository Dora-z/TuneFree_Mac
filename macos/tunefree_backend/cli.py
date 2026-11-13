#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""TuneFree macOS 后端命令行（`tunefree` / `python main.py` 都走这里）。

前端可以 spawn 这个进程，解析 ``@@PROGRESS 解密 3/10`` 这一行，
或者加 ``--json`` 拿结构化事件（TuneFree.app 就是这么接的）。

    python main.py -i "~/Music/下载" -o "~/Music/导出" -b 320k
    python main.py -i "~/Music/下载" --json          # 事件流，给新前端用
    python main.py --info -i "~/Music/下载"          # 只探查尾部结构，不解密
    python main.py --selftest                       # 自检（向量 + 端到端 + ffmpeg）
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import traceback

from . import VERSION, Options, audio, decrypt, job as job_mod, run_selftest


# ------------------------------------------------------------ 输出适配 ----

class Reporter(object):
    """统一处理两种输出：给人看的日志 + 给程序解析的 @@PROGRESS / JSON 事件。"""

    def __init__(self, json_mode=False):
        self.json_mode = json_mode
        self._tty = False
        try:
            self._tty = sys.stdout is not None and sys.stdout.isatty()
        except (ValueError, AttributeError):
            self._tty = False

    def log(self, level, message):
        if self.json_mode:
            self._emit({"event": "log", "level": level, "message": message})
        else:
            logging.log(
                {"debug": logging.DEBUG, "info": logging.INFO,
                 "warning": logging.WARNING, "error": logging.ERROR}.get(level, logging.INFO),
                message,
            )

    def progress(self, progress):
        if self.json_mode:
            self._emit({"event": "progress", "phase": progress.phase,
                        "done": progress.done, "total": progress.total,
                        "percent": round(progress.percent, 1),
                        "file": progress.current_file})
            return
        print("@@PROGRESS %s %d/%d" % (progress.phase, progress.done, progress.total), flush=True)
        if self._tty:
            print("%s: %d/%d" % (progress.phase, progress.done, progress.total),
                  end="\r", flush=True)

    def file_event(self, payload):
        if self.json_mode:
            self._emit(payload)

    def result(self, result):
        if self.json_mode:
            self._emit({"event": "result", "result": result.to_dict()})
        else:
            logging.info(result.summary())

    def _emit(self, payload):
        sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
        sys.stdout.flush()


# ---------------------------------------------------------------- 参数 ----

def build_parser():
    parser = argparse.ArgumentParser(
        prog="TuneFree",
        description="解密 QQ音乐 mflac/mgg 文件并转换为 MP3（macOS 后端，无需 QQ音乐客户端）",
    )
    parser.add_argument("-i", "--input", help="输入目录（包含 .mflac / .mgg 文件），默认为当前目录")
    parser.add_argument("-o", "--output", help="输出根目录（默认：输入目录下的 output），其下自动创建 mp3 与 flac 子目录")
    parser.add_argument("--flac-dir", help="FLAC 输出目录")
    parser.add_argument("--mp3-dir", help="MP3 输出目录")
    parser.add_argument("-b", "--bitrate", default="192k", help="MP3 比特率，例如 128k / 192k / 320k（默认 192k）")
    parser.add_argument("--keep-flac", action="store_true", help="保留解密后的 FLAC/OGG 原始文件")
    parser.add_argument("--no-mp3", action="store_true", help="不生成 MP3，仅保留 FLAC（OGG 仍会转成 MP3）")
    parser.add_argument("--force", action="store_true", help="已存在的输出也重新生成")
    parser.add_argument("-j", "--jobs", type=int, default=1, help="转码并发数（默认 1；机械硬盘建议保持 1）")
    parser.add_argument("--ekey", help="musicex 布局的文件需要单独提供 ekey（base64）")
    parser.add_argument("--authst", help="手动指定 QQ音乐 authst（默认读本机登录态）")
    parser.add_argument("--uin", help="手动指定 QQ音乐 uin")
    parser.add_argument("--no-ekey-fetch", action="store_true",
                        help="不自动向 GetEVkey 接口取密钥（只用文件内 ekey 或 --ekey）")
    parser.add_argument("--ffmpeg", help="手动指定 ffmpeg 路径")
    parser.add_argument("--no-tags", action="store_true",
                        help="不从文件名回填 歌名/歌手 标签（默认会补全缺失的标签）")
    parser.add_argument("--no-online-tags", action="store_true",
                        help="不联网补全标签（默认会按歌曲 ID 向 QQ音乐查封面、专辑、年份、歌词）")
    parser.add_argument("--lrc", action="store_true", help="另存一份 .lrc 同步歌词（与 MP3 同名）")
    parser.add_argument("--verify", action="store_true", help="解密/转码后校验音频容器完整性")
    parser.add_argument("--json", action="store_true", help="以 JSON 行输出事件（前端解析用）")
    parser.add_argument("--info", action="store_true", help="只探查文件尾部结构，不解密")
    parser.add_argument("--selftest", action="store_true", help="跑内置自检（算法向量 + 端到端）")
    parser.add_argument("-v", "--version", action="version", version="TuneFree %s" % VERSION)
    return parser


def _setup_logging():
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s",
                        datefmt="%H:%M:%S")


# ---------------------------------------------------------------- 命令 ----

def cmd_info(paths, reporter):
    rows = []
    for path in paths:
        try:
            rows.append(decrypt.probe(path))
        except decrypt.DecryptError as exc:
            rows.append({"path": path, "error": str(exc)})
    if reporter.json_mode:
        for row in rows:
            reporter._emit({"event": "info", "info": row})
        return 0
    for row in rows:
        if "error" in row:
            print("%s\n  读取失败：%s" % (row["path"], row["error"]))
            continue
        print(row["path"])
        print("  大小：%s 字节" % row["size"])
        print("  尾部布局：%s（解密目标 .%s）" % (row["kind"], row["format"]))
        if row.get("audio_bytes"):
            print("  音频数据：%s 字节" % row["audio_bytes"])
        if row.get("song_id"):
            print("  song_id：%s" % row["song_id"])
        if row.get("mid"):
            print("  media_mid：%s" % row["mid"])
        if row.get("filename"):
            print("  资源名：%s" % row["filename"])
        if row.get("ekey"):
            print("  ekey（截断）：%s" % row["ekey"])
        if row.get("key_bytes"):
            print("  内嵌 key：%s 字节" % row["key_bytes"])
        if row["kind"] == "musicex":
            auto = row.get("ekey_auto") or {}
            if auto.get("available"):
                print("  密钥：不在文件里，可自动取（QQ音乐登录态 uin %s，来源 %s）"
                      % (auto.get("uin") or "?", auto.get("source")))
            else:
                print("  密钥：不在文件里，也没读到 QQ音乐登录态 —— 需要 --ekey <base64>")
    return 0


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    args = build_parser().parse_args(argv)
    _setup_logging()
    reporter = Reporter(json_mode=args.json)

    if args.selftest:
        ok, _ = run_selftest(verbose=not args.json)
        if args.json:
            reporter._emit({"event": "selftest", "ok": ok})
        return 0 if ok else 1

    input_dir = os.path.abspath(os.path.expanduser(args.input)) if args.input else os.getcwd()

    if args.info:
        if os.path.isfile(input_dir):
            paths = [input_dir]
        elif os.path.isdir(input_dir):
            paths = job_mod.scan_inputs(input_dir)
            if not paths:
                reporter.log("warning", "%s 里没有受支持的加密文件" % input_dir)
                return 1
        else:
            reporter.log("error", "路径不存在：%s" % input_dir)
            return 1
        return cmd_info(paths, reporter)

    if not os.path.isdir(input_dir):
        reporter.log("error", "输入目录不存在：%s" % input_dir)
        return 1

    if args.ffmpeg:
        os.environ["TUNEFREE_FFMPEG"] = args.ffmpeg

    reporter.log("info", "TuneFree %s（macOS 后端，本地离线解密）" % VERSION)

    if not args.no_ekey_fetch:
        from . import ekey as ekey_mod

        try:
            creds = ekey_mod.get_credentials(args.authst, args.uin)
            reporter.log("info", "QQ音乐登录态：uin %s（来源：%s），musicex 文件会自动取密钥"
                         % (creds.uin or "?", creds.source))
        except ekey_mod.EkeyError:
            reporter.log("warning", "没有读到 QQ音乐登录态；musicex 布局的文件将需要 --ekey")

    if not args.no_mp3:
        path = audio.find_ffmpeg()
        if path:
            reporter.log("info", "ffmpeg：%s" % path)
        else:
            reporter.log("warning", "没找到 ffmpeg，只能输出 FLAC/OGG：brew install ffmpeg")

    options = Options(
        input_dir=input_dir,
        output_root=args.output,
        flac_dir=args.flac_dir,
        mp3_dir=args.mp3_dir,
        bitrate=args.bitrate,
        keep_flac=args.keep_flac,
        no_mp3=args.no_mp3,
        force=args.force,
        jobs=args.jobs,
        ekey=args.ekey,
        auto_ekey=not args.no_ekey_fetch,
        authst=args.authst,
        uin=args.uin,
        verify_output=args.verify,
        tag_from_filename=not args.no_tags,
        online_tags=not args.no_online_tags,
        write_lrc=args.lrc,
        ffmpeg_path=args.ffmpeg,
    )

    task = job_mod.Job(
        options,
        on_log=reporter.log,
        on_progress=reporter.progress,
        on_file=reporter.file_event,
    )

    try:
        result = task.run()
    except KeyboardInterrupt:
        task.cancel()
        reporter.log("warning", "已被用户中断")
        return 130

    reporter.result(result)

    if result.cancelled:
        return 130
    if not result.ok:
        if result.decrypt_failed and not (result.decrypted or result.decrypt_skipped):
            reporter.log("error", "解密全部失败，没有产出；失败原因见上文")
        elif result.files_found == 0:
            reporter.log("error", "没有找到可处理的文件（.mflac / .mgg，可含子目录）")
        return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except Exception:
        logging.error("程序异常终止：")
        traceback.print_exc()
        sys.exit(1)
