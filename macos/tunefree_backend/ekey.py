# -*- coding: utf-8 -*-
"""musicex 布局的 ekey 自动获取。

新版客户端下载的 `.mflac` / `.mgg` 尾部只有元数据（song_id / media_mid / 资源名），
密钥不在文件里 —— 它由服务端按「账号 + 这首歌」临时下发，对应接口是
``music.vkey.GetEVkey``（module=CgiGetEVkey）。

macOS 上账号凭据就在 QQ音乐自己的偏好设置里（``AutoLoginUserInfo``，一个
NSKeyedArchiver 编码的 plist，里面存着 ``strAuthst`` 和 UIN），所以不需要注入、
不需要抓包：读出来直接调接口即可。用完即弃，不落盘。

只对「本机已下载、且下载它的账号已登录」的文件有效。
"""
from __future__ import annotations

import json
import os
import plistlib
import sys
import urllib.error
import urllib.request

API_URL = "https://u.y.qq.com/cgi-bin/musicu.fcg"
USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"
PLATFORM = "20"          # 20 = macOS 客户端，27 = Windows PC
REFERER = "https://y.qq.com/"

PREFS_PATH = os.path.expanduser("~/Library/Preferences/com.tencent.QQMusicMac.plist")
CONTAINER = os.path.expanduser(
    "~/Library/Containers/com.tencent.QQMusicMac/Data"
    "/Library/Application Support/QQMusicMac"
)

_CACHE = {}


class EkeyError(Exception):
    """取不到 ekey（未登录 / 凭据过期 / 接口拒绝）。"""


class Credentials(object):
    __slots__ = ("uin", "authst", "source")

    def __init__(self, uin, authst, source=""):
        self.uin = str(uin)
        self.authst = authst
        self.source = source

    def __repr__(self):
        return "Credentials(uin=%s, authst=%s…, source=%s)" % (
            self.uin, self.authst[:12], self.source)


# --------------------------------------------------------- 凭据读取 ----

def _resolve_objects(info):
    """把 NSKeyedArchiver 的 $objects 解析成普通 Python 结构（只跟一层 UID）。"""
    objects = info.get("$objects", [])

    def resolve(value, depth=0):
        # NSKeyedArchiver 的引用嵌套不深（root → userArray → UserInfo → 字段），
        # 但 UID 和外层容器各算一层，上限留宽一点。
        if depth > 16:
            return None
        if isinstance(value, plistlib.UID):
            index = value.data
            if 0 <= index < len(objects):
                return resolve(objects[index], depth + 1)
            return None
        if isinstance(value, dict):
            return {k: resolve(v, depth + 1) for k, v in value.items() if k != "$class"}
        if isinstance(value, list):
            return [resolve(v, depth + 1) for v in value]
        return value

    return resolve(info.get("$top", {}).get("root"))


def _walk_dicts(node):
    if isinstance(node, dict):
        yield node
        for value in node.values():
            for item in _walk_dicts(value):
                yield item
    elif isinstance(node, list):
        for value in node:
            for item in _walk_dicts(value):
                yield item


def read_credentials_from_plist(path=PREFS_PATH):
    """从 QQ音乐偏好设置里读出 uin / authst。"""
    if not os.path.isfile(path):
        return None

    try:
        with open(path, "rb") as fh:
            prefs = plistlib.load(fh)
    except Exception:
        return None

    blob = prefs.get("AutoLoginUserInfo")
    if not blob:
        return None

    try:
        archive = plistlib.loads(bytes(blob))
        root = _resolve_objects(archive)
    except Exception:
        return None

    candidates = []
    for node in _walk_dicts(root):
        authst = node.get("strAuthst")
        if not isinstance(authst, str) or len(authst) < 16:
            continue
        uin = node.get("nUserId") or node.get("strUserAccount") or ""
        candidates.append((str(uin), authst))

    if not candidates:
        return None
    uin, authst = candidates[0]
    return Credentials(uin, authst, source=os.path.basename(path))


def _scan_files_for_authst():
    """兜底：在 App 容器里找形如 "authst":"..." 的明文（部分版本会落一份）。"""
    if not os.path.isdir(CONTAINER):
        return None
    needles = (b'"authst":"', b'"authst": "')
    for root, _dirs, files in os.walk(CONTAINER):
        if "iMusic" in root or "iRRCache" in root or "iLog" in root:
            continue
        for name in files:
            if not name.endswith((".dat", ".plist", ".json", ".data", ".db")):
                continue
            path = os.path.join(root, name)
            try:
                if os.path.getsize(path) > 8 * 1024 * 1024:
                    continue
                with open(path, "rb") as fh:
                    data = fh.read()
            except OSError:
                continue
            for needle in needles:
                index = data.find(needle)
                while index >= 0:
                    start = index + len(needle)
                    end = data.find(b'"', start)
                    if end > start:
                        value = data[start:end].decode("ascii", "ignore")
                        if len(value) >= 24 and all(
                                c.isalnum() or c in "-_=+/" for c in value):
                            uin = _guess_uin(data)
                            return Credentials(uin, value, source=name)
                    index = data.find(needle, end if end > 0 else start)
    return None


