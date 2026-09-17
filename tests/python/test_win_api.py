#!/usr/bin/env python3
# coding=utf-8
"""win_api 单元测试（跨平台可跑）。"""

from __future__ import annotations

import os
import struct
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "scripts", "win"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import win_api  # noqa: E402
from fake_win_api import FakeWin32Api  # noqa: E402


def has_numpy() -> bool:
    import importlib.util
    return importlib.util.find_spec("numpy") is not None


class HwndIntTest(unittest.TestCase):
    def test_accepts_both_int_and_pointer(self):
        import ctypes as _ctypes

        self.assertEqual(win_api.hwnd_int(0x1000), 0x1000)
        self.assertEqual(win_api.hwnd_int(_ctypes.c_void_p(0x1000)), 0x1000)
        self.assertEqual(win_api.hwnd_int(_ctypes.c_void_p(None)), 0)


class LParamTest(unittest.TestCase):
    def test_pack_unpack(self):
        for x, y in ((0, 0), (800, 450), (1599, 899), (10, 2000)):
            lparam = win_api.lparam_point(x, y)
            self.assertEqual(lparam & 0xFFFF, x)
            self.assertEqual((lparam >> 16) & 0xFFFF, y)


class AnalyzeTest(unittest.TestCase):
    def test_black_and_colorful(self):
        black = win_api.analyze_bgra(bytes(16 * 16 * 4), 16, 16)
        self.assertTrue(black["valid"])
        self.assertEqual(black["black_ratio"], 1.0)

        buf = FakeWin32Api.GOOD_PATTERN * (16 * 16 * 4 // 32 + 1)
        good = win_api.analyze_bgra(buf[:16 * 16 * 4], 16, 16)
        self.assertEqual(good["black_ratio"], 0.0)
        self.assertGreaterEqual(good["distinct_colors_sampled"], 6)

    def test_invalid_buffer(self):
        result = win_api.analyze_bgra(None, 10, 10)
        self.assertFalse(result["valid"])
        self.assertEqual(result["black_ratio"], 1.0)


class NumpyTest(unittest.TestCase):
    def test_bgra_to_bgr(self):
        if not has_numpy():
            self.skipTest("未安装 numpy")
        # BGRA 缓冲区取前 3 通道即为 OpenCV 需要的 BGR 顺序，不应做通道交换
        buf = bytes([1, 2, 3, 255]) * (4 * 4)
        image = win_api.bgra_to_bgr_numpy(buf, 4, 4)
        self.assertEqual(image.shape, (4, 4, 3))
        self.assertEqual(tuple(int(v) for v in image[0, 0]), (1, 2, 3))

    def test_bad_length(self):
        self.assertIsNone(win_api.bgra_to_bgr_numpy(b"\x00", 4, 4))


class BmpTest(unittest.TestCase):
    def test_round_trip(self):
        width, height = 4, 3
        buf = bytearray(width * height * 4)
        expected = {}
        for y in range(height):
            for x in range(width):
                color = (x * 40 % 256, y * 80 % 256, 200)
                expected[(x, y)] = color
                off = (y * width + x) * 4
                buf[off:off + 4] = bytes([color[2], color[1], color[0], 255])
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "sub", "shot.bmp")
            self.assertTrue(win_api.save_bgra_bmp(path, bytes(buf), width, height))
            with open(path, "rb") as fh:
                raw = fh.read()
        self.assertEqual(raw[:2], b"BM")
        info = struct.unpack("<IiiHHIIiiII", raw[14:54])
        self.assertEqual((info[1], info[2], info[4]), (width, height, 24))
        row_size = ((width * 3 + 3) // 4) * 4
        offset = 54
        for file_row in range(height):
            y = height - 1 - file_row
            row = raw[offset:offset + row_size]
            offset += row_size
            for x in range(width):
                rgb = (row[x * 3 + 2], row[x * 3 + 1], row[x * 3])
                self.assertEqual(rgb, expected[(x, y)])

    def test_invalid_input(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertFalse(win_api.save_bgra_bmp(os.path.join(tmp, "x.bmp"), b"", 4, 4))


class GeometryTest(unittest.TestCase):
    def test_scale_point(self):
        self.assertEqual(win_api.scale_point(800, 450, (1600, 900), (1600, 900)), (800, 450))
        self.assertEqual(win_api.scale_point(800, 450, (1600, 900), (800, 450)), (400, 225))
        self.assertEqual(win_api.scale_point(0, 0, (1600, 900), (3200, 1800)), (0, 0))
        self.assertEqual(win_api.scale_point(1600, 900, (1600, 900), (800, 450)), (800, 450))

    def test_clamp_point(self):
        self.assertEqual(win_api.clamp_point(-5, -5, (100, 100)), (1, 1))
        self.assertEqual(win_api.clamp_point(500, 500, (100, 100)), (98, 98))
        self.assertEqual(win_api.clamp_point(50, 50, (100, 100)), (50, 50))


class ApiInjectionTest(unittest.TestCase):
    def test_non_windows_raises(self):
        if win_api.IS_WINDOWS:
            self.skipTest("Windows 上不做该断言")
        win_api.set_api(None)
        with self.assertRaises(RuntimeError):
            win_api.api()

    def test_set_api(self):
        fake = FakeWin32Api()
        win_api.set_api(fake)
        self.assertIs(win_api.api(), fake)
        win_api.set_api(None)


if __name__ == "__main__":
    unittest.main()
