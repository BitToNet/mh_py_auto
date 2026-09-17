#!/usr/bin/env python3
# coding=utf-8
"""截图层单元测试：后端择优、缓存、降级、归一化。"""

from __future__ import annotations

import os
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "scripts", "win"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import win_capture  # noqa: E402
from fake_win_api import FakeWin32Api  # noqa: E402


class CaptureBackendTest(unittest.TestCase):
    def setUp(self):
        self.fake = FakeWin32Api()
        self.hwnd = 0x1000
        self.fake.add_game_window(self.hwnd, 1111, client_width=1600, client_height=900)

    def test_specific_method(self):
        result = win_capture.capture_bgra(self.hwnd, "printwindow_renderfull", api=self.fake)
        self.assertIsNotNone(result)
        self.assertEqual(result.size, (1600, 900))
        self.assertEqual(result.metrics["black_ratio"], 0.0)
        self.assertTrue(result.ok)

    def test_black_backend_detected(self):
        result = win_capture.capture_bgra(self.hwnd, "bitblt_client", api=self.fake)
        self.assertIsNotNone(result)
        self.assertEqual(result.metrics["black_ratio"], 1.0)

    def test_unknown_method(self):
        with self.assertRaises(ValueError):
            win_capture.capture_bgra(self.hwnd, "nope", api=self.fake)

    def test_missing_window(self):
        self.assertIsNone(win_capture.capture_bgra(0x9999, "printwindow_client", api=self.fake))


class ProbeTest(unittest.TestCase):
    def test_probe_reports_every_method(self):
        fake = FakeWin32Api()
        hwnd = 0x1000
        fake.add_game_window(hwnd, 1111)
        report = win_capture.probe_methods(hwnd, api=fake)
        self.assertEqual(len(report), len(win_capture.DEFAULT_ORDER))
        by_name = {item["method"]: item for item in report}
        self.assertTrue(by_name["printwindow_renderfull"]["ok"])
        # 能拿到画面但内容是黑屏：ok=True 且 black_ratio=1.0
        self.assertTrue(by_name["bitblt_client"]["ok"])
        self.assertEqual(by_name["bitblt_client"]["metrics"]["black_ratio"], 1.0)

    def test_probe_black_mode(self):
        fake = FakeWin32Api()
        hwnd = 0x1000
        fake.add_game_window(hwnd, 1111)
        fake.capture_mode = "black"
        report = win_capture.probe_methods(hwnd, order=("printwindow_renderfull",), api=fake)
        self.assertEqual(report[0]["metrics"]["black_ratio"], 1.0)


