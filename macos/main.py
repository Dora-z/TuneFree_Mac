#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""源码运行入口。真正的实现在 tunefree_backend/cli.py（安装后即 `tunefree` 命令）。

    python main.py -i "~/Music/下载" -o "~/Music/导出" -b 320k
    python main.py --selftest
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from tunefree_backend.cli import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main())
