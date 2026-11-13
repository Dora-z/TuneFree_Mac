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
import glob
import plistlib
import subprocess
import sys
import urllib.error
import urllib.request

API_URL = "https://u.y.qq.com/cgi-bin/musicu.fcg"
USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"
PLATFORM = "20"          # 20 = macOS 客户端，27 = Windows PC
REFERER = "https://y.qq.com/"

DOMAIN = "com.tencent.QQMusicMac"
PREFS_PATH = os.path.expanduser("~/Library/Preferences/%s.plist" % DOMAIN)
CONTAINER_ROOT = os.path.expanduser("~/Library/Containers/%s/Data" % DOMAIN)
# 沙盒版（Mac App Store 装的）QQ音乐，偏好设置在自己的容器里，而不是 ~/Library/Preferences
CONTAINER_PREFS = os.path.join(CONTAINER_ROOT, "Library", "Preferences", "%s.plist" % DOMAIN)
CONTAINER = os.path.join(CONTAINER_ROOT, "Library", "Application Support", "QQMusicMac")

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


def _short(path):
    home = os.path.expanduser("~")
    return "~" + path[len(home):] if path.startswith(home) else path


def prefs_candidates():
    """QQ音乐可能放偏好设置的位置：普通版、沙盒版容器、其他渠道的 domain 名。"""
    paths = [PREFS_PATH, CONTAINER_PREFS]
    patterns = (
        os.path.join(CONTAINER_ROOT, "Library", "Preferences", "*.plist"),
        os.path.expanduser("~/Library/Preferences/com.tencent.QQMusic*.plist"),
        os.path.expanduser("~/Library/Containers/com.tencent.QQMusic*/Data/Library/Preferences/*.plist"),
        os.path.expanduser("~/Library/Group Containers/*QQMusic*/Library/Preferences/*.plist"),
    )
    for pattern in patterns:
        for path in sorted(glob.glob(pattern)):
            if path not in paths and "tencent" in path.lower():
                paths.append(path)
    return paths


def _creds_from_prefs(prefs, source):
    """从偏好设置字典里取凭据，返回 (Credentials 或 None, 状态说明)。"""
    blob = prefs.get("AutoLoginUserInfo")
    if not blob:
        return None, "没有自动登录信息（没登录，或没勾选「自动登录」）"
    try:
        archive = plistlib.loads(bytes(blob))
        root = _resolve_objects(archive)
    except Exception:
        return None, "自动登录信息格式不认识（QQ音乐版本可能变了）"

    candidates = []
    for node in _walk_dicts(root):
        authst = node.get("strAuthst")
        if not isinstance(authst, str) or len(authst) < 16:
            continue
        uin = node.get("nUserId") or node.get("strUserAccount") or ""
        candidates.append((str(uin), authst))

    if not candidates:
        return None, "有自动登录信息，但里面没有登录凭据（authst）"
    uin, authst = candidates[0]
    return Credentials(uin, authst, source=source), "找到了"


def read_credentials_from_plist(path=PREFS_PATH, report=None):
    """从 QQ音乐偏好设置文件里读出 uin / authst；report 是列表时把检查结果追加进去。"""
    def note(status):
        if report is not None:
            report.append((_short(path), status))

    if not os.path.isfile(path):
        note("不存在")
        return None
    try:
        with open(path, "rb") as fh:
            prefs = plistlib.load(fh)
    except PermissionError:
        note("没有权限读取（系统设置 → 隐私与安全性 → 完全磁盘访问权限 里允许 TuneFree）")
        return None
    except Exception:
        note("读不了")
        return None
    creds, status = _creds_from_prefs(prefs, os.path.basename(path))
    note(status)
    return creds


def _read_live_prefs(report=None):
    """通过 defaults 读 QQ音乐当前的偏好设置（刚登录、还没写回磁盘时文件里可能没有）。"""
    try:
        proc = subprocess.run(["/usr/bin/defaults", "export", DOMAIN, "-"], capture_output=True,
                              timeout=5, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0 or not proc.stdout:
        if report is not None:
            report.append(("defaults %s" % DOMAIN, "没有这个偏好设置域"))
        return None
    try:
        prefs = plistlib.loads(proc.stdout)
    except Exception:
        return None
    creds, status = _creds_from_prefs(prefs, "defaults %s" % DOMAIN)
    if report is not None:
        report.append(("defaults %s" % DOMAIN, status))
    return creds


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

    report = []
    for path in prefs_candidates():
        creds = read_credentials_from_plist(path, report)
        if creds:
            return creds

    creds = _read_live_prefs(report)
    if creds:
        return creds

    creds = _scan_files_for_authst()
    if creds:
        return creds

    raise EkeyError(missing_credentials_message(report))


def missing_credentials_message(report):
    checked = "\n".join("     · %s：%s" % (where, status) for where, status in report)
    installed = os.path.isdir(CONTAINER_ROOT) or os.path.isfile(PREFS_PATH)
    first = ("打开 QQ音乐，登录下载这些歌的那个账号，并勾选「自动登录」；然后退出 QQ音乐再重试"
             if installed else "这台 Mac 上好像没装过 QQ音乐：musicex 格式的歌只能在下载它的那台 Mac 上解")
    return (
        "没有找到 QQ音乐的登录凭据（新版 QQ音乐下载的 musicex 格式，密钥要用登录态去取）。\n"
        "  查过的位置：\n%s\n"
        "  请：\n"
        "  1) %s\n"
        "  2) 或者手动指定：--authst <authst> --uin <uin>\n"
        "  3) 或者直接给某个文件的 ekey：--ekey <base64>" % (checked or "     · （无）", first)
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