class StrategyTest(unittest.TestCase):
    def setUp(self):
        self.fake = FakeWin32Api()
        self.hwnd = 0x1000
        self.fake.add_game_window(self.hwnd, 1111, client_width=1600, client_height=900)

    def test_picks_first_usable(self):
        strategy = win_capture.CaptureStrategy(api=self.fake)
        result = strategy.capture(self.hwnd)
        self.assertIsNotNone(result)
        self.assertEqual(result.method, "printwindow_renderfull")
        self.assertEqual(strategy.chosen_method(self.hwnd), "printwindow_renderfull")

    def test_falls_back_and_caches(self):
        self.fake.capture_mode = "bitblt"
        strategy = win_capture.CaptureStrategy(api=self.fake)
        result = strategy.capture(self.hwnd)
        self.assertEqual(result.method, "bitblt_client")
        self.assertEqual(result.probe_fallbacks, ["printwindow_renderfull", "printwindow_client"])
        first_round = len(self.fake.capture_calls)
        self.assertEqual(first_round, 3)
        # 第二次命中缓存，只应有 1 次调用
        strategy.capture(self.hwnd)
        self.assertEqual(len(self.fake.capture_calls) - first_round, 1)

    def test_cache_invalidated_when_method_breaks(self):
        strategy = win_capture.CaptureStrategy(api=self.fake)
        strategy.capture(self.hwnd)
        self.fake.capture_mode = "bitblt"  # 原来选中的后端突然不可用
        result = strategy.capture(self.hwnd)
        self.assertEqual(result.method, "bitblt_client")

    def test_invalidate_forces_probe(self):
        strategy = win_capture.CaptureStrategy(api=self.fake)
        strategy.capture(self.hwnd)
        strategy.invalidate(self.hwnd)
        self.assertIsNone(strategy.chosen_method(self.hwnd))

    def test_all_backends_black_returns_last(self):
        self.fake.capture_mode = "black"
        strategy = win_capture.CaptureStrategy(api=self.fake)
        result = strategy.capture(self.hwnd)
        self.assertIsNotNone(result)
        self.assertEqual(result.metrics["black_ratio"], 1.0)
        self.assertIsNone(strategy.chosen_method(self.hwnd))

    def test_child_order_for_child_windows(self):
        self.fake.capture_mode = "childonly"
        top = 0x2000
        self.fake.add_game_window(top, 2222, with_child=True)
        strategy = win_capture.CaptureStrategy(api=self.fake)
        child = top + 1
        result = strategy.capture(child, is_child=True)
        self.assertIsNotNone(result)
        self.assertEqual(result.method, "printwindow_renderfull")
        self.assertNotIn("printwindow_window", strategy.child_order)

    def test_stats(self):
        strategy = win_capture.CaptureStrategy(api=self.fake)
        strategy.capture(self.hwnd)
        stats = strategy.stats()
        self.assertIn("chosen", stats)
        self.assertEqual(stats["chosen"][self.hwnd], "printwindow_renderfull")


class ImageHelperTest(unittest.TestCase):
    def test_normalize_size(self):
        try:
            import numpy as np
        except Exception:
            self.skipTest("未安装 numpy")
        image = np.zeros((450, 800, 3), dtype=np.uint8)
        out = win_capture.normalize_size(image, (1600, 900))
        self.assertEqual(out.shape, (900, 1600, 3))
        same = win_capture.normalize_size(out, (1600, 900))
        self.assertIs(same, out)

    def test_to_numpy_from_result(self):
        fake = FakeWin32Api()
        hwnd = 0x1000
        fake.add_game_window(hwnd, 1111, client_width=1600, client_height=900)
        result = win_capture.capture_bgra(hwnd, "printwindow_renderfull", api=fake)
        image = win_capture.to_numpy(result)
        if image is None:
            self.skipTest("未安装 numpy")
        self.assertEqual(image.shape, (900, 1600, 3))

    def test_capture_image_with_design_size(self):
        fake = FakeWin32Api()
        hwnd = 0x1000
        fake.add_game_window(hwnd, 1111, client_width=800, client_height=450)
        image, result = win_capture.capture_image(hwnd, target_size=(1600, 900), api=fake)
        if image is None:
            self.skipTest("未安装 numpy")
        self.assertEqual(image.shape, (900, 1600, 3))
        self.assertEqual(result.size, (800, 450))

    def test_usable_image(self):
        try:
            import numpy as np
        except Exception:
            self.skipTest("未安装 numpy")
        self.assertTrue(win_capture.usable_image(np.full((10, 10, 3), 100, dtype=np.uint8)))
        self.assertFalse(win_capture.usable_image(np.zeros((10, 10, 3), dtype=np.uint8)))
        self.assertFalse(win_capture.usable_image(None))

    def test_capture_to_file(self):
        fake = FakeWin32Api()
        hwnd = 0x1000
        fake.add_game_window(hwnd, 1111, client_width=320, client_height=180)
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "shot.bmp")
            result = win_capture.capture_to_file(path, hwnd, api=fake)
            self.assertIsNotNone(result)
            self.assertTrue(os.path.isfile(path))
            self.assertGreater(os.path.getsize(path), 0)


if __name__ == "__main__":
    unittest.main()
