# -*- coding: utf-8 -*-
"""解密后末尾多余字节的裁剪：多出来的才裁，完整 / 截断的文件不动。"""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tunefree_backend import audio, trim  # noqa: E402

FFMPEG = audio.find_ffmpeg()


def make(codec_args, suffix, seconds=3):
    root = tempfile.mkdtemp()
    path = os.path.join(root, "a" + suffix)
    subprocess.run([FFMPEG, "-hide_banner", "-nostdin", "-v", "quiet", "-y", "-f", "lavfi",
                    "-i", "sine=frequency=440:duration=%d" % seconds] + codec_args + [path],
                   check=True, stdin=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    with open(path, "rb") as fh:
        data = fh.read()
    shutil.rmtree(root, True)
    return data


@unittest.skipIf(FFMPEG is None, "本机没有 ffmpeg")
class FlacTrimTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.flac = make(["-c:a", "flac", "-sample_fmt", "s32", "-ar", "44100"], ".flac")

    def test_完整文件不动(self):
        self.assertIsNone(trim.audio_end(self.flac, "flac"))

    def test_末尾多出的字节会被裁掉(self):
        for junk in (b"\x00" * 15, bytes(range(30)), b"\xff\xf0" * 9, b"\x00\x00\x07junk"):
            self.assertEqual(trim.audio_end(self.flac + junk, "flac"), len(self.flac))

    def test_最后一帧不完整时不动(self):
        self.assertIsNone(trim.audio_end(self.flac[:-7], "flac"))

    def test_不是FLAC不动(self):
        self.assertIsNone(trim.audio_end(b"ID3" + b"\x00" * 100, "flac"))


@unittest.skipIf(FFMPEG is None, "本机没有 ffmpeg")
class OggTrimTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        try:
            cls.ogg = make(["-c:a", "libvorbis"], ".ogg")
        except subprocess.CalledProcessError:
            cls.ogg = make(["-c:a", "vorbis", "-strict", "-2", "-ac", "2"], ".ogg")

    def test_完整文件不动(self):
        self.assertIsNone(trim.audio_end(self.ogg, "ogg"))

    def test_末尾多出的字节会被裁掉(self):
        self.assertEqual(trim.audio_end(self.ogg + b"junk-bytes-after-last-page", "ogg"), len(self.ogg))


if __name__ == "__main__":
    unittest.main()
