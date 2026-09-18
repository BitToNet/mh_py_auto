#!/usr/bin/env python3
# coding=utf-8
"""冒烟脚本本身的测试：用假后端在 macOS 上把 tools/smoke_win.py 完整跑一遍。"""

from __future__ import annotations

import contextlib
import io
import json
import os
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "scripts", "win"))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import smoke_win  # noqa: E402
import win_api  # noqa: E402
import win_device  # noqa: E402
from fake_win_api import FakeWin32Api  # noqa: E402


class SmokeScriptTest(unittest.TestCase):
    def setUp(self):
        self._real_is_windows = win_api.IS_WINDOWS
        win_api.IS_WINDOWS = True  # 让脚本走"Windows 分支"，但底层用假后端
        self.fake = FakeWin32Api()
        self.fake.add_game_window(0x1000, 1111, client_width=800, client_height=450)
        self.backend = win_device.WindowsBackend(config={"jitterRadius": 0}, api=self.fake)
        self.tmp = tempfile.TemporaryDirectory()
        smoke_win.RESULTS.clear()

    def tearDown(self):
        win_api.IS_WINDOWS = self._real_is_windows
        smoke_win.RESULTS.clear()
        self.tmp.cleanup()

    def run_smoke(self, argv) -> int:
        """跑冒烟脚本但吞掉它的控制台输出，保持测试输出干净。"""
        with contextlib.redirect_stdout(io.StringIO()):
            return smoke_win.main(argv, backend=self.backend)

    def report(self) -> dict:
        path = os.path.join(self.tmp.name, "smoke_report.json")
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)

    def test_readonly_run(self):
        code = self.run_smoke(["--out", self.tmp.name])
        report = self.report()
        self.assertEqual(report["failed"], 0, report["results"])
        self.assertEqual(code, 0)
        self.assertGreater(report["passed"], 0)
        self.assertEqual(report["health"]["isWindows"], True)
        self.assertEqual(len(report["devices"]), 1)
        self.assertEqual(report["devices"][0]["capture"]["chosen"], "printwindow_renderfull")
        environment = report["health"]["environment"]
        self.assertEqual(environment["designSize"], [1600, 900])
        self.assertEqual(environment["inputOrder"],
                         ["postmessage", "sendmessage", "sendinput"])
        self.assertIn("captureOrder", environment)
        # 排障关键：配置到底有没有被读到（None 表示使用内置默认值）
        self.assertIn("configPath", environment)
        self.assertIn("configFound", environment)
        self.assertTrue(os.path.isfile(report["devices"][0]["capture"]["file"]))

    def test_resize_and_input(self):
        code = self.run_smoke(["--out", self.tmp.name, "--input", "--resize", "--yes"])
        report = self.report()
        self.assertEqual(report["failed"], 0, report["results"])
        self.assertEqual(code, 0)
        entry = report["devices"][0]
        self.assertTrue(entry["resize"]["matched"])
        self.assertEqual(entry["resize"]["size"], [1600, 900])
        for method in ("postmessage", "sendmessage", "sendinput"):
            self.assertIn(method, entry["input"]["methods"])
        self.assertTrue(entry["input"]["methods"]["postmessage"]["tap"]["ok"])

    def test_text_check(self):
        code = self.run_smoke(["--out", self.tmp.name, "--text", "abc", "--yes"])
        report = self.report()
        self.assertEqual(report["failed"], 0, report["results"])
        self.assertEqual(code, 0)
        self.assertTrue(report["devices"][0]["text"]["ok"])

    def test_no_device(self):
        smoke_win.RESULTS.clear()
        empty = win_device.WindowsBackend(config={"jitterRadius": 0}, api=FakeWin32Api())
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = smoke_win.main(["--out", self.tmp.name], backend=empty)
        report = self.report()
        self.assertEqual(code, 1)
        self.assertGreater(report["failed"], 0)
        self.assertFalse(any(item["name"] == "存在可测设备" and item["ok"]
                             for item in report["results"]))
        # 枚举本身也要被检查，并且不能说成"客户端没启动"
        self.assertFalse(any(item["name"] == "窗口枚举可用" and item["ok"]
                             for item in report["results"]))
        self.assertIn("枚举机制本身失效", buffer.getvalue())
        self.assertNotIn("请确认客户端已启动", buffer.getvalue())

    def test_enumeration_check_passes_when_windows_exist(self):
        code = self.run_smoke(["--out", self.tmp.name])
        self.assertEqual(code, 0)
        listed = [item for item in self.report()["results"] if item["name"] == "窗口枚举可用"]
        self.assertEqual(len(listed), 1)
        self.assertTrue(listed[0]["ok"])
        self.assertIn("个顶层窗口", listed[0]["detail"])

    def test_unknown_device_filter(self):
        code = self.run_smoke(["--out", self.tmp.name, "--device", "win:9999"])
        self.assertEqual(code, 1)


if __name__ == "__main__":
    unittest.main()
