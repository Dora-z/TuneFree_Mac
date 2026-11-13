# -*- coding: utf-8 -*-
"""标签：源文件解析（FLAC / OGG）、联网结果的校验、USLT 歌词帧、完整写入流程（网络用假数据）。"""
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tunefree_backend import Options, audio, id3, job, meta, qmc2, selftest, tags  # noqa: E402

FFMPEG = audio.find_ffmpeg()


def ffmpeg(*args):
    subprocess.run([FFMPEG, "-hide_banner", "-nostdin", "-v", "quiet", "-y"] + list(args),
                   check=True, stdin=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def vorbis_comment(entries, vendor=b"test"):
    body = struct.pack("<I", len(vendor)) + vendor + struct.pack("<I", len(entries))
    for entry in entries:
        raw = entry.encode("utf-8")
        body += struct.pack("<I", len(raw)) + raw
    return body


class FlacParseTest(unittest.TestCase):
    def _flac(self, entries, rate=44100, samples=44100 * 3):
        info = bytearray(34)
        info[10] = (rate >> 12) & 0xFF
        info[11] = (rate >> 4) & 0xFF
        info[12] = ((rate & 0x0F) << 4) | (1 << 1)
        info[13] = (15 << 4) | ((samples >> 32) & 0x0F)
        info[14:18] = (samples & 0xFFFFFFFF).to_bytes(4, "big")
        comment = vorbis_comment(entries)
        data = b"fLaC" + bytes([0]) + len(info).to_bytes(3, "big") + bytes(info)
        data += bytes([0x80 | 4]) + len(comment).to_bytes(3, "big") + comment
        fd, path = tempfile.mkstemp(suffix=".flac")
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
        self.addCleanup(os.unlink, path)
        return path

    def test_标签与时长(self):
        path = self._flac(["TITLE=思念是一种病", "ARTIST=张震岳", "ARTIST=蔡健雅", "ALBUM=OK",
                           "TRACKNUMBER=1/12", "DATE=2007"])
        info = tags.read_source(path)
        self.assertEqual(info.tags["title"], "思念是一种病")
        self.assertEqual(info.tags["artist"], "张震岳/蔡健雅")
        self.assertEqual(info.tags["album"], "OK")
        self.assertEqual(info.tags["track"], "1")
        self.assertAlmostEqual(info.duration, 3.0, places=3)

    def test_不认识的文件(self):
        fd, path = tempfile.mkstemp()
        with os.fdopen(fd, "wb") as fh:
            fh.write(b"not audio")
        self.addCleanup(os.unlink, path)
        self.assertEqual(tags.read_source(path).tags, {})


@unittest.skipIf(FFMPEG is None, "本机没有 ffmpeg")
class OggParseTest(unittest.TestCase):
    def test_流级别标签与私有字段(self):
        root = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, root, True)
        path = os.path.join(root, "a.ogg")
        meta_args = ["-metadata:s:a:0", "TITLE=泪海", "-metadata:s:a:0", "ALBUM=泪海",
                     "-metadata:s:a:0", "endgran=123"]
        for codec in (["-c:a", "libvorbis"], ["-c:a", "vorbis", "-strict", "-2", "-ac", "2"]):
            try:
                ffmpeg("-f", "lavfi", "-i", "sine=duration=2", *(codec + meta_args + [path]))
                break
            except subprocess.CalledProcessError:
                continue
        else:
            self.skipTest("ffmpeg 没有 Vorbis 编码器")
        info = tags.read_source(path)
        self.assertEqual(info.tags.get("title"), "泪海")
        self.assertEqual(info.tags.get("album"), "泪海")
        self.assertNotIn("endgran", info.tags)
        self.assertAlmostEqual(info.duration, 2.0, delta=0.1)


