#!/usr/bin/env python3
# coding=utf-8
"""推荐工具的测试：把假的探测报告喂进去，检查它推出的配置是否正确。

这里的报告结构必须和 tools/win_probe.py 真正写出来的一致（键名、tag 格式），
所以它同时也是"报告格式"的一份契约。
"""

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

import win_capture  # noqa: E402
import win_device  # noqa: E402
import win_probe  # noqa: E402
import win_recommend  # noqa: E402
from test_win_probe import FullFakeProbeWin  # noqa: E402

TAG = "pid1111_hwnd00001000"


def make_method(name, ok=True, black=0.02, colors=64, error=None):
    return {
        "method": name,
        "ok": ok,
        "metrics": {"valid": ok, "black_ratio": black, "distinct_colors_sampled": colors},
        "error": error,
    }


def make_report(methods=None, input_section=None, resize=None, keyboard=None,
                children=None, client=(1600, 900), targets=True):
    report = {
        "meta": {"script": "win_probe", "isWindows": True},
        "windows": [],
        "targets": [],
        "children": {TAG: children or []},
        "capture": {TAG: {"methods": methods if methods is not None else [], "best": None}},
        "occlusion": {},
        "resize": {TAG: resize} if resize is not None else {},
        "input": {TAG: input_section} if input_section is not None else {},
        "keyboard": {TAG: keyboard} if keyboard is not None else {},
    }
    if targets:
        report["targets"] = [{
            "hwnd": 0x1000, "pid": 1111, "title": "梦幻西游：时空",
            "class_name": "MyGame", "client_size": list(client),
            "children": children or [],
        }]
    return report


def all_methods_ok():
    return [make_method(name) for name in win_capture.DEFAULT_ORDER]


