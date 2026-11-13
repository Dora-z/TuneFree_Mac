# -*- coding: utf-8 -*-
"""musicex 取密钥的测试：凭据解析、请求构造、接口响应处理。全部离线（假 urlopen）。"""
import io
import json
import os
import plistlib
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tunefree_backend import ekey, qmc2, decrypt  # noqa: E402


def make_prefs(authst="A" * 40, uin=123456, path=None):
    """造一份和 QQ音乐同结构的偏好设置（NSKeyedArchiver 编码的 AutoLoginUserInfo）。"""
    objects = [
        "$null",
        {
            "nLastUseQQ": uin,
            "nCurrUseId": uin,
            "userArray": plistlib.UID(2),
            "eState": 0,
            "$class": plistlib.UID(6),
        },
        {"NS.objects": [plistlib.UID(3)]},
        {
            "strAuthst": authst,
            "nUserId": uin,
            "strUserAccount": str(uin),
            "strOpenId": "DEADBEEF",
            "$class": plistlib.UID(5),
        },
        {"$classname": "UserInfo", "$classes": ["UserInfo", "NSObject"]},
        {"$classname": "UserInfo", "$classes": ["UserInfo", "NSObject"]},
        {"$classname": "AutoLogin", "$classes": ["AutoLogin", "NSObject"]},
    ]
    archive = {"$version": 100000, "$archiver": "NSKeyedArchiver",
               "$top": {"root": plistlib.UID(1)}, "$objects": objects}
    blob = plistlib.dumps(archive, fmt=plistlib.FMT_BINARY)
    prefs = {"AutoLoginUserInfo": blob}
    path = path or os.path.join(tempfile.mkdtemp(), "prefs.plist")
    with open(path, "wb") as fh:
        plistlib.dump(prefs, fh, fmt=plistlib.FMT_BINARY)
    return path


class FakeResponse(object):
    def __init__(self, payload):
        self._payload = payload

    def read(self):
        return self._payload

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


class CredentialsTest(unittest.TestCase):
    def test_解析_plist(self):
        path = make_prefs(authst="Q_H_L_" + "x" * 35, uin=123456789)
        creds = ekey.read_credentials_from_plist(path)
        self.assertIsNotNone(creds)
        self.assertEqual(creds.uin, "123456789")
        self.assertTrue(creds.authst.startswith("Q_H_L_"))

    def test_没有文件时返回_None(self):
        self.assertIsNone(ekey.read_credentials_from_plist("/nonexistent/prefs.plist"))

    def test_结构不对时返回_None(self):
        path = os.path.join(tempfile.mkdtemp(), "bad.plist")
        with open(path, "wb") as fh:
            plistlib.dump({"AutoLoginUserInfo": b"not a plist"}, fh)
        self.assertIsNone(ekey.read_credentials_from_plist(path))

    def test_显式参数优先(self):
        creds = ekey.get_credentials(explicit_authst="A" * 32, explicit_uin="9")
        self.assertEqual(creds.uin, "9")
        self.assertEqual(creds.authst, "A" * 32)
        self.assertEqual(creds.source, "命令行参数")

    def test_环境变量(self):
        with mock.patch.dict(os.environ,
                             {"TUNEFREE_QQMUSIC_AUTHST": "B" * 32, "TUNEFREE_QQMUSIC_UIN": "77"}):
            creds = ekey.get_credentials()
        self.assertEqual(creds.uin, "77")
        self.assertEqual(creds.source, "环境变量")

    def test_找不到凭据时报错清楚(self):
        with mock.patch.object(ekey, "read_credentials_from_plist", return_value=None), \
             mock.patch.object(ekey, "_read_live_prefs", return_value=None), \
             mock.patch.object(ekey, "_scan_files_for_authst", return_value=None), \
             mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(ekey.EkeyError) as ctx:
                ekey.get_credentials()
        self.assertIn("--authst", str(ctx.exception))

    def test_沙盒版容器里的偏好设置也能读(self):
        root = tempfile.mkdtemp()
        normal = os.path.join(root, "Preferences", "com.tencent.QQMusicMac.plist")      # 不存在
        sandboxed = make_prefs(authst="Q_H_L_" + "y" * 35, uin=42)
        with mock.patch.object(ekey, "prefs_candidates", return_value=[normal, sandboxed]), \
             mock.patch.dict(os.environ, {}, clear=True):
            creds = ekey.get_credentials()
        self.assertEqual(creds.uin, "42")

    def test_报错里列出查过的位置和原因(self):
        root = tempfile.mkdtemp()
        no_login = os.path.join(root, "com.tencent.QQMusicMac.plist")
        with open(no_login, "wb") as fh:
            plistlib.dump({"SomethingElse": 1}, fh)
        missing = os.path.join(root, "nope.plist")
        with mock.patch.object(ekey, "prefs_candidates", return_value=[missing, no_login]), \
             mock.patch.object(ekey, "_read_live_prefs", return_value=None), \
             mock.patch.object(ekey, "_scan_files_for_authst", return_value=None), \
             mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(ekey.EkeyError) as ctx:
                ekey.get_credentials()
        message = str(ctx.exception)
        self.assertIn("nope.plist：不存在", message)
        self.assertIn("没有自动登录信息", message)
        self.assertIn("自动登录", message)