class MatchTest(unittest.TestCase):
    def _meta(self, title, artists, duration=200.0, by="song_id"):
        return meta.TrackMeta(title=title, artists=artists, duration=duration, matched_by=by)

    def test_歌名歌手时长都对上(self):
        hints = meta.Hints(title="思念是一种病", artist="张震岳,蔡健雅", duration=201.0)
        self.assertTrue(meta.plausible(self._meta("思念是一种病", ["张震岳", "蔡健雅"]), hints))

    def test_括号版本号不影响(self):
        hints = meta.Hints(title="泪海 (Live)", artist="许茹芸", duration=200)
        self.assertTrue(meta.plausible(self._meta("泪海", ["许茹芸"]), hints))

    def test_歌名不对就不用(self):
        hints = meta.Hints(title="测试曲目 01", duration=200)
        self.assertFalse(meta.plausible(self._meta("别的歌", ["某人"]), hints))

    def test_歌手不对就不用(self):
        hints = meta.Hints(title="晴天", artist="周杰伦", duration=200)
        self.assertFalse(meta.plausible(self._meta("晴天", ["翻唱歌手"]), hints))

    def test_时长差太多就不用(self):
        hints = meta.Hints(title="晴天", artist="周杰伦", duration=100)
        self.assertFalse(meta.plausible(self._meta("晴天", ["周杰伦"], duration=269), hints))

    def test_没有歌名线索只信song_id加时长(self):
        self.assertTrue(meta.plausible(self._meta("X", ["Y"], 200), meta.Hints(duration=201)))
        self.assertFalse(meta.plausible(self._meta("X", ["Y"], 200, by="search"), meta.Hints(duration=201)))
        self.assertFalse(meta.plausible(self._meta("X", ["Y"], 200), meta.Hints()))

    def test_解析详情与歌词(self):
        data = {"track_info": {"id": 1, "mid": "m", "name": "泪海", "singer": [{"name": "许茹芸"}],
                               "album": {"mid": "A1", "name": "泪海"}, "time_public": "1996-03-28",
                               "index_album": 1, "index_cd": 0, "interval": 298},
                "info": {"genre": {"title": "歌曲流派", "content": [{"value": "Pop"}]}}}
        m = meta.parse_detail(data)
        self.assertEqual((m.title, m.artist, m.album, m.year, m.track, m.genre, m.duration),
                         ("泪海", "许茹芸", "泪海", "1996", 1, "Pop", 298.0))
        self.assertIsNone(m.disc)
        import base64
        lrc = "[ti:泪海]\n[00:01.00]第一句\n[00:02.50]第二句"
        self.assertEqual(meta.parse_lyric({"lyric": base64.b64encode(lrc.encode()).decode()}), lrc)
        self.assertEqual(meta.lrc_to_text(lrc), "第一句\n第二句")
        pure = "[00:00.00]此歌曲为没有填词的纯音乐，请您欣赏"
        self.assertEqual(meta.parse_lyric({"lyric": base64.b64encode(pure.encode()).decode()}), "")


class FakeClient(object):
    """假的联网结果：任何 song_id 都返回同一首歌 + 一张本地封面。"""

    available = True
    cover_path = None

    def __init__(self, *args, **kwargs):
        pass

    def resolve(self, hints):
        if not hints.song_id:
            return None
        found = meta.TrackMeta(song_id=hints.song_id, title="示例歌名", artists=["歌手甲", "歌手乙"],
                               album="示例专辑", album_mid="ALB", date="2001-05-01", track=3,
                               genre="Pop", duration=hints.duration, matched_by="song_id",
                               lyrics="[00:01.00]第一句\n[00:02.00]第二句")
        return found

    def cover(self, album_mid):
        return FakeClient.cover_path


