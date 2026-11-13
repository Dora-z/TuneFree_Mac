# -*- coding: utf-8 -*-
# dmgbuild 的配置：DMG 打开后的 Finder 窗口长什么样。
#   dmgbuild -s Support/dmg_settings.py -D app=… -D background=… -D volicon=… "TuneFree" out.dmg
# 背景图由 Support/make_dmg_background.swift 生成（720×440 pt，1x + 2x 合成 TIFF），
# 图标位置要和背景上的箭头对齐。
import os

app = defines["app"]                       # noqa: F821  （dmgbuild 注入）
app_name = os.path.basename(app)

format = "ULFO"                             # LZFSE 压缩：比 UDZO 小，macOS 10.11+ 都能开
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
hide_extensions = [app_name]                # 显示成「TuneFree」而不是「TuneFree.app」
icon = defines.get("volicon")              # noqa: F821  卷图标（Finder 侧栏 / 标题栏）

background = defines["background"]         # noqa: F821
window_rect = ((240, 160), (720, 440))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True

arrange_by = None
icon_size = 112
text_size = 13
label_pos = "bottom"
icon_locations = {
    app_name: (190, 215),
    "Applications": (530, 215),
}
