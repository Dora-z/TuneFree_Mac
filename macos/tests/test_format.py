# -*- coding: utf-8 -*-
"""文件格式层测试：尾部识别、扩展名映射、落盘、错误提示。"""

import os
import shutil
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tunefree_backend import decrypt, qmc2, selftest, verify  # noqa: E402


def qtag_blob(audio_bytes, ekey, song_id="123"):
    meta = ("%s,%s,2" % (ekey, song_id)).encode("ascii")
    return audio_bytes + meta + struct.pack(">I", len(meta)) + b"QTag"


def v1_blob(audio_bytes, key):
    return audio_bytes + key + struct.pack("<I", len(key))


class FooterTest(unittest.TestCase):
    def test_qtag(self):
        blob = qtag_blob(b"OggS" + bytes(100), "AAA", song_id="8557419")
        footer = qmc2.detect_footer(blob)
        self.assertEqual(footer.kind, "qtag")
        self.assertEqual(footer.audio_len, 104)
        self.assertEqual(footer.song_id, "8557419")

    def test_v1(self):
        key = bytes(range(16))
        footer = qmc2.detect_footer(v1_blob(b"fLaC" + bytes(100), key))
        self.assertEqual(footer.kind, "v1")
        self.assertEqual(footer.key, key)
        self.assertEqual(footer.audio_len, 104)

    def test_musicex(self):
        meta = bytes(176)
        blob = b"OggS" + bytes(100) + meta + struct.pack("<II", 192, 1) + b"musicex\x00"
        footer = qmc2.detect_footer(blob)
        self.assertEqual(footer.kind, "musicex")
        self.assertEqual(footer.audio_len, 104)

    def test_认不出来(self):
        self.assertEqual(qmc2.detect_footer(b"\x00" * 64).kind, "unknown")


class ExtMapTest(unittest.TestCase):
    def test_映射(self):
        self.assertEqual(decrypt.output_extension("a.mflac"), "flac")
        self.assertEqual(decrypt.output_extension("A.MFLAC"), "flac")
        self.assertEqual(decrypt.output_extension("a.mgg"), "ogg")
        self.assertEqual(decrypt.output_extension("a.mflac0"), "flac")
        self.assertEqual(decrypt.output_extension("a.qmcflac"), "flac")
        self.assertEqual(decrypt.output_extension("a.qmc0"), "mp3")
        self.assertIsNone(decrypt.output_extension("a.txt"))

    def test_sniff(self):
        self.assertEqual(decrypt.sniff_plain_audio(b"fLaC....."), "flac")
        self.assertEqual(decrypt.sniff_plain_audio(b"OggS....."), "ogg")
        self.assertEqual(decrypt.sniff_plain_audio(b"ID3\x04...."), "mp3")
        self.assertEqual(decrypt.sniff_plain_audio(b"\xff\xfb\x90\x00"), "mp3")
        self.assertIsNone(decrypt.sniff_plain_audio(b"\x00\x01\x02\x03"))


class DecryptFileTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="tf-test-")

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def _write(self, name, data):
        path = os.path.join(self.dir, name)
        with open(path, "wb") as fh:
            fh.write(data)
        return path

    def test_qtag_端到端(self):
        payload = b"OggS" + bytes((i * 31) & 0xFF for i in range(50000))
        key = bytes((i * 17 + 3) & 0xFF for i in range(64))
        src = self._write("song.mgg", qtag_blob(qmc2.MapCipher(key).decrypt(payload),
                                                selftest._make_ekey(key)))
        dst = os.path.join(self.dir, "out", "song.ogg")
        info = decrypt.decrypt_file(src, dst)
        with open(dst, "rb") as fh:
            self.assertEqual(fh.read(), payload)
        self.assertEqual(info["kind"], "qtag")
        self.assertEqual(info["cipher"], "map")

    def test_v1_端到端(self):
        payload = b"fLaC" + bytes((i * 19) & 0xFF for i in range(30000))
        key = bytes((i * 11 + 1) & 0xFF for i in range(32))
        src = self._write("song.mflac", v1_blob(qmc2.MapCipher(key).decrypt(payload), key))
        dst = os.path.join(self.dir, "song.flac")
        decrypt.decrypt_file(src, dst)
        with open(dst, "rb") as fh:
            self.assertEqual(fh.read(), payload)

    def test_qmc1_端到端(self):
        from tunefree_backend import qmc1

        payload = b"fLaC" + bytes((i * 5) & 0xFF for i in range(30000))
        src = self._write("old.qmcflac", qmc1.Qmc1Cipher().decrypt(payload))
        dst = os.path.join(self.dir, "old.flac")
        info = decrypt.decrypt_file(src, dst)
        with open(dst, "rb") as fh:
            self.assertEqual(fh.read(), payload)
        self.assertEqual(info["kind"], "qmc1")

    def test_musicex_缺_ekey_报错清楚(self):
        meta = bytes(176)
        src = self._write("x.mgg", b"OggS" + bytes(400) + meta
                          + struct.pack("<II", 192, 1) + b"musicex\x00")
        # 单体测试不联网、不碰真实账号：显式关掉自动取密钥
        with self.assertRaises(decrypt.DecryptError) as ctx:
            decrypt.decrypt_file(src, os.path.join(self.dir, "x.ogg"), auto_ekey=False)
        self.assertIn("ekey", str(ctx.exception))
        self.assertEqual(ctx.exception.reason, "ekey")

    def test_密钥不对时不会写出坏文件(self):
        payload = b"OggS" + bytes(2000)
        good_key = bytes(range(32))
        src = self._write("bad.mgg", qtag_blob(qmc2.MapCipher(good_key).decrypt(payload),
                                               selftest._make_ekey(bytes(range(1, 33)))))
        dst = os.path.join(self.dir, "bad.ogg")
        with self.assertRaises(decrypt.DecryptError):
            decrypt.decrypt_file(src, dst)
        self.assertFalse(os.path.exists(dst))
        # 也不该留下临时文件
        leftovers = [n for n in os.listdir(self.dir) if n.startswith(".tunefree-")]
        self.assertEqual(leftovers, [])

    def test_空文件与超大文件(self):
        empty = self._write("e.mgg", b"")
        with self.assertRaises(decrypt.DecryptError) as ctx:
            decrypt.decrypt_file(empty, os.path.join(self.dir, "e.ogg"))
        self.assertEqual(ctx.exception.reason, "empty")

    def test_probe(self):
        key = bytes(range(16))
        src = self._write("p.mflac", v1_blob(b"fLaC" + bytes(100), key))
        info = decrypt.probe(src)
        self.assertEqual(info["kind"], "v1")
        self.assertEqual(info["format"], "flac")
        self.assertEqual(info["key_bytes"], 16)


class VerifyTest(unittest.TestCase):
    def test_假_ogg_会被识别为坏(self):
        self.assertFalse(verify.verify_ogg(b"OggS" + bytes(100))["ok"])

    def test_flac_streaminfo(self):
        # 手工拼一个 STREAMINFO：44.1k / 双声道 / 16bit
        packed = (44100 << 44) | (1 << 41) | (15 << 36) | 1000
        streaminfo = struct.pack(">HH", 4096, 4096) + b"\x00\x00\x00" + b"\x00\x00\x00" + struct.pack(">Q", packed)
        data = b"fLaC" + bytes(4) + streaminfo + b"\x00" * 100
        result = verify.verify_flac(data)
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["sample_rate"], 44100)
        self.assertEqual(result["channels"], 2)

    def test_mp3_帧头(self):
        self.assertTrue(verify.verify_mp3(b"\xff\xfb\x90\x00" + bytes(4096))["ok"])
        self.assertFalse(verify.verify_mp3(bytes(4096))["ok"])


if __name__ == "__main__":
    unittest.main()
