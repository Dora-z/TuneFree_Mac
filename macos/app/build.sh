#!/bin/bash
# 打出「双击就能用」的 TuneFree.app：SwiftUI 界面 + 内置 Python 运行时 + 内置 ffmpeg。
# 用户机器上什么都不用装（不需要 Python、不需要 Homebrew、不需要 QQ音乐在运行）。
#
#   bash app/build.sh                    # 两种芯片都打：dist/<架构>/TuneFree.app 与 dist/TuneFree-<版本>-<架构>.dmg
#   bash app/build.sh --arch arm64       # 只打 Apple 芯片版
#   bash app/build.sh --arch x86_64      # 只打 Intel 版
#   bash app/build.sh --no-dmg           # 只要 .app
#   bash app/build.sh --reuse-backend    # 复用 dist/<架构>/TuneFreeBackend，不重新跑 PyInstaller
#
# 只需要 Xcode 命令行工具（xcode-select --install），不需要完整 Xcode。
#
# 交叉打包 Intel 版（在 Apple 芯片上）：
#   - 界面：swift build --arch x86_64 直接交叉编译；
#   - 后端：PyInstaller 只能打「运行它的那个 Python」的架构，所以要一个 x86_64 的 Python，
#     在 Rosetta 下跑。默认用 uv 管理的独立版 CPython（没有就自动 `uv python install`），
#     也可以用 BUILD_PYTHON_X86_64=/path/to/python 指定；
#   - 包内自检也在 Rosetta 下跑（softwareupdate --install-rosetta 装一次即可）。
# 在 Intel Mac 上打 Intel 版则一切都是原生的。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"          # macos/
cd "$ROOT"

MAKE_DMG=1
REUSE_BACKEND=0
ARCHS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --no-dmg) MAKE_DMG=0 ;;
    --reuse-backend) REUSE_BACKEND=1 ;;
    --arch) shift; ARCHS+=("$1") ;;
    --arch=*) ARCHS+=("${1#--arch=}") ;;
    *) echo "未知参数：$1"; exit 2 ;;
  esac
  shift
done
[ ${#ARCHS[@]} -gt 0 ] || ARCHS=(${ARCH:-arm64 x86_64})
for a in "${ARCHS[@]}"; do
  case "$a" in arm64|x86_64) ;; *) echo "不支持的架构：$a（arm64 或 x86_64）"; exit 2 ;; esac
done

VERSION="$(python3 -c 'import sys; sys.path.insert(0,"."); from tunefree_backend import VERSION; print(VERSION)')"
SHORT_VERSION="${VERSION%%-*}"
BUILD="$ROOT/.build"
DIST="$ROOT/dist"
HOST_ARCH="$(uname -m)"
mkdir -p "$BUILD" "$DIST"

echo "==> TuneFree ${VERSION}（${ARCHS[*]}）"

# ------------------------------------------------------- 构建用 Python ----
build_python() {  # $1=架构 → 打印该架构的 Python 解释器路径
  local arch="$1" py=""
  if [ "$arch" = arm64 ]; then
    py="${BUILD_PYTHON_ARM64:-${BUILD_PYTHON:-}}"
  else
    py="${BUILD_PYTHON_X86_64:-}"
  fi
  if [ -z "$py" ] && [ "$arch" = "$HOST_ARCH" ] && arch "-$arch" /usr/bin/python3 -c "" 2>/dev/null; then
    py=/usr/bin/python3
  fi
  if [ -z "$py" ] && command -v uv >/dev/null 2>&1; then
    local want="cpython-3.12-macos-$arch-none"
    py="$(uv python find "$want" 2>/dev/null || true)"
    if [ -z "$py" ]; then
      uv python install "$want" >&2
      py="$(uv python find "$want")"
    fi
  fi
  [ -n "$py" ] && arch "-$arch" "$py" -c "" 2>/dev/null || {
    echo "✗ 找不到能跑 $arch 的 Python。装 uv（brew install uv）或用 BUILD_PYTHON_$( [ "$arch" = arm64 ] && echo ARM64 || echo X86_64 )=… 指定" >&2
    return 1
  }
  echo "$py"
}

