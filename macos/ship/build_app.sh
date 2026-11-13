#!/bin/bash
# 打一个「双击就能用」的发布包：内置 Python 运行时 + ffmpeg，对方不需要装任何东西。
#
#   bash ship/build_app.sh              # 默认 arm64，产物在 dist/
#
# 说明：
# - 打出来的包只对当前 CPU 架构有效（本机是 arm64 就只给 arm64 用）。
#   要给 Intel Mac 用，就在 Intel 机器上跑一遍这个脚本，或者
#   ARCH=x86_64 配上 x86_64 的 Python 再打一次。
# - 不做签名/公证，所以首次打开需要「右键 → 打开」一次。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

VERSION="$(python3 -c 'import sys; sys.path.insert(0,"."); from tunefree_backend import VERSION; print(VERSION)')"
ARCH="${ARCH:-$(uname -m)}"
BUILD="$ROOT/.build"
VENV="$BUILD/venv"
DIST="$ROOT/dist"
STAGE="$DIST/TuneFree-$VERSION-$ARCH"

echo "==> 版本 ${VERSION}，架构 ${ARCH}"

# 1) 独立的构建环境（只在构建机上用，不进发布包）
if [ ! -x "$VENV/bin/python" ]; then
  echo "==> 建构建环境"
  # shellcheck disable=SC2086
  ${BUILD_PYTHON:-/usr/bin/python3} -m venv "$VENV"
fi
"$VENV/bin/python" -m pip install -q --upgrade pip
"$VENV/bin/python" -m pip install -q pyinstaller imageio-ffmpeg

# 2) 打包后端（onedir 比 onefile 启动快，ffmpeg 也能放在旁边）
echo "==> PyInstaller 打包"
rm -rf "$BUILD/pyi" "$DIST/TuneFreeBackend"
"$VENV/bin/python" -m PyInstaller \
  --noconfirm --clean --onedir --console \
  --name TuneFreeBackend \
  --paths "$ROOT" \
  --distpath "$DIST" \
  --workpath "$BUILD/pyi" \
  --specpath "$BUILD" \
  --exclude-module tkinter --exclude-module unittest --exclude-module pydoc \
  --exclude-module imageio_ffmpeg --exclude-module imageio --exclude-module numpy \
  main.py

# 3) 把 ffmpeg 塞进去（对方就不用 brew install 了）
echo "==> 内置 ffmpeg"
FFMPEG_SRC="$("$VENV/bin/python" -c 'import imageio_ffmpeg; print(imageio_ffmpeg.get_ffmpeg_exe())')"
cp "$FFMPEG_SRC" "$DIST/TuneFreeBackend/ffmpeg"
rm -rf "$DIST/TuneFreeBackend/_internal/imageio_ffmpeg"
chmod +x "$DIST/TuneFreeBackend/ffmpeg"
xattr -c "$DIST/TuneFreeBackend/ffmpeg" 2>/dev/null || true

# 4) 组装发布目录
echo "==> 组装 ${STAGE}"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$DIST/TuneFreeBackend" "$STAGE/TuneFreeBackend"
cp "$HERE/TuneFree.command" "$STAGE/TuneFree.command"
chmod +x "$STAGE/TuneFree.command" "$STAGE/TuneFreeBackend/TuneFreeBackend"
[ -f "$HERE/使用说明.txt" ] && cp "$HERE/使用说明.txt" "$STAGE/使用说明.txt"
cp "$ROOT/README.md" "$STAGE/技术说明.md" 2>/dev/null || true

# 5) 自检：跑一遍内置自检，确认包里东西齐全
echo "==> 包内自检"
"$STAGE/TuneFreeBackend/TuneFreeBackend" --selftest | tail -14

# 6) 压缩（保留符号链接，别把 macOS 结构压坏）
echo "==> 压缩"
( cd "$DIST" && rm -f "TuneFree-$VERSION-$ARCH.zip" && ditto -c -k --sequesterRsrc --keepParent \
    "TuneFree-$VERSION-$ARCH" "TuneFree-$VERSION-$ARCH.zip" )

echo
echo "完成："
du -sh "$STAGE" "$DIST/TuneFree-$VERSION-$ARCH.zip"
echo "发给别人：$(basename "${DIST}/TuneFree-${VERSION}-${ARCH}.zip")"