class RequestTest(unittest.TestCase):
    def test_请求体结构(self):
        body = ekey.build_request("123456789", "AUTHST", "F0M0002f41HR41fvDE.mflac", "003ilXfl3EWxcV")
        self.assertEqual(body["comm"]["authst"], "AUTHST")
        self.assertEqual(body["comm"]["uin"], "123456789")
        self.assertEqual(body["comm"]["ct"], "19")
        self.assertEqual(body["comm"]["tmeLoginType"], "3")
        req = body["req_1"]
        self.assertEqual(req["module"], "music.vkey.GetEVkey")
        self.assertEqual(req["method"], "CgiGetEVkey")
        self.assertEqual(req["param"]["filename"], ["F0M0002f41HR41fvDE.mflac"])
        self.assertEqual(req["param"]["songmid"], ["003ilXfl3EWxcV"])
        self.assertEqual(req["param"]["songtype"], [1])
        self.assertEqual(req["param"]["loginflag"], 1)
        self.assertEqual(req["param"]["platform"], "20")

    def test_正常响应(self):
        payload = json.dumps({
            "req_1": {"code": 0, "data": {"midurlinfo": [{"result": 0, "ekey": "E" * 704}]}}
        }).encode()
        with mock.patch("urllib.request.urlopen", return_value=FakeResponse(payload)):
            got = ekey.fetch_ekey(ekey.Credentials("1", "A" * 32), "x.mgg", "003abc")
        self.assertEqual(got, "E" * 704)

    def test_业务失败要有明确报错(self):
        payload = json.dumps({
            "req_1": {"code": 0, "data": {"midurlinfo": [{"result": 100, "ekey": ""}]}}
        }).encode()
        with mock.patch("urllib.request.urlopen", return_value=FakeResponse(payload)):
            with self.assertRaises(ekey.EkeyError) as ctx:
                ekey.fetch_ekey(ekey.Credentials("1", "A" * 32), "x.mgg", "003abc")
        self.assertIn("result=100", str(ctx.exception))

    def test_登录过期要有提示(self):
        payload = json.dumps({"req_1": {"code": 1000, "data": {}}}).encode()
        with mock.patch("urllib.request.urlopen", return_value=FakeResponse(payload)):
            with self.assertRaises(ekey.EkeyError) as ctx:
                ekey.fetch_ekey(ekey.Credentials("1", "A" * 32), "x.mgg", "003abc")
        self.assertIn("code=1000", str(ctx.exception))

    def test_网络不通(self):
        import urllib.error

        with mock.patch("urllib.request.urlopen",
                        side_effect=urllib.error.URLError("offline")):
            with self.assertRaises(ekey.EkeyError) as ctx:
                ekey.fetch_ekey(ekey.Credentials("1", "A" * 32), "x.mgg", "003abc")
        self.assertIn("y.qq.com", str(ctx.exception))


class MusicexWithoutEkeyTest(unittest.TestCase):
    def test_关掉自动取密钥时给出_ekey_原因(self):
        import struct

        meta = bytes(176)
        blob = b"OggS" + bytes(200) + meta + struct.pack("<II", 192, 1) + b"musicex\x00"
        path = os.path.join(tempfile.mkdtemp(), "x.mgg")
        with open(path, "wb") as fh:
            fh.write(blob)
        with self.assertRaises(decrypt.DecryptError) as ctx:
            decrypt.decrypt_bytes(path, auto_ekey=False)
        self.assertEqual(ctx.exception.reason, "ekey")
        self.assertIn("ekey", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