class RecommendCoreTest(unittest.TestCase):
    def test_all_backends_usable_keeps_default_order(self):
        result = win_recommend.recommend(make_report(methods=all_methods_ok()))
        config = result["config"]
        self.assertEqual(config["captureOrder"], list(win_capture.DEFAULT_ORDER))
        self.assertEqual(config["inputTarget"], "top")
        self.assertTrue(result["measured"])
        self.assertEqual(result["warnings"], [])

    def test_only_bitblt_usable_puts_it_first_and_warns(self):
        methods = [make_method(name) for name in win_capture.DEFAULT_ORDER]
        for item in methods:
            if item["method"] != "bitblt_client":
                item["ok"] = False
                item["metrics"] = {"valid": False, "black_ratio": 1.0,
                                   "distinct_colors_sampled": 1}
        result = win_recommend.recommend(make_report(methods=methods))
        self.assertEqual(result["config"]["captureOrder"][0], "bitblt_client")
        self.assertEqual(result["config"]["captureOrder"][-1], "bitblt_client")
        self.assertTrue(any("BitBlt" in line for line in result["warnings"]),
                        result["warnings"])
        self.assertTrue(any("不可用" in line for line in result["notes"]), result["notes"])

    def test_black_screen_backend_is_rejected(self):
        methods = all_methods_ok()
        methods[0]["metrics"] = {"valid": True, "black_ratio": 0.999,
                                 "distinct_colors_sampled": 64}
        result = win_recommend.recommend(make_report(methods=methods))
        self.assertNotEqual(result["config"]["captureOrder"][0],
                            win_capture.DEFAULT_ORDER[0])
        self.assertEqual(result["config"]["captureOrder"][0], win_capture.DEFAULT_ORDER[1])

    def test_few_colors_backend_is_rejected(self):
        methods = all_methods_ok()
        methods[1]["metrics"]["distinct_colors_sampled"] = 2
        result = win_recommend.recommend(make_report(methods=methods))
        self.assertNotIn(win_capture.DEFAULT_ORDER[1], result["config"]["captureOrder"][:1])

    def test_smoke_chosen_method_goes_first(self):
        smoke = {"devices": [{"capture": {"chosen": "bitblt_client"}}], "results": []}
        result = win_recommend.recommend(make_report(methods=all_methods_ok()), smoke)
        self.assertEqual(result["config"]["captureOrder"][0], "bitblt_client")
        self.assertTrue(any("冒烟" in line for line in result["notes"]), result["notes"])

    def test_smoke_failed_checks_are_surfaced(self):
        smoke = {"devices": [], "results": [{"name": "input", "ok": False}]}
        result = win_recommend.recommend(make_report(methods=all_methods_ok()), smoke)
        self.assertTrue(any("冒烟报告" in line for line in result["notes"]), result["notes"])

    def test_no_capture_measurement_warns_but_still_reports(self):
        result = win_recommend.recommend(make_report(methods=[]))
        self.assertNotIn("captureOrder", result["config"])
        self.assertTrue(any("截图实测结果" in line for line in result["warnings"]),
                        result["warnings"])

    def test_unknown_backend_name_is_never_written(self):
        """报告里有运行时不认识的后端名（旧版本报告）→ 只警告，绝不写进配置。"""
        methods = all_methods_ok() + [make_method("printwindow_clientonly")]
        result = win_recommend.recommend(make_report(methods=methods))
        self.assertTrue(any("不认识" in line for line in result["warnings"]),
                        result["warnings"])
        order = result["config"]["captureOrder"]
        self.assertNotIn("printwindow_clientonly", order)
        for name in order:
            self.assertIn(name, win_capture.METHODS)

    def test_child_order_only_uses_child_backends(self):
        children = [{"hwnd": 0x2000, "class_name": "RenderChild",
                     "client_size": [1600, 900]}]
        result = win_recommend.recommend(make_report(methods=all_methods_ok(),
                                                     children=children))
        self.assertEqual(result["config"]["captureOrderChild"],
                         list(win_capture.CHILD_ORDER))

    def test_child_order_keeps_child_preference_when_only_window_backend_works(self):
        methods = []
        for name in win_capture.DEFAULT_ORDER:
            ok = name in ("printwindow_window", "bitblt_window")
            methods.append(make_method(name, ok=ok, black=0.02 if ok else 1.0,
                                       colors=64 if ok else 1))
        result = win_recommend.recommend(make_report(methods=methods))
        self.assertEqual(result["config"]["captureOrder"][0], "printwindow_window")
        # 窗口级后端不能跑到子窗口顺序里去
        self.assertEqual(result["config"]["captureOrderChild"],
                         list(win_capture.CHILD_ORDER))

    def test_multiple_targets_are_mentioned(self):
        report = make_report(methods=all_methods_ok())
        report["targets"].append({"hwnd": 0x3000, "pid": 2222, "title": "时空 2",
                                  "client_size": [1600, 900], "children": []})
        result = win_recommend.recommend(report)
        self.assertTrue(any("2 个候选窗口" in line for line in result["notes"]),
                        result["notes"])

    def test_missing_target_is_not_measured(self):
        result = win_recommend.recommend(make_report(targets=False))
        self.assertFalse(result["measured"])
        self.assertTrue(any("没有候选窗口" in line for line in result["warnings"]),
                        result["warnings"])


