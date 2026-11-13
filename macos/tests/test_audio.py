# -*- coding: utf-8 -*-
"""标签回填与 ffmpeg 查找的测试。"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tunefree_backend import audio  # noqa: E402


class FilenameTagsTest(unittest.TestCase):
    def test_单歌手(self):
        self.assertEqual(audio.parse_filename_tags("许茹芸-泪海.mgg"),
                         {"artist": "许茹芸", "title": "泪海"})

    def test_多歌手(self):
        self.assertEqual(audio.parse_filename_tags("张震岳,蔡健雅-思念是一种病.mflac"),
                         {"artist": "张震岳,蔡健雅", "title": "思念是一种病"})

    def test_带空格的连字符(self):
        self.assertEqual(audio.parse_filename_tags("周杰伦 - 晴天.mp3"),
                         {"artist": "周杰伦", "title": "晴天"})

    def test_没有连字符时只当歌名(self):
        self.assertEqual(audio.parse_filename_tags("intro.flac"), {"title": "intro"})

    def test_空文件名(self):
        self.assertEqual(audio.parse_filename_tags(""), {})


class MergeTagsTest(unittest.TestCase):
    def test_缺失就补(self):
        merged = audio.merge_tags({}, "许茹芸-泪海.ogg")
        self.assertEqual(merged["title"], "泪海")
        self.assertEqual(merged["artist"], "许茹芸")

    def test_已有的不动(self):
        merged = audio.merge_tags({"title": "官方标题", "artist": "甲"}, "乙-别的名字.mgg")
        self.assertEqual(merged["title"], "官方标题")
        self.assertEqual(merged["artist"], "甲")

    def test_歌手信息更全时用文件名的(self):
        # QQ音乐部分 FLAC 只写了第一位歌手，文件名里是全的
        merged = audio.merge_tags({"title": "思念是一种病", "artist": "张震岳"},
                                  "张震岳,蔡健雅-思念是一种病.mflac")
        self.assertEqual(merged["artist"], "张震岳,蔡健雅")
        self.assertEqual(merged["title"], "思念是一种病")

    def test_不相干时不乱改(self):
        merged = audio.merge_tags({"artist": "某人"}, "别人-歌名.mgg")
        self.assertEqual(merged["artist"], "某人")


class FFmpegLookupTest(unittest.TestCase):
    def test_find_ffmpeg(self):
        path = audio.find_ffmpeg()
        if path is None:
            self.skipTest("本机没有 ffmpeg")
        self.assertTrue(os.access(path, os.X_OK))

    def test_环境变量优先(self):
        path = audio.find_ffmpeg()
        if not path:
            self.skipTest("本机没有 ffmpeg")
        old = os.environ.get("TUNEFREE_FFMPEG")
        os.environ["TUNEFREE_FFMPEG"] = path
        try:
            self.assertEqual(audio.find_ffmpeg(), path)
        finally:
            if old is None:
                os.environ.pop("TUNEFREE_FFMPEG", None)
            else:
                os.environ["TUNEFREE_FFMPEG"] = old

    def test_不存在的路径会被忽略(self):
        old = os.environ.get("TUNEFREE_FFMPEG")
        os.environ["TUNEFREE_FFMPEG"] = "/nonexistent/ffmpeg"
        try:
            self.assertNotEqual(audio.find_ffmpeg(), "/nonexistent/ffmpeg")
        finally:
            if old is None:
                os.environ.pop("TUNEFREE_FFMPEG", None)
            else:
                os.environ["TUNEFREE_FFMPEG"] = old


if __name__ == "__main__":
    unittest.main()
