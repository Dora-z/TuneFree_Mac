#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""前端接入示例：两种接法都能跑，直接抄。

    python3 examples/frontend_usage.py -i /tmp/tf-samples -o /tmp/out --mode api
    python3 examples/frontend_usage.py -i /tmp/tf-samples -o /tmp/out --mode subprocess
    python3 examples/frontend_usage.py --print-qt > worker.py     # 打印 PySide6 版 Worker

两种接法的差别：

* ``api``：进程内调用，能拿到 Result / FileError 结构，能取消，适合新界面；
* ``subprocess``：起一个 python 子进程，解析 ``@@PROGRESS 解密 3/10``，
  适合任何语言写的界面（加 ``--json`` 可拿结构化事件，``--mode json``）。
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BACKEND = os.path.dirname(HERE)
sys.path.insert(0, BACKEND)

from tunefree_backend import Options, Job  # noqa: E402


# ------------------------------------------------------------------ 方式 A ----

def run_inprocess(input_dir, output_dir, bitrate="320k"):
    """进程内调用：回调直接更新界面。"""
    opts = Options(input_dir=input_dir, output_root=output_dir, bitrate=bitrate)
    job = Job(
        opts,
        on_log=lambda level, msg: print("[%s] %s" % (level, msg)),
        on_progress=lambda p: print("\r%s %d/%d  %-30s" % (p.phase, p.done, p.total, p.current_file[:30]),
                                    end="", flush=True),
        on_file=lambda ev: print("\n  事件：%s %s" % (ev["event"], os.path.basename(ev.get("input", "")))),
    )
    result = job.run()
    print()
    print("完成：", result.summary())
    for err in result.errors:
        print("  失败 %s（%s）：%s" % (os.path.basename(err.path), err.stage, err.message))
    return result


# ------------------------------------------------------------------ 方式 B ----

def run_via_subprocess(input_dir, output_dir, bitrate="320k"):
    """子进程调用：解析 @@PROGRESS 协议。"""
    cmd = [sys.executable, os.path.join(BACKEND, "main.py"),
           "-i", input_dir, "-o", output_dir, "-b", bitrate]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, encoding="utf-8", errors="replace", bufsize=1)
    last = None
    for line in proc.stdout:
        line = line.rstrip()
        if line.startswith("@@PROGRESS"):
            # @@PROGRESS 解密 3/10
            parts = line.split()
            if len(parts) == 3:
                phase, ratio = parts[1], parts[2]
                done, _, total = ratio.partition("/")
                try:
                    percent = 100.0 * int(done) / max(1, int(total))
                except ValueError:
                    percent = 0.0
                last = (phase, int(done), int(total))
                print("\r%s %d/%d（%.0f%%）" % (phase, int(done), int(total), percent),
                      end="", flush=True)
        else:
            print("\n" + line)
    print()
    code = proc.wait()
    print("退出码 %d，最后一帧进度 %s" % (code, last))
    return code


def run_json_events(input_dir, output_dir, bitrate="320k"):
    """子进程 + --json：拿到结构化事件流，新前端用这个最省事。"""
    cmd = [sys.executable, os.path.join(BACKEND, "main.py"),
           "-i", input_dir, "-o", output_dir, "-b", bitrate, "--json"]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            text=True, encoding="utf-8", errors="replace", bufsize=1)
    for line in proc.stdout:
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if event.get("event") == "progress":
            print("\r%s %d/%d %s" % (event["phase"], event["done"], event["total"],
                                     event["file"][:28]), end="", flush=True)
        elif event.get("event") == "result":
            print("\n结果：%s" % json.dumps(event["result"], ensure_ascii=False))
        elif event.get("event") == "log" and event.get("level") in ("warning", "error"):
            print("\n[%s] %s" % (event["level"], event["message"]))
    print()
    return proc.wait()


# --------------------------------------------------------------- PySide6 ----

QT_WORKER = r'''# -*- coding: utf-8 -*-
"""PySide6 版 Worker：把后端放进 QThread，进度用信号回到主线程。"""
from PySide6.QtCore import QObject, QThread, Signal

from tunefree_backend import Options, Job


class TuneFreeWorker(QObject):
    progress = Signal(str, int, int, str)      # phase, done, total, 文件名
    logged = Signal(str, str)                  # level, message
    finished = Signal(object)                  # Result
    file_event = Signal(dict)

    def __init__(self, options):
        super().__init__()
        self.options = options
        self._job = None

    def run(self):
        self._job = Job(
            self.options,
            on_log=lambda lvl, msg: self.logged.emit(lvl, msg),
            on_progress=lambda p: self.progress.emit(p.phase, p.done, p.total, p.current_file),
            on_file=self.file_event.emit,
        )
        self.finished.emit(self._job.run())

    def cancel(self):
        if self._job:
            self._job.cancel()


class TuneFreeController(QObject):
    """界面侧只管三件事：start / cancel / 接信号。"""

    def __init__(self, parent=None):
        super().__init__(parent)
        self._thread = None
        self._worker = None

    def start(self, input_dir, output_dir, bitrate="320k", jobs=1):
        self._thread = QThread()
        self._worker = TuneFreeWorker(
            Options(input_dir=input_dir, output_root=output_dir, bitrate=bitrate, jobs=jobs)
        )
        self._worker.moveToThread(self._thread)
        self._thread.started.connect(self._worker.run)
        self._worker.finished.connect(self._thread.quit)
        self._thread.start()
        return self._worker

    def cancel(self):
        if self._worker:
            self._worker.cancel()

    def wait(self, msecs=10000):
        if self._thread:
            self._thread.wait(msecs)
'''

QT_USAGE = r'''
# 接到界面上大致是这样：
#
#   self.ctl = TuneFreeController()
#   worker = self.ctl.start("/Users/me/Music/下载", "/Users/me/Music/导出", "320k", jobs=2)
#   worker.progress.connect(lambda phase, done, total, name:
#       (self.bar.setMaximum(total), self.bar.setValue(done),
#        self.label.setText(f"{phase}：{name}")))
#   worker.logged.connect(self.log_view.appendPlainText)
#   worker.finished.connect(lambda result: self.status.setText(result.summary()))
#
#   取消按钮 → self.ctl.cancel()
'''


def main(argv=None):
    parser = argparse.ArgumentParser(description="TuneFree 后端接入示例")
    parser.add_argument("-i", "--input", default="")
    parser.add_argument("-o", "--output", default="")
    parser.add_argument("-b", "--bitrate", default="320k")
    parser.add_argument("--mode", choices=["api", "subprocess", "json"], default="api")
    parser.add_argument("--print-qt", action="store_true", help="打印 PySide6 Worker 代码")
    args = parser.parse_args(argv)

    if args.print_qt:
        print(QT_WORKER)
        print(QT_USAGE)
        return 0

    if not args.input:
        parser.error("需要 -i 输入目录")
    input_dir = os.path.abspath(os.path.expanduser(args.input))
    output_dir = os.path.abspath(os.path.expanduser(args.output)) if args.output else None

    if args.mode == "api":
        result = run_inprocess(input_dir, output_dir, args.bitrate)
        return 0 if result.ok else 1
    if args.mode == "subprocess":
        return run_via_subprocess(input_dir, output_dir, args.bitrate) and 1 or 0
    return run_json_events(input_dir, output_dir, args.bitrate)


if __name__ == "__main__":
    sys.exit(main())