class RecommendInputTest(unittest.TestCase):
    def test_recommendation_field_is_used(self):
        section = {"recommendation": "postmessage",
                   "postmessage": {"likely_effective": True}}
        result = win_recommend.recommend(make_report(methods=all_methods_ok(),
                                                     input_section=section))
        self.assertEqual(result["config"]["inputMethod"], "postmessage")
        self.assertEqual(result["config"]["inputTarget"], "top")

    def test_multiple_effective_methods_are_mentioned(self):
        section = {"recommendation": "sendmessage",
                   "postmessage": {"likely_effective": True},
                   "sendmessage": {"likely_effective": True}}
        result = win_recommend.recommend(make_report(methods=all_methods_ok(),
                                                     input_section=section))
        self.assertEqual(result["config"]["inputMethod"], "sendmessage")
        self.assertTrue(any("postmessage" in line for line in result["notes"]),
                        result["notes"])

    def test_effective_scan_when_no_recommendation(self):
        section = {"sendinput": {"likely_effective": True}}
        result = win_recommend.recommend(make_report(methods=all_methods_ok(),
                                                     input_section=section))
        self.assertEqual(result["config"]["inputMethod"], "sendinput")

    def test_no_effective_input_with_big_child_suggests_capture_target(self):
        section = {"postmessage": {"likely_effective": False},
                   "sendmessage": {"likely_effective": False},
                   "sendinput": {"likely_effective": False}}
        children = [{"hwnd": 0x2000, "class_name": "RenderChild",
                     "client_size": [1600, 900]}]
        result = win_recommend.recommend(make_report(methods=all_methods_ok(),
                                                     input_section=section,
                                                     children=children))
        self.assertEqual(result["config"]["inputTarget"], "capture")
        self.assertTrue(any("capture" in line for line in result["notes"]),
                        result["notes"])
        self.assertTrue(any("点击方式" in line for line in result["warnings"]),
                        result["warnings"])

    def test_no_effective_input_without_child_stays_top(self):
        section = {"postmessage": {"likely_effective": False}}
        result = win_recommend.recommend(make_report(methods=all_methods_ok(),
                                                     input_section=section))
        self.assertEqual(result["config"]["inputTarget"], "top")

    def test_small_child_does_not_trigger_capture_target(self):
        section = {"postmessage": {"likely_effective": False}}
        children = [{"hwnd": 0x2000, "class_name": "Toolbar",
                     "client_size": [200, 40]}]
        result = win_recommend.recommend(make_report(methods=all_methods_ok(),
                                                     input_section=section,
                                                     children=children))
        self.assertEqual(result["config"]["inputTarget"], "top")


class RecommendResizeAndTextTest(unittest.TestCase):
    def test_resize_matched_enables_autoresize(self):
        resize = {"matched": True, "before_client": [1280, 720],
                  "after_client": [1600, 900]}
        result = win_recommend.recommend(make_report(methods=all_methods_ok(),
                                                     resize=resize))
        self.assertTrue(result["config"]["autoResize"])
        self.assertTrue(any("1600×900" in line for line in result["notes"]),
                        result["notes"])

    def test_resize_not_matched_disables_and_warns(self):
        resize = {"matched": False, "after_client": [1280, 720]}
        result = win_recommend.recommend(make_report(methods=all_methods_ok(),
                                                     resize=resize))
        self.assertFalse(result["config"]["autoResize"])
        self.assertTrue(any("缩放" in line for line in result["warnings"]),
                        result["warnings"])

    def test_missing_resize_mentions_the_flag(self):
        result = win_recommend.recommend(make_report(methods=all_methods_ok()))
        self.assertNotIn("autoResize", result["config"])
        self.assertTrue(any("--resize" in line for line in result["notes"]),
                        result["notes"])

    def test_wm_char_preferred_when_both_work(self):
        keyboard = {"text": "abc",
                    "wm_char_diff": {"changed_ratio": 0.01},
                    "unicode_diff": {"changed_ratio": 0.01},
                    "clipboard_fallback_available": True}
        result = win_recommend.recommend(make_report(methods=all_methods_ok(),
                                                     keyboard=keyboard))
        self.assertEqual(result["config"]["textMethod"], "wm_char")

    def test_unicode_only(self):
        keyboard = {"wm_char_diff": {"changed_ratio": 0.0},
                    "unicode_diff": {"changed_ratio": 0.02}}
        result = win_recommend.recommend(make_report(methods=all_methods_ok(),
                                                     keyboard=keyboard))
        self.assertEqual(result["config"]["textMethod"], "unicode")

    def test_no_text_change_warns_and_keeps_unicode(self):
        keyboard = {"wm_char_diff": {"changed_ratio": 0.0},
                    "unicode_diff": {"changed_ratio": 0.0}}
        result = win_recommend.recommend(make_report(methods=all_methods_ok(),
                                                     keyboard=keyboard))
        self.assertEqual(result["config"]["textMethod"], "unicode")
        self.assertTrue(any("文字注入" in line for line in result["warnings"]),
                        result["warnings"])

    def test_clipboard_unavailable_is_warned(self):
        keyboard = {"unicode_diff": {"changed_ratio": 0.01},
                    "clipboard_fallback_available": False}
        result = win_recommend.recommend(make_report(methods=all_methods_ok(),
                                                     keyboard=keyboard))
        self.assertTrue(any("剪贴板" in line for line in result["warnings"]),
                        result["warnings"])


class RecommendMainTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.report_path = os.path.join(self.tmp.name, "win_probe_report.json")

    def tearDown(self):
        self.tmp.cleanup()

    def write_report(self, report):
        with open(self.report_path, "w", encoding="utf-8") as handle:
            json.dump(report, handle, ensure_ascii=False)
        return self.report_path

    def run_main(self, argv):
        out = io.StringIO()
        err = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = win_recommend.main(argv)
        return code, out.getvalue(), err.getvalue()

    def test_missing_report_exits_2(self):
        code, _out, err = self.run_main([os.path.join(self.tmp.name, "nope.json")])
        self.assertEqual(code, 2)
        self.assertIn("win_probe.py", err)

    def test_print_only_does_not_write(self):
        self.write_report(make_report(methods=all_methods_ok()))
        out_path = os.path.join(self.tmp.name, "config", "win_backend.json")
        code, out, _err = self.run_main(
            [self.report_path, "--out", out_path, "--smoke",
             os.path.join(self.tmp.name, "no_smoke.json")])
        self.assertEqual(code, 0)
        self.assertIn("captureOrder", out)
        self.assertFalse(os.path.exists(out_path))
        self.assertIn("--write", out)

    def test_write_then_device_layer_reads_it(self):
        methods = all_methods_ok()
        for item in methods:
            if item["method"] != "bitblt_client":
                item["ok"] = False
                item["metrics"] = {"valid": False, "black_ratio": 1.0,
                                   "distinct_colors_sampled": 1}
        self.write_report(make_report(methods=methods))
        out_path = os.path.join(self.tmp.name, "config", "win_backend.json")
        code, out, _err = self.run_main([self.report_path, "--out", out_path, "--write"])
        self.assertEqual(code, 0)
        self.assertTrue(os.path.isfile(out_path))
        self.assertIn("已写入", out)
        # 写出来的配置必须真的被设备层读进去，且顺序生效
        config = win_device.load_config(out_path)
        self.assertEqual(config["captureOrder"][0], "bitblt_client")
        info = win_device.environment_info(config)
        self.assertEqual(info["captureOrder"][0], "bitblt_client")
        # captureMethod 仍是 auto —— 含义是"按 captureOrder 自动择优"，
        # 报告里显示的顺序才是真正生效的东西
        self.assertEqual(info["captureMethod"], "auto")

    def test_write_refuses_existing_without_force(self):
        self.write_report(make_report(methods=all_methods_ok()))
        out_path = os.path.join(self.tmp.name, "win_backend.json")
        with open(out_path, "w", encoding="utf-8") as handle:
            handle.write('{"keep": true}')
        code, _out, err = self.run_main([self.report_path, "--out", out_path, "--write"])
        self.assertEqual(code, 1)
        self.assertIn("--force", err)
        with open(out_path, "r", encoding="utf-8") as handle:
            self.assertEqual(json.load(handle), {"keep": True})

    def test_write_with_force_overwrites(self):
        self.write_report(make_report(methods=all_methods_ok()))
        out_path = os.path.join(self.tmp.name, "win_backend.json")
        with open(out_path, "w", encoding="utf-8") as handle:
            handle.write('{"keep": true}')
        code, _out, _err = self.run_main(
            [self.report_path, "--out", out_path, "--write", "--force"])
        self.assertEqual(code, 0)
        config = win_device.load_config(out_path)
        self.assertEqual(config["captureOrder"], list(win_capture.DEFAULT_ORDER))

    def test_write_refuses_without_capture_data(self):
        self.write_report(make_report(methods=[]))
        out_path = os.path.join(self.tmp.name, "win_backend.json")
        code, _out, err = self.run_main([self.report_path, "--out", out_path, "--write"])
        self.assertEqual(code, 1)
        self.assertIn("截图实测结果", err)
        self.assertFalse(os.path.exists(out_path))

    def test_no_target_report_prints_warning_and_exits_1(self):
        self.write_report(make_report(targets=False))
        code, out, _err = self.run_main([self.report_path])
        self.assertEqual(code, 1)
        self.assertIn("没有候选窗口", out)