def _guess_uin(data):
    marker = b'"uin":"'
    index = data.find(marker)
    if index >= 0:
        start = index + len(marker)
        end = data.find(b'"', start)
        if end > start:
            return data[start:end].decode("ascii", "ignore")
    return ""


def get_credentials(explicit_authst=None, explicit_uin=None):
    """凭据来源优先级：显式传入 > 环境变量 > 偏好设置 > 容器明文扫描。"""
    if explicit_authst:
        return Credentials(explicit_uin or "", explicit_authst, source="命令行参数")

    env_authst = os.environ.get("TUNEFREE_QQMUSIC_AUTHST")
    if env_authst:
        return Credentials(os.environ.get("TUNEFREE_QQMUSIC_UIN", ""), env_authst,
                           source="环境变量")

    creds = read_credentials_from_plist()
    if creds:
        return creds

    creds = _scan_files_for_authst()
    if creds:
        return creds

    raise EkeyError(
        "没有找到 QQ音乐的登录凭据。请：\n"
        "  1) 打开 QQ音乐并保持登录（读的是它的本地登录态，不需要注入）\n"
        "  2) 或者手动指定：--authst <authst> --uin <uin>\n"
        "  3) 或者直接给某个文件的 ekey：--ekey <base64>"
    )


# ------------------------------------------------------------ 接口 ----

def build_request(uin, authst, filename, songmid):
    return {
        "comm": {
            "authst": authst,
            "ct": "19",
            "cv": "1859",
            "uin": str(uin),
            "tmeLoginType": "3",
        },
        "req_1": {
            "module": "music.vkey.GetEVkey",
            "method": "CgiGetEVkey",
            "param": {
                "filename": [filename],
                "guid": "10000",
                "songmid": [songmid],
                "songtype": [1],
                "uin": str(uin),
                "loginflag": 1,
                "platform": PLATFORM,
                "ctx": 1,
            },
        },
    }


def fetch_ekey(credentials, filename, songmid, timeout=15):
    """调 GetEVkey 拿 ekey。filename 要带扩展名（.mgg / .mflac）。"""
    body = json.dumps(build_request(credentials.uin, credentials.authst, filename, songmid),
                      ensure_ascii=False).encode("utf-8")
    request = urllib.request.Request(
        API_URL,
        data=body,
        headers={
            "Content-Type": "application/json",
            "User-Agent": USER_AGENT,
            "Referer": REFERER,
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = response.read()
    except urllib.error.HTTPError as exc:
        raise EkeyError("GetEVkey 接口返回 HTTP %s" % exc.code)
    except urllib.error.URLError as exc:
        raise EkeyError("连不上 y.qq.com：%s" % exc.reason)

    try:
        data = json.loads(payload.decode("utf-8", "replace"))
    except ValueError:
        raise EkeyError("接口返回的不是 JSON：%r" % payload[:120])

    req = data.get("req_1") or {}
    code = req.get("code")
    if code not in (0, None):
        raise EkeyError("GetEVkey 请求失败（code=%s）" % code)

    midurlinfo = ((req.get("data") or {}).get("midurlinfo") or [])
    if not midurlinfo:
        raise EkeyError("接口没有返回 midurlinfo（凭据多半已过期，重开一次 QQ音乐再试）")

    item = midurlinfo[0]
    result = item.get("result", -1)
    ekey = item.get("ekey") or ""
    if result not in (0, None) or not ekey:
        raise EkeyError(
            "接口没有下发 ekey（result=%s）。常见原因：账号登录态过期、这首歌没下载过、"
            "或者下载时用的音质不在 EVkey 支持范围内" % result
        )
    return ekey


def ekey_for_footer(footer, credentials=None, explicit_authst=None, explicit_uin=None):
    """给 musicex 尾部取 ekey（带进程内缓存）。"""
    mid = getattr(footer, "mid", "") or ""
    filename = getattr(footer, "filename", "") or ""
    if not mid or not filename:
        raise EkeyError("musicex 尾部里没有 media_mid 或资源名，没法取 ekey")

    creds = credentials or get_credentials(explicit_authst, explicit_uin)
    cache_key = (creds.uin, mid, filename)
    if cache_key in _CACHE:
        return _CACHE[cache_key]

    ekey = fetch_ekey(creds, filename, mid)
    _CACHE[cache_key] = ekey
    return ekey


def supported():
    return sys.platform == "darwin"