# ------------------------------------------------------------- SDK 选择 ----
# 新版 SDK 里 SwiftUI 的 @State 变成了宏，宏插件只随完整 Xcode 提供。
# 只有命令行工具时，从新到旧试编一小段代码，挑第一个能编过的 SDK。
pick_sdk() {  # $1=架构
  [ -n "${SDKROOT:-}" ] && return 0
  local probe="$BUILD/sdkprobe.swift"
  cat > "$probe" <<'SWIFT'
import SwiftUI
struct P: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View { configuration.label.onHover { hover = $0 } }
}
SWIFT
  for sdk in "" $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.sdk /Applications/Xcode*.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX[0-9]*.sdk 2>/dev/null | sort -rV); do
    if [ -z "$sdk" ]; then
      xcrun swiftc -typecheck -target "$1-apple-macos14.0" "$probe" >/dev/null 2>&1 && return 0
    elif SDKROOT="$sdk" xcrun swiftc -typecheck -sdk "$sdk" -target "$1-apple-macos14.0" "$probe" >/dev/null 2>&1; then
      export SDKROOT="$sdk"
      return 0
    fi
  done
}

# ---------------------------------------------------------------- 图标 ----
ICONWORK="$BUILD/icon"
make_icon() {
  echo "==> 生成图标"
  rm -rf "$ICONWORK" && mkdir -p "$ICONWORK/AppIcon.iconset"
  swift "$HERE/Support/make_icon.swift" "$ICONWORK/icon_1024.png" >/dev/null
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ICONWORK/icon_1024.png" --out "$ICONWORK/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$ICONWORK/icon_1024.png" --out "$ICONWORK/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONWORK/AppIcon.iconset" -o "$ICONWORK/AppIcon.icns"
}