class ProbeReportCompatibilityTest(unittest.TestCase):
    """探测工具真正写出来的报告，推荐工具必须能读懂（跨脚本契约）。

    报告结构是两边手写的字典，最容易在这里悄悄错位：这里用假 Win32 让
    win_probe.main 真的写一份报告出来，再整份喂给 win_recommend。
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.previous = (win_probe.WIN, win_probe.Win32, win_probe.WNDPROC,
                         win_probe.IS_WINDOWS)
        win_probe.IS_WINDOWS = True
        win_probe.WNDPROC = staticmethod(lambda callback: callback)
        self.fake = FullFakeProbeWin()
        win_probe.WIN = self.fake
        win_probe.Win32 = lambda: self.fake
        self.addCleanup(self._restore)

    def _restore(self):
        (win_probe.WIN, win_probe.Win32, win_probe.WNDPROC,
         win_probe.IS_WINDOWS) = self.previous

    def test_real_probe_report_drives_a_config(self):
        with contextlib.redirect_stdout(io.StringIO()):
            code = win_probe.main(["--out", self.tmp.name, "--no-occlusion",
                                   "--no-save-shots", "--yes",
                                   "--resize", "1600x900",
                                   "--text", "时空测试"])
        self.assertEqual(code, 0)
        with open(os.path.join(self.tmp.name, "win_probe_report.json"),
                  encoding="utf-8") as handle:
            report = json.load(handle)

        result = win_recommend.recommend(report)
        config = result["config"]
        self.assertTrue(result["measured"])
        # 报告里的实测结果必须真的被用上（不是默默走了"没数据"分支）
        self.assertIn("captureOrder", config)
        self.assertNotIn("没有截图实测结果", " ".join(result["warnings"]))
        self.assertEqual(config["designWidth"], 1600)
        self.assertEqual(config["designHeight"], 900)
        # 尺寸段跑了就一定给出 autoResize 结论
        self.assertIn("autoResize", config)
        # 文字段跑了就一定给出 textMethod
        self.assertIn("textMethod", config)

    def test_report_without_targets_is_not_measured(self):
        with contextlib.redirect_stdout(io.StringIO()):
            win_probe.main(["--out", self.tmp.name, "--list-only"])
        with open(os.path.join(self.tmp.name, "win_probe_report.json"),
                  encoding="utf-8") as handle:
            report = json.load(handle)
        result = win_recommend.recommend(report)
        self.assertFalse(result["measured"])
        self.assertTrue(any("没有候选窗口" in line for line in result["warnings"]))
        # 只有窗口清单时不能瞎写配置
        code, _out, err = self._run_write(report)
        self.assertEqual(code, 1)
        self.assertIn("截图实测结果", err)

    def _run_write(self, report):
        report_path = os.path.join(self.tmp.name, "copy.json")
        with open(report_path, "w", encoding="utf-8") as handle:
            json.dump(report, handle, ensure_ascii=False)
        out_path = os.path.join(self.tmp.name, "win_backend.json")
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = win_recommend.main([report_path, "--out", out_path, "--write"])
        return code, out.getvalue(), err.getvalue()


if __name__ == "__main__":
    unittest.main()
