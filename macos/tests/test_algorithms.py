# -*- coding: utf-8 -*-
"""算法层测试：TC-TEA / QMC2 Map & RC4 / QMC1 掩码流。

期望值来自公开参考实现的官方测试向量，不是自己跟自己比。
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tunefree_backend import qmc1, qmc2, tea  # noqa: E402


class TeaTest(unittest.TestCase):
    def test_官方_ekey_向量(self):
        ekey = "VGhpcyBpcyBHFWEh4cjZ1Vi7rJ56XeoPlqGM1sxBGPg7mt89umKclFBr9iqfmFdS"
        self.assertEqual(qmc2.parse_ekey(ekey), b"This is a test key for test purpose :D")

    def test_simple_key_常量(self):
        self.assertEqual(tea.SIMPLE_KEY_106.hex(), "695646382b20150b")

    def test_derive_tea_key(self):
        header = bytes([0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8])
        self.assertEqual(
            tea.derive_tea_key(header),
            bytes([0x69, 0xF1, 0x56, 0xF2, 0x46, 0xF3, 0x38, 0xF4,
                   0x2B, 0xF5, 0x20, 0xF6, 0x15, 0xF7, 0x0B, 0xF8]),
        )

    def test_加解密闭环(self):
        key = tea.derive_tea_key(b"12345678")
        for payload in (b"x", b"hello", b"\x00" * 64, bytes(range(1, 200))):
            self.assertEqual(tea.decrypt(tea.encrypt(payload, key), key), payload)

    def test_长度非法时返回_None(self):
        key = tea.derive_tea_key(b"12345678")
        self.assertIsNone(tea.decrypt(b"", key))
        self.assertIsNone(tea.decrypt(b"123", key))
        self.assertIsNone(tea.decrypt(b"x" * 16, b"short"))


class Qmc2MapTest(unittest.TestCase):
    KEY = bytes(range(0x41, 0x51))

    def test_偏移_0_向量(self):
        got = list(qmc2.MapCipher(self.KEY).decrypt(bytes(16), 0))
        self.assertEqual(
            got,
            [0x3F, 0x8A, 0xC1, 0x49, 0x3F, 0x49, 0xC1, 0x8A,
             0x3F, 0x8A, 0xC1, 0x49, 0x3F, 0x49, 0xC1, 0x8A],
        )

    def test_0x7fff_边界向量(self):
        got = list(qmc2.MapCipher(self.KEY).decrypt(bytes(16), 0x7FFF - 8))
        self.assertEqual(
            got,
            [0x8A, 0x3F, 0x8A, 0xC1, 0x49, 0x3F, 0x49, 0xC1,
             0x8A, 0x8A, 0xC1, 0x49, 0x3F, 0x49, 0xC1, 0x8A],
        )

    def test_边界那一字节用_0x7fff_自身(self):
        """文档里踩过的坑：0x7FFF 不能按取模算成 0。"""
        cipher = qmc2.MapCipher(self.KEY)
        self.assertEqual(cipher.mask_at(0x7FFF), cipher.mask_at(0x7FFF))
        self.assertNotEqual(cipher.mask_at(0x7FFF), cipher.mask_at(0))
        # 0x8000 起回到取模
        self.assertEqual(cipher.mask_at(0x8000), cipher.mask_at(1))

    def test_分段与整段一致(self):
        cipher = qmc2.MapCipher(bytes(range(1, 60)))
        payload = bytes((i * 37 + 11) & 0xFF for i in range(120000))
        whole = cipher.decrypt(payload)
        chunked = b"".join(cipher.decrypt(payload[i:i + 4096], offset=i)
                           for i in range(0, len(payload), 4096))
        self.assertEqual(whole, chunked)
        self.assertEqual(cipher.decrypt(whole), payload)

    def test_空数据(self):
        self.assertEqual(qmc2.MapCipher(self.KEY).decrypt(b""), b"")


class Qmc2Rc4Test(unittest.TestCase):
    def test_首段向量(self):
        key = bytes(range(255))
        got = list(qmc2.Rc4Cipher(key).decrypt(bytes(16), 0))
        self.assertEqual(got, [0, 50, 16, 8, 5, 3, 2, 1, 1, 1, 0, 0, 0, 0, 0, 0])

    def test_hash_base(self):
        self.assertEqual(qmc2._hash_base([1, 99]), 1)
        self.assertEqual(qmc2._hash_base(bytes([0xFF] * 16)), 0xFC05FC01)

    def test_超过分段长度仍然可逆(self):
        key = bytes((i * 7 + 1) & 0xFF for i in range(320))
        cipher = qmc2.Rc4Cipher(key)
        payload = bytes((i * 13 + 7) & 0xFF for i in range(200000))
        self.assertEqual(cipher.decrypt(cipher.decrypt(payload)), payload)

    def test_切片密钥流等于逐字节参考实现(self):
        # 快速实现把各分段的密钥流从一条基础流里切出来；这里逐字节按参考算法重算一遍对照
        key = bytes(((i * 131 + 17) ^ (i >> 3)) & 0xFF for i in range(704))
        cipher = qmc2.Rc4Cipher(key)
        n = len(key)

        def reference(offset, length):
            out = bytearray()
            for o in range(offset, offset + length):
                if o < qmc2.RC4_FIRST:
                    out.append(key[cipher._segment_key(o, key[o % n]) % n])
                    continue
                seg = o // qmc2.RC4_SEGMENT
                skip = (cipher._segment_key(seg, key[seg & 0x1FF]) & 0x1FF) + o % qmc2.RC4_SEGMENT
                box = bytearray(cipher._box)
                j = k = 0
                for _ in range(skip + 1):
                    j = (j + 1) % n
                    k = (box[j] + k) % n
                    box[j], box[k] = box[k], box[j]
                out.append(box[(box[j] + box[k]) % n])
            return bytes(out)

        for offset, length in [(0, 200), (120, 20), (5110, 20), (0x1400 * 37 + 5, 30)]:
            self.assertEqual(cipher.keystream(length, offset), reference(offset, length), (offset, length))

    def test_按长度选密码(self):
        self.assertIsInstance(qmc2.make_cipher(b"\x00" * 300), qmc2.MapCipher)
        self.assertIsInstance(qmc2.make_cipher(b"\x00" * 301), qmc2.Rc4Cipher)


class Qmc1Test(unittest.TestCase):
    def test_掩码流头部(self):
        # c3 之后是表按之字形走：4a d6 ca 90 67 f7 52，越界后 0xd8 掉头
        self.assertEqual(qmc1.mask_stream(9).hex(), "c34ad6ca9067f752d8")

    def test_往返(self):
        cipher = qmc1.Qmc1Cipher()
        payload = bytes((i * 7 + 3) & 0xFF for i in range(100000))
        self.assertEqual(cipher.decrypt(cipher.decrypt(payload)), payload)

    def test_缓存不会串位(self):
        short = qmc1.mask_stream(100)
        long = qmc1.mask_stream(1000)
        self.assertEqual(long[:100], short)


if __name__ == "__main__":
    unittest.main()