# ------------------------------------------------------------ 单个架构 ----
build_arch() {
  local ARCH="$1"
  local OUT="$DIST/$ARCH"
  local BACKEND="$OUT/TuneFreeBackend"
  local APP="$OUT/TuneFree.app"
  local VENV="$BUILD/venv-$ARCH"
  local RUN=(arch "-$ARCH")
  mkdir -p "$OUT"
  # 在 Apple 芯片上交叉打 Intel 版时，PyInstaller 跑在 Rosetta 里，它调用的 lipo 等工具
  # 会走 xcrun，而命令行工具的 libxcrun 只有 arm64 —— 用一层包装让这些工具原生运行。
  if [ "$ARCH" != "$HOST_ARCH" ]; then
    local SHIM="$BUILD/toolshim-$HOST_ARCH"
    mkdir -p "$SHIM"
    for tool in lipo otool install_name_tool strip; do
      printf '#!/bin/bash\nexec /usr/bin/arch -%s /usr/bin/%s "$@"\n' "$HOST_ARCH" "$tool" > "$SHIM/$tool"
      chmod +x "$SHIM/$tool"
    done
    RUN=(env "PATH=$SHIM:$PATH" arch "-$ARCH")
  fi
  echo
  echo "======== $ARCH ========"

  # 1) 后端
  if [ "$REUSE_BACKEND" = 1 ] && [ -x "$BACKEND/TuneFreeBackend" ]; then
    echo "==> 复用已有后端：$BACKEND"
  else
    local PY
    PY="$(build_python "$ARCH")"
    echo "==> 打包 Python 后端（$("${RUN[@]}" "$PY" -c 'import sys; print(sys.version.split()[0])')，$ARCH）"
    [ -x "$VENV/bin/python" ] || "${RUN[@]}" "$PY" -m venv "$VENV"
    "${RUN[@]}" "$VENV/bin/python" -m pip install -q --upgrade pip
    "${RUN[@]}" "$VENV/bin/python" -m pip install -q pyinstaller imageio-ffmpeg
    rm -rf "$BUILD/pyi-$ARCH" "$BACKEND"
    "${RUN[@]}" "$VENV/bin/python" -m PyInstaller \
      --noconfirm --clean --onedir --console \
      --name TuneFreeBackend \
      --paths "$ROOT" \
      --distpath "$OUT" \
      --workpath "$BUILD/pyi-$ARCH" \
      --specpath "$BUILD/spec-$ARCH" \
      --exclude-module tkinter --exclude-module unittest --exclude-module pydoc \
      --exclude-module imageio_ffmpeg --exclude-module imageio --exclude-module numpy \
      --log-level WARN \
      main.py

    echo "==> 内置 ffmpeg"
    local FFMPEG_SRC
    FFMPEG_SRC="$("${RUN[@]}" "$VENV/bin/python" -c 'import imageio_ffmpeg; print(imageio_ffmpeg.get_ffmpeg_exe())')"
    cp "$FFMPEG_SRC" "$BACKEND/ffmpeg"
    chmod +x "$BACKEND/ffmpeg"
  fi
  [ -x "$BACKEND/ffmpeg" ] || { echo "✗ 后端里没有 ffmpeg"; exit 1; }
  for bin in "$BACKEND/TuneFreeBackend" "$BACKEND/ffmpeg"; do
    lipo -archs "$bin" | tr ' ' '\n' | grep -qx "$ARCH" || { echo "✗ $(basename "$bin") 不是 $ARCH：$(lipo -archs "$bin")"; exit 1; }
  done

  # 2) 界面
  pick_sdk "$ARCH"
  [ -n "${SDKROOT:-}" ] && echo "==> SDK：$SDKROOT"
  echo "==> 编译 SwiftUI 界面（$ARCH）"
  ( cd "$HERE" && swift build -c release --arch "$ARCH" 2>&1 | grep -vE "^\[|^Building|^Compiling|^Write" || true )
  local BIN
  BIN="$(cd "$HERE" && swift build -c release --arch "$ARCH" --show-bin-path)/TuneFree"
  [ -x "$BIN" ] || { echo "✗ 界面编译失败"; exit 1; }
  lipo -archs "$BIN" | tr ' ' '\n' | grep -qx "$ARCH" || { echo "✗ 界面不是 $ARCH：$(lipo -archs "$BIN")"; exit 1; }

  # 3) 组装
  echo "==> 组装 $APP"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$BIN" "$APP/Contents/MacOS/TuneFree"
  cp "$ICONWORK/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  ditto "$BACKEND" "$APP/Contents/Resources/TuneFreeBackend"
  sed -e "s/__VERSION__/$SHORT_VERSION/g" -e "s/__BUILD__/$VERSION/g" \
    "$HERE/Support/Info.plist" > "$APP/Contents/Info.plist"
  printf 'APPL????' > "$APP/Contents/PkgInfo"
  xattr -cr "$APP" 2>/dev/null || true

  # 4) 签名
  # 没有开发者证书就做 ad-hoc 签名（Apple 芯片要求每个可执行文件都有签名）。
  # 有证书时：CODESIGN_ID="Developer ID Application: xxx" bash app/build.sh
  local SIGN_ID="${CODESIGN_ID:--}"
  local SIGN_OPTS=(--force --timestamp=none -s "$SIGN_ID")
  # 正式证书才开 hardened runtime（公证需要）；ad-hoc 开了会因 Team ID 不同拒绝加载内置 Python
  [ "$SIGN_ID" != "-" ] && SIGN_OPTS=(--force --timestamp --options runtime -s "$SIGN_ID")
  echo "==> 签名（${SIGN_ID}）"
  # 由内到外：先签包内所有 Mach-O（含 Python 运行时、.so、ffmpeg），再签主程序和整个包
  while IFS= read -r -d '' f; do
    if file -b "$f" | grep -q "Mach-O"; then
      codesign "${SIGN_OPTS[@]}" "$f" 2>/dev/null
    fi
  done < <(find "$APP/Contents/Resources/TuneFreeBackend" -type f -print0)
  find "$APP/Contents/Resources/TuneFreeBackend" -name "*.framework" -type d -prune -print0 |
    while IFS= read -r -d '' fw; do codesign "${SIGN_OPTS[@]}" "$fw" 2>/dev/null || true; done
  codesign "${SIGN_OPTS[@]}" "$APP/Contents/MacOS/TuneFree"
  codesign "${SIGN_OPTS[@]}" "$APP"
  codesign --verify --deep --strict "$APP" && echo "    签名校验通过"

  # 5) 自检（Intel 版在 Apple 芯片上走 Rosetta）
  echo "==> 包内自检"
  local SELFTEST
  SELFTEST="$("${RUN[@]}" "$APP/Contents/Resources/TuneFreeBackend/TuneFreeBackend" --selftest 2>&1)" \
    || { echo "$SELFTEST" | tail -20; echo "✗ 包内自检失败"; exit 1; }
  echo "$SELFTEST" | tail -3

  # 6) DMG
  if [ "$MAKE_DMG" = 1 ]; then
    local DMG="$DIST/TuneFree-$VERSION-$ARCH.dmg"
    echo "==> 制作 $DMG"
    local STAGE="$BUILD/dmg-$ARCH"
    rm -rf "$STAGE" "$DMG"
    mkdir -p "$STAGE"
    ditto "$APP" "$STAGE/TuneFree.app"
    ln -s /Applications "$STAGE/Applications"
    cp "$HERE/Support/使用说明.txt" "$STAGE/使用说明.txt"
    hdiutil create -quiet -volname "TuneFree" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG"
    rm -rf "$STAGE"
  fi
}

make_icon
for a in "${ARCHS[@]}"; do build_arch "$a"; done

echo
echo "完成："
for a in "${ARCHS[@]}"; do
  du -sh "$DIST/$a/TuneFree.app"
  [ "$MAKE_DMG" = 1 ] && du -sh "$DIST/TuneFree-$VERSION-$a.dmg"
done
true
