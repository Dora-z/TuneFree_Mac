# -*- coding: utf-8 -*-
"""流水线测试：真 FLAC（ffmpeg 生成）→ 加密成 .mflac → Job 跑完整流程 → 校验 MP3。

覆盖：解密、转码、跳过已存在、--keep-flac、--no-mp3、--force、取消、进度回调。
"""
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tunefree_backend import Options, audio, job, qmc2, selftest, verify  # noqa: E402

FFMPEG = audio.find_ffmpeg()


def make_flac(seconds=2, rate=44100):
    """用 ffmpeg 生成一段真 FLAC（440Hz 正弦波）。"""
    fd, path = tempfile.mkstemp(suffix=".flac")
    os.close(fd)
    cmd = [FFMPEG, "-hide_banner", "-nostdin", "-v", "error", "-y",
           "-f", "lavfi", "-i", "sine=frequency=440:duration=%d:sample_rate=%d" % (seconds, rate),
           "-c:a", "flac", path]
    subprocess.run(cmd, check=True, stdin=subprocess.DEVNULL)
    return path


class OfflineClient(object):
    """测试不联网：联网补全一律「没查到」。"""

    available = True

    def __init__(self, *args, **kwargs):
        pass

    def resolve(self, hints):
        return None

    def cover(self, album_mid):
        return None


@unittest.skipIf(FFMPEG is None, "本机没有 ffmpeg")
class PipelineTest(unittest.TestCase):
    def setUp(self):
        self._real_client = job.meta_mod.Client
        job.meta_mod.Client = OfflineClient
        self.addCleanup(setattr, job.meta_mod, "Client", self._real_client)
        self.root = tempfile.mkdtemp(prefix="tf-flow-")
        self.in_dir = os.path.join(self.root, "in")
        os.makedirs(self.in_dir)
        self.flac = make_flac()
        with open(self.flac, "rb") as fh:
            self.palin = fh.read()
        self.key = bytes((i * 13 + 5) & 0xFF for i in range(64))

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)
        try:
            os.unlink(self.flac)
        except OSError:
            pass

    def _encrypt_into(self, name, payload=None):
        payload = payload if payload is not None else self.palin
        enc = qmc2.MapCipher(self.key).decrypt(payload)
        blob = enc + selftest._make_ekey(self.key).encode("ascii") + b",123,2"
        blob = blob + struct.pack(">I", len(blob) - len(enc)) + b"QTag"
        path = os.path.join(self.in_dir, name)
        with open(path, "wb") as fh:
            fh.write(blob)
        return path

    def test_完整流程(self):
        self._encrypt_into("曲目 A.mflac")
        opts = Options(input_dir=self.in_dir, bitrate="128k")
        logs, progress = [], []
        task = job.Job(opts, on_log=lambda lvl, msg: logs.append((lvl, msg)),
                       on_progress=progress.append)
        result = task.run()

        self.assertTrue(result.ok, result.to_dict())
        self.assertEqual(result.files_found, 1)
        self.assertEqual(result.decrypted, 1)
        self.assertEqual(result.mp3_ok, 1)

        mp3 = os.path.join(opts.mp3_dir, "曲目 A.mp3")
        self.assertTrue(os.path.exists(mp3), os.listdir(opts.mp3_dir))
        self.assertTrue(verify.verify_file(mp3)["ok"])
        # 默认不保留 FLAC
        self.assertFalse(os.path.exists(os.path.join(opts.flac_dir, "曲目 A.flac")))
        # 进度相位
        self.assertEqual({p.phase for p in progress}, {"解密", "转码"})

    def test_keep_flac(self):
        self._encrypt_into("b.mflac")
        opts = Options(input_dir=self.in_dir, keep_flac=True, bitrate="128k")
        job.run(opts)
        self.assertTrue(os.path.exists(os.path.join(opts.flac_dir, "b.flac")))
        self.assertTrue(os.path.exists(os.path.join(opts.mp3_dir, "b.mp3")))
        self.assertTrue(verify.verify_file(os.path.join(opts.flac_dir, "b.flac"))["ok"])

    def test_no_mp3_只解不转(self):
        self._encrypt_into("c.mflac")
        opts = Options(input_dir=self.in_dir, no_mp3=True)
        result = job.run(opts)
        self.assertEqual(result.decrypted, 1)
        self.assertTrue(os.path.exists(os.path.join(opts.flac_dir, "c.flac")))
        self.assertFalse(os.path.exists(os.path.join(opts.mp3_dir, "c.mp3")))

    def test_二次运行全部跳过(self):
        self._encrypt_into("d.mflac")
        opts = Options(input_dir=self.in_dir, keep_flac=True, bitrate="128k")
        job.run(opts)
        again = job.run(opts)
        self.assertEqual(again.decrypt_skipped, 1)
        self.assertEqual(again.decrypted, 0)
        self.assertEqual(again.mp3_skipped, 1)

    def test_force_重新生成(self):
        self._encrypt_into("e.mflac")
        opts = Options(input_dir=self.in_dir, keep_flac=True, bitrate="128k")
        job.run(opts)
        again = job.run(Options(input_dir=self.in_dir, keep_flac=True, bitrate="128k", force=True))
        self.assertEqual(again.decrypt_skipped, 0)
        self.assertEqual(again.decrypted, 1)
        self.assertEqual(again.mp3_ok, 1)

    def test_坏文件不影响好文件(self):
        self._encrypt_into("good.mflac")
        with open(os.path.join(self.in_dir, "broken.mflac"), "wb") as fh:
            fh.write(b"\x00" * 300)   # 尾部认不出来
        result = job.run(Options(input_dir=self.in_dir, bitrate="128k"))
        self.assertEqual(result.decrypted, 1)
        self.assertEqual(result.decrypt_failed, 1)
        self.assertTrue(any(e.stage == "decrypt" for e in result.errors))

    def test_取消(self):
        self._encrypt_into("f.mflac")
        opts = Options(input_dir=self.in_dir, bitrate="128k")
        task = job.Job(opts)
        task.cancel()
        result = task.run()
        self.assertTrue(result.cancelled)
        self.assertFalse(result.ok)

    def test_并发转码(self):
        for i in range(4):
            self._encrypt_into("p%d.mflac" % i)
        opts = Options(input_dir=self.in_dir, bitrate="128k", jobs=4, keep_flac=True)
        result = job.run(opts)
        self.assertEqual(result.decrypted, 4)
        self.assertEqual(result.mp3_ok, 4)
        for i in range(4):
            self.assertTrue(verify.verify_file(os.path.join(opts.mp3_dir, "p%d.mp3" % i))["ok"])

    def test_空目录(self):
        result = job.run(Options(input_dir=self.in_dir))
        self.assertEqual(result.files_found, 0)
        self.assertFalse(result.ok)


if __name__ == "__main__":
    unittest.main()
