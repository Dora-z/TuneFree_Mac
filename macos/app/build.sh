#!/bin/bash
# 打出一个「双击就能用」的 TuneFree.app：SwiftUI 界面 + 内置 Python 运行时 + 内置 ffmpeg。
# 用户机器上什么都不用装（不需要 Python、不需要 Homebrew、不需要 QQ音乐在运行）。
#
#   bash app/build.sh                  # 产物：dist/TuneFree.app 与 dist/TuneFree-<版本>-<架构>.dmg
#   bash app/build.sh --no-dmg         # 只要 .app
#   bash app/build.sh --reuse-backend  # 复用 dist/TuneFreeBackend，不重新跑 PyInstaller
#
# 只需要 Xcode 命令行工具（xcode-select --install），不需要完整 Xcode。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"          # macos/
cd "$ROOT"

MAKE_DMG=1
REUSE_BACKEND=0
for arg in "$@"; do
  case "$arg" in
    --no-dmg) MAKE_DMG=0 ;;
    --reuse-backend) REUSE_BACKEND=1 ;;
    *) echo "未知参数：$arg"; exit 2 ;;
  esac
done

VERSION="$(python3 -c 'import sys; sys.path.insert(0,"."); from tunefree_backend import VERSION; print(VERSION)')"
SHORT_VERSION="${VERSION%%-*}"
ARCH="${ARCH:-$(uname -m)}"
BUILD="$ROOT/.build"
VENV="$BUILD/venv"
DIST="$ROOT/dist"
BACKEND="$DIST/TuneFreeBackend"
APP="$DIST/TuneFree.app"

echo "==> TuneFree ${VERSION}（${ARCH}）"

# ------------------------------------------------------------ 1) 后端 ----
if [ "$REUSE_BACKEND" = 1 ] && [ -x "$BACKEND/TuneFreeBackend" ]; then
  echo "==> 复用已有后端：$BACKEND"
else
  echo "==> 打包 Python 后端（PyInstaller，内置运行时）"
  if [ ! -x "$VENV/bin/python" ]; then
    ${BUILD_PYTHON:-/usr/bin/python3} -m venv "$VENV"
  fi
  "$VENV/bin/python" -m pip install -q --upgrade pip
  "$VENV/bin/python" -m pip install -q pyinstaller imageio-ffmpeg
  rm -rf "$BUILD/pyi" "$BACKEND"
  "$VENV/bin/python" -m PyInstaller \
    --noconfirm --clean --onedir --console \
    --name TuneFreeBackend \
    --paths "$ROOT" \
    --distpath "$DIST" \
    --workpath "$BUILD/pyi" \
    --specpath "$BUILD" \
    --exclude-module tkinter --exclude-module unittest --exclude-module pydoc \
    --exclude-module imageio_ffmpeg --exclude-module imageio --exclude-module numpy \
    --log-level WARN \
    main.py

  echo "==> 内置 ffmpeg"
  FFMPEG_SRC="$("$VENV/bin/python" -c 'import imageio_ffmpeg; print(imageio_ffmpeg.get_ffmpeg_exe())')"
  cp "$FFMPEG_SRC" "$BACKEND/ffmpeg"
  chmod +x "$BACKEND/ffmpeg"
fi
[ -x "$BACKEND/ffmpeg" ] || { echo "✗ 后端里没有 ffmpeg"; exit 1; }

# ------------------------------------------------------------ 2) 界面 ----
# 新版 SDK 里 SwiftUI 的 @State 变成了宏，宏插件只随完整 Xcode 提供。
# 只有命令行工具时，从新到旧试编一小段代码，挑第一个能编过的 SDK。
if [ -z "${SDKROOT:-}" ]; then
  PROBE="$BUILD/sdkprobe.swift"
  mkdir -p "$BUILD"
  cat > "$PROBE" <<'SWIFT'
import SwiftUI
struct P: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View { configuration.label.onHover { hover = $0 } }
}
SWIFT
  for sdk in "" $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.sdk /Applications/Xcode*.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX[0-9]*.sdk 2>/dev/null | sort -rV); do
    if [ -z "$sdk" ]; then
      xcrun swiftc -typecheck -target "$ARCH-apple-macos14.0" "$PROBE" >/dev/null 2>&1 && break
    elif SDKROOT="$sdk" xcrun swiftc -typecheck -sdk "$sdk" -target "$ARCH-apple-macos14.0" "$PROBE" >/dev/null 2>&1; then
      export SDKROOT="$sdk"
      break
    fi
  done
fi
[ -n "${SDKROOT:-}" ] && echo "==> SDK：$SDKROOT"

echo "==> 编译 SwiftUI 界面"
( cd "$HERE" && swift build -c release --arch "$ARCH" 2>&1 | grep -vE "^\[|^Building|^Compiling|^Write" || true )
BIN="$HERE/.build/$ARCH-apple-macosx/release/TuneFree"
[ -x "$BIN" ] || BIN="$HERE/.build/release/TuneFree"
[ -x "$BIN" ] || { echo "✗ 界面编译失败"; exit 1; }

# ------------------------------------------------------------ 3) 图标 ----
echo "==> 生成图标"
ICONWORK="$BUILD/icon"
rm -rf "$ICONWORK" && mkdir -p "$ICONWORK/AppIcon.iconset"
swift "$HERE/Support/make_icon.swift" "$ICONWORK/icon_1024.png" >/dev/null
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICONWORK/icon_1024.png" --out "$ICONWORK/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$ICONWORK/icon_1024.png" --out "$ICONWORK/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONWORK/AppIcon.iconset" -o "$ICONWORK/AppIcon.icns"

# ------------------------------------------------------------ 4) 组装 ----
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

# ------------------------------------------------------------ 5) 签名 ----
# 没有开发者证书就做 ad-hoc 签名（Apple 芯片要求每个可执行文件都有签名）。
# 有证书时：CODESIGN_ID="Developer ID Application: xxx" bash app/build.sh
SIGN_ID="${CODESIGN_ID:--}"
SIGN_OPTS=(--force --timestamp=none -s "$SIGN_ID")
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

# ------------------------------------------------------------ 6) 自检 ----
echo "==> 包内自检"
SELFTEST="$("$APP/Contents/Resources/TuneFreeBackend/TuneFreeBackend" --selftest 2>&1)" || { echo "$SELFTEST" | tail -20; echo "✗ 包内自检失败"; exit 1; }
echo "$SELFTEST" | tail -3

# ------------------------------------------------------------ 7) DMG ----
if [ "$MAKE_DMG" = 1 ]; then
  DMG="$DIST/TuneFree-$VERSION-$ARCH.dmg"
  echo "==> 制作 $DMG"
  STAGE="$BUILD/dmg"
  rm -rf "$STAGE" "$DMG"
  mkdir -p "$STAGE"
  ditto "$APP" "$STAGE/TuneFree.app"
  ln -s /Applications "$STAGE/Applications"
  [ -f "$ROOT/ship/使用说明.txt" ] && cp "$ROOT/ship/使用说明.txt" "$STAGE/使用说明.txt"
  hdiutil create -quiet -volname "TuneFree" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG"
  rm -rf "$STAGE"
fi

echo
echo "完成："
du -sh "$APP"
[ "$MAKE_DMG" = 1 ] && du -sh "$DIST/TuneFree-$VERSION-$ARCH.dmg"
echo "打开：open \"$APP\""
