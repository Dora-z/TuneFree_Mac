#!/bin/bash
# TuneFree —— 双击运行。文件夹选择用系统对话框，不需要开终端敲命令。
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR" || exit 1

BIN="$DIR/TuneFreeBackend/TuneFreeBackend"
[ -x "$BIN" ] || BIN="$DIR/TuneFreeBackend.app/Contents/MacOS/TuneFreeBackend"

say() { printf '%s\n' "$*"; }
die() { say ""; say "✗ $*"; say ""; read -r -p "按回车关闭…" _; exit 1; }

# 从网上下载并解压后，系统会给文件打隔离标记；这里自己清掉，省得用户手动处理
for target in "$BIN" "$DIR/TuneFreeBackend" "$0"; do
  [ -e "$target" ] && xattr -d com.apple.quarantine "$target" 2>/dev/null
done
[ -d "$DIR/TuneFreeBackend" ] && xattr -dr com.apple.quarantine "$DIR/TuneFreeBackend" 2>/dev/null

# 架构不对时 PyInstaller 的二进制只会报一句 "cannot execute binary file"，这里提前说清楚
if [ -x "$BIN" ] && command -v lipo >/dev/null 2>&1; then
  HAVE="$(lipo -archs "$BIN" 2>/dev/null)"
  WANT="$(uname -m)"
  case "$HAVE" in
    *" $WANT"*|"$WANT") : ;;
    "") : ;;
    *) HAVE_MSG="${HAVE}"; die "这个包是给 ${HAVE_MSG} 的，你的 Mac 是 ${WANT}。
请让对方用你的架构重新打包，或者换一个对应架构的版本。" ;;
  esac
fi

[ -x "$BIN" ] || die "找不到主程序：$BIN
这个文件夹可能没解压完整，请重新解压一次。"

pick_folder() {  # $1=提示语  $2=默认位置
  osascript -e "POSIX path of (choose folder with prompt \"$1\" default location POSIX file \"$2\")" 2>/dev/null
}

IN="${TUNEFREE_IN:-}"
if [ -z "$IN" ]; then
  # 默认位置给到 QQ音乐的缓存目录，省得用户到处找
  DEFAULT="$HOME/Library/Containers/com.tencent.QQMusicMac/Data/Library/Application Support/QQMusicMac/iQmc"
  [ -d "$DEFAULT" ] || DEFAULT="$HOME/Music"
  IN="$(pick_folder "第 1 步：选择放着 .mflac / .mgg 的文件夹" "$DEFAULT")"
  [ -n "$IN" ] || { say "已取消。"; exit 0; }
  IN="${IN%/}"
fi

OUT="${TUNEFREE_OUT:-}"
if [ -z "$OUT" ]; then
  OUT="$(pick_folder "第 2 步：选择导出到哪个文件夹" "$HOME/Music")"
  [ -n "$OUT" ] || { say "已取消。"; exit 0; }
  OUT="${OUT%/}"
fi

RATE="${TUNEFREE_BITRATE:-}"
if [ -z "$RATE" ]; then
  RATE="$(osascript -e 'choose from list {"320k（推荐）", "192k（体积小）", "128k（更小）"} with prompt "第 3 步：MP3 音质" default items {"320k（推荐）"}' 2>/dev/null)"
  [ -n "$RATE" ] || { say "已取消。"; exit 0; }
  RATE="${RATE%%（*}"
fi

KEEP="${TUNEFREE_KEEP:-}"
if [ -z "$KEEP" ]; then
  KEEP="$(osascript -e 'choose from list {"只留 MP3", "MP3 + 无损 FLAC"} with prompt "第 4 步：要不要保留无损原文件？" default items {"只留 MP3"}' 2>/dev/null)"
  [ -n "$KEEP" ] || { say "已取消。"; exit 0; }
fi

ARGS=(-i "$IN" -o "$OUT" -b "$RATE" --verify)
[ "$KEEP" = "MP3 + 无损 FLAC" ] && ARGS+=(--keep-flac)

say ""
say "────────────────────────────────────────────"
say " 输入：$IN"
say " 输出：$OUT"
say " 音质：$RATE    $KEEP"
say "────────────────────────────────────────────"
say ""

"$BIN" "${ARGS[@]}"
CODE=$?

say ""
if [ $CODE -eq 0 ]; then
  say "✓ 完成，正在打开输出文件夹…"
  [ -d "$OUT/mp3" ] && open "$OUT/mp3"
else
  say "⚠ 没有全部成功（退出码 $CODE）。上面带 ERROR 的行是原因。"
  [ -d "$OUT/mp3" ] && open "$OUT/mp3"
fi
say ""
read -r -p "按回车关闭窗口…" _