@unittest.skipIf(FFMPEG is None, "本机没有 ffmpeg")
class WriteTagsTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="tf-tags-")
        self.addCleanup(shutil.rmtree, self.root, True)
        self.in_dir = os.path.join(self.root, "in")
        os.makedirs(self.in_dir)
        FakeClient.cover_path = os.path.join(self.root, "cover.jpg")
        ffmpeg("-f", "lavfi", "-i", "color=c=red:s=64x64", "-frames:v", "1", FakeClient.cover_path)
        flac = os.path.join(self.root, "src.flac")
        ffmpeg("-f", "lavfi", "-i", "sine=duration=2", "-c:a", "flac", "-metadata", "TITLE=示例歌名", flac)
        with open(flac, "rb") as fh:
            plain = fh.read()
        key = bytes((i * 13 + 5) & 0xFF for i in range(64))
        enc = qmc2.MapCipher(key).decrypt(plain)
        blob = enc + selftest._make_ekey(key).encode("ascii") + b",4242,2"
        blob += struct.pack(">I", len(blob) - len(enc)) + b"QTag"
        with open(os.path.join(self.in_dir, "歌手甲-示例歌名.mflac"), "wb") as fh:
            fh.write(blob)
        self._real = job.meta_mod.Client
        job.meta_mod.Client = FakeClient
        self.addCleanup(setattr, job.meta_mod, "Client", self._real)

    def test_MP3_标签封面歌词_FLAC_也补(self):
        events = []
        opts = Options(input_dir=self.in_dir, bitrate="128k", keep_flac=True, write_lrc=True)
        result = job.Job(opts, on_file=events.append).run()
        self.assertTrue(result.ok)
        mp3 = os.path.join(opts.mp3_dir, "歌手甲-示例歌名.mp3")
        frames = id3.read_frames(mp3)
        for fid in ("TIT2", "TPE1", "TALB", "TYER", "TRCK", "TCON", "APIC", "USLT"):
            self.assertIn(fid, frames)
        self.assertEqual(id3.read_uslt(mp3), "第一句\n第二句")
        self.assertTrue(os.path.isfile(os.path.join(opts.mp3_dir, "歌手甲-示例歌名.lrc")))
        tag_events = [e for e in events if e["event"] == "tags"]
        self.assertEqual(len(tag_events), 1)
        self.assertTrue(tag_events[0]["online"])
        self.assertEqual(tag_events[0]["artist"], "歌手甲/歌手乙")
        flac = tags.read_source(os.path.join(opts.flac_dir, "歌手甲-示例歌名.flac"))
        self.assertEqual(flac.tags.get("album"), "示例专辑")
        self.assertTrue(flac.has_picture)
        self.assertIn("第一句", flac.tags.get("lyrics", ""))

    def test_关掉联网就只用本地标签(self):
        events = []
        opts = Options(input_dir=self.in_dir, bitrate="128k", online_tags=False)
        job.Job(opts, on_file=events.append).run()
        mp3 = os.path.join(opts.mp3_dir, "歌手甲-示例歌名.mp3")
        frames = id3.read_frames(mp3)
        self.assertIn("TPE1", frames)          # 文件名补的歌手
        self.assertNotIn("APIC", frames)
        self.assertNotIn("TALB", frames)
        self.assertFalse([e for e in events if e["event"] == "tags"][0]["online"])


class Id3Test(unittest.TestCase):
    def test_重复写歌词不叠加(self):
        body = b"TIT2" + struct.pack(">I", 3) + b"\x00\x00" + b"\x00ab" + b"\x00" * 20
        size = len(body)
        header = b"ID3\x03\x00\x00" + bytes([(size >> 21) & 0x7F, (size >> 14) & 0x7F, (size >> 7) & 0x7F, size & 0x7F])
        fd, path = tempfile.mkstemp(suffix=".mp3")
        with os.fdopen(fd, "wb") as fh:
            fh.write(header + body + b"\xff\xfbAUDIO")
        self.addCleanup(os.unlink, path)
        id3.add_lyrics(path, "一")
        id3.add_lyrics(path, "二")
        self.assertEqual(id3.read_frames(path).count("USLT"), 1)
        self.assertEqual(id3.read_uslt(path), "二")
        with open(path, "rb") as fh:
            self.assertTrue(fh.read().endswith(b"\xff\xfbAUDIO"))


if __name__ == "__main__":
    unittest.main()
