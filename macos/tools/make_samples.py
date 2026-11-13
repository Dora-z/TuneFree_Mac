#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""造一批「像真的一样」的加密样本来调试前端。

没有真实的 .mflac/.mgg 时，用真实的 FLAC/OGG（ffmpeg 现生成）按 QMC2 的
三种尾部布局加密回去，得到能跑通完整流水线的样本。生成出来的文件
用本仓库后端解出来的就是原音频，可以拿来校验界面、进度条、错误提示。

    python tools/make_samples.py --out /tmp/tf-samples --count 3
"""
from __future__ import annotations

import argparse
import os
import struct
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tunefree_backend import audio, qmc1, qmc2, selftest  # noqa: E402


# 不同 ffmpeg 构建带的编码器不一样：优先 libvorbis，退到原生 vorbis，再退到 opus
VORBIS_VARIANTS = [
    ["-c:a", "libvorbis", "-q:a", "5"],
    ["-c:a", "vorbis", "-strict", "-2", "-q:a", "5"],
    ["-c:a", "libopus", "-b:a", "128k"],
]


def make_audio(ffmpeg, out_path, seconds, codec, freq=440):
    """生成一段真实音频；vorbis 编码器缺失时返回 False。"""
    base = [ffmpeg, "-hide_banner", "-nostdin", "-v", "error", "-y",
            "-f", "lavfi", "-i", "sine=frequency=%d:duration=%s" % (freq, seconds), "-ac", "2"]
    variants = [["-c:a", "flac"]] if codec == "flac" else VORBIS_VARIANTS
    last = None
    for args in variants:
        last = subprocess.run(base + args + [out_path],
                              capture_output=True, text=True,
                              encoding="utf-8", errors="ignore",
                              stdin=subprocess.DEVNULL)
        if last.returncode == 0:
            return True
    if last is not None and last.stderr.strip():
        print("  ! %s 生成失败：%s" % (os.path.basename(out_path), last.stderr.strip().splitlines()[-1]))
    return False


def write_qtag(path, payload, key, song_id):
    """QTag + EncV2 双层 ekey（新下载的文件基本都是这个）。"""
    ekey = selftest._make_ekey(key, encv2=True)
    meta = ("%s,%s,2" % (ekey, song_id)).encode("ascii")
    blob = qmc2.make_cipher(key).decrypt(payload) + meta + struct.pack(">I", len(meta)) + b"QTag"
    with open(path, "wb") as fh:
        fh.write(blob)


def write_v1(path, payload, key):
    """V1：裸 key 放尾部（老版本客户端）。"""
    blob = qmc2.make_cipher(key).decrypt(payload) + key + struct.pack("<I", len(key))
    with open(path, "wb") as fh:
        fh.write(blob)


def write_qmc1(path, payload):
    with open(path, "wb") as fh:
        fh.write(qmc1.Qmc1Cipher().decrypt(payload))


def main(argv=None):
    parser = argparse.ArgumentParser(description="生成 TuneFree 加密样本")
    parser.add_argument("--out", default="samples", help="输出目录（默认 samples）")
    parser.add_argument("--count", type=int, default=3, help="每种布局生成几个（默认 3）")
    parser.add_argument("--seconds", default="3", help="每个样本的音频时长（默认 3 秒）")
    args = parser.parse_args(argv)

    ffmpeg = audio.require_ffmpeg()
    out = os.path.abspath(os.path.expanduser(args.out))
    os.makedirs(out, exist_ok=True)
    tmp = os.path.join(out, ".tmp")
    os.makedirs(tmp, exist_ok=True)

    made = []
    for i in range(max(1, args.count)):
        song_id = str(8550000 + i)
        key = bytes(((n * 17 + i * 7 + 3) & 0xFF) for n in range(64))

        flat = os.path.join(tmp, "s%d.flac" % i)
        make_audio(ffmpeg, flat, args.seconds, "flac", freq=330 + i * 110)
        with open(flat, "rb") as fh:
            payload = fh.read()

        qtag = os.path.join(out, "测试曲目 %02d.mflac" % (i + 1))
        write_qtag(qtag, payload, key, song_id)
        made.append(qtag)

        v1 = os.path.join(out, "老版本曲目 %02d.mflac" % (i + 1))
        write_v1(v1, payload, key[:32])
        made.append(v1)

        old = os.path.join(out, "旧格式曲目 %02d.qmcflac" % (i + 1))
        write_qmc1(old, payload)
        made.append(old)

        if i == 0:  # 再给一个 OGG 的样本（编码器不全时跳过）
            ogg = os.path.join(tmp, "s%d.ogg" % i)
            if make_audio(ffmpeg, ogg, args.seconds, "vorbis", freq=880):
                with open(ogg, "rb") as fh:
                    ogg_payload = fh.read()
                mgg = os.path.join(out, "OGG 样本.mgg")
                write_qtag(mgg, ogg_payload, key, song_id)
                made.append(mgg)

        # 一个 musicex 样本（不带密钥，用来验证「提示用户要 ekey」的界面分支）
        if i == 0:
            meta = bytes(176)
            blob = payload + meta + struct.pack("<II", 192, 1) + b"musicex\x00"
            musicex = os.path.join(out, "需要 ekey 的样本.mgg")
            with open(musicex, "wb") as fh:
                fh.write(blob)
            made.append(musicex)

    for path in sorted(os.listdir(tmp)):
        try:
            os.unlink(os.path.join(tmp, path))
        except OSError:
            pass
    os.rmdir(tmp)

    print("生成 %d 个样本到 %s：" % (len(made), out))
    for path in made:
        print("  %s（%d 字节）" % (os.path.basename(path), os.path.getsize(path)))
    print("\n试跑：python main.py -i %r -o %r --verify" % (out, os.path.join(out, "_out")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
