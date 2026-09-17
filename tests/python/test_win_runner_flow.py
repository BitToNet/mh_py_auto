#!/usr/bin/env python3
# coding=utf-8
"""两个生成运行器在假 Windows 设备层上的执行测试。

* flow_runner_win.py —— 自定义流程
* record_runner_win.py —— 录制手势回放（界面里"回放录制流程"走的就是它）

CLI 契约由 test_win_runner.py 覆盖，这里管的是"配置驱动的一次真实执行"：
配置 JSON -> main() -> 设备层调用。上层 Flutter 写出来的配置，本文件就是它的执行侧对账。
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

import flow_runner_win  # noqa: E402
import record_runner_win  # noqa: E402
import win_api  # noqa: E402
import win_device  # noqa: E402
from fake_win_api import FakeWin32Api  # noqa: E402

WM_LBUTTONDOWN = 0x0201
WM_LBUTTONUP = 0x0202
WM_MOUSEMOVE = 0x0200
WM_CHAR = 0x0102


class FlowRunnerExecutionTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self._real_is_windows = win_api.IS_WINDOWS
        win_api.IS_WINDOWS = True
        self.fake = FakeWin32Api()
        # 客户区就是设计分辨率：坐标不需要缩放，断言可以直读
        self.fake.add_game_window(0x1000, 1111, client_width=1600, client_height=900)
        self.backend = win_device.WindowsBackend(
            config={"jitterRadius": 0, "pressGapMs": 0, "inputMethod": "postmessage",
                    "textMethod": "wm_char", "activateBeforeInput": False},
            api=self.fake,
        )
        flow_runner_win.set_backend(self.backend)
        self.addCleanup(self._restore)

    def _restore(self):
        flow_runner_win.set_backend(None)
        win_device.set_backend(None)
        win_api.set_api(None)
        win_api.IS_WINDOWS = self._real_is_windows

    # -- 执行辅助 --
    def run_config(self, steps, *, device_ids=("1111",), **extra):
        config = {
            "deviceIds": list(device_ids),
            "loopCount": 1,
            "steps": steps,
            "imagePaths": {},
            "recordedFlows": {},
            "skipDeviceCheck": False,
            "jitterRadius": 0,
        }
        config.update(extra)
        path = os.path.join(self.tmp.name, "flow_config.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(config, fh, ensure_ascii=False)
        argv = list(sys.argv)
        sys.argv = ["flow_runner_win.py", path]
        buffer = io.StringIO()
        try:
            with contextlib.redirect_stdout(buffer):
                flow_runner_win.main()
        finally:
            sys.argv = argv
        return buffer.getvalue()

    def taps(self):
        """返回每个鼠标按下点的设计坐标。"""
        points = []
        for item in self.fake.messages:
            if item["msg"] == WM_LBUTTONDOWN:
                lparam = item["lparam"]
                points.append((lparam & 0xFFFF, (lparam >> 16) & 0xFFFF))
        return points

    # -- 用例 --
    def test_coordinate_tap_reaches_device_layer(self):
        self.run_config([{
            "type": "coordinateTap", "label": "点一下", "x": 800, "y": 450,
            "postWaitMinMs": 0, "postWaitMaxMs": 0,
        }])
        self.assertEqual(self.taps(), [(800, 450)])
        self.assertTrue(any(item["msg"] == WM_LBUTTONUP for item in self.fake.messages))

    def test_tap_is_clamped_to_client_area(self):
        output = self.run_config([{
            "type": "coordinateTap", "label": "越界", "x": 9999, "y": -50,
            "postWaitMinMs": 0, "postWaitMaxMs": 0,
        }])
        (x, y), = self.taps()
        self.assertTrue(0 <= x < 1600 and 0 <= y < 900, (x, y))
        self.assertGreater(x, 1500)
        self.assertLess(y, 50)
        self.assertIn("点击坐标超出边界", output)

    def test_wait_step_uses_step_range(self):
        output = self.run_config([{
            "type": "wait", "label": "等一等", "waitMinMs": 1, "waitMaxMs": 2,
        }])
        self.assertIn("开始固定等待", output)
        self.assertEqual(self.taps(), [])

    def test_loop_block_repeats_nested_steps(self):
        self.run_config([{
            "type": "loopBlock", "label": "循环两遍", "loopCount": 2, "loopMode": "fixedCount",
            "children": [{
                "type": "coordinateTap", "label": "点内部", "x": 100, "y": 200,
                "postWaitMinMs": 0, "postWaitMaxMs": 0,
            }],
        }])
        self.assertEqual(self.taps(), [(100, 200), (100, 200)])

    def test_loop_count_runs_all_steps_again(self):
        self.run_config(
            [{"type": "coordinateTap", "label": "点", "x": 10, "y": 20,
              "postWaitMinMs": 0, "postWaitMaxMs": 0}],
            loopCount=2,
        )
        self.assertEqual(self.taps(), [(10, 20), (10, 20)])

    def test_paste_text_step_types_into_client(self):
        output = self.run_config([{
            "type": "pasteText", "label": "输入文字", "textContent": "时空",
            "textInputMethod": "wm_char", "clearTextFirst": False,
        }])
        typed = "".join(chr(item["wparam"]) for item in self.fake.messages
                        if item["msg"] == WM_CHAR)
        self.assertIn("时空", typed)
        self.assertIn("字符数: 2", output)

    def test_paste_text_can_take_text_from_upper_loop(self):
        """文本逐行循环 + 粘贴文字（用上层文本）：两轮各输入一行。"""
        self.run_config([{
            "type": "loopBlock", "label": "逐行", "loopMode": "textLines",
            "loopTextContent": "第一行\n第二行",
            "children": [{
                "type": "pasteText", "label": "输入", "useParentLoopText": True,
                "textInputMethod": "wm_char", "clearTextFirst": False,
            }],
        }])
        typed = "".join(chr(item["wparam"]) for item in self.fake.messages
                        if item["msg"] == WM_CHAR)
        self.assertEqual(typed, "第一行第二行")

    def test_restart_activity_rebinds_device_to_new_pid(self):
        """重启客户端后 PID 会变：后续步骤必须自动打到新窗口上（多开寻址的关键）。"""
        fake = self.fake

        def fake_restart(self, device_id=None, **_kwargs):
            # 模拟"客户端被重启"：旧窗口消失，出现一个同进程名的新窗口
            fake.windows.pop(0x1000, None)
            fake.add_game_window(0x2000, 2222, client_width=1600, client_height=900)
            return {"started": {"started": True, "pid": 2222}}

        original_restart = win_device.WindowsBackend.restart
        self.addCleanup(lambda: setattr(win_device.WindowsBackend, "restart", original_restart))
        self.addCleanup(flow_runner_win._DEVICE_ALIASES.clear)
        self.addCleanup(flow_runner_win._device_screen_size_cache.clear)
        win_device.WindowsBackend.restart = fake_restart

        output = self.run_config([
            {"type": "restartActivity", "label": "重启客户端"},
            {"type": "coordinateTap", "label": "点一下", "x": 640, "y": 360,
             "postWaitMinMs": 0, "postWaitMaxMs": 0},
        ])
        self.assertIn("客户端已重启", output)
        self.assertIn("设备已重新绑定到 win:2222", output)
        self.assertEqual(len(self.taps()), 1, output)
        hwnds = {item["hwnd"] for item in self.fake.messages
                 if item["msg"] == WM_LBUTTONDOWN}
        self.assertEqual(hwnds, {0x2000}, "重启后仍打到了旧窗口")

    def test_restart_activity_fails_when_no_new_window(self):
        fake = self.fake

        def fake_restart(self, device_id=None, **_kwargs):
            fake.windows.pop(0x1000, None)
            return {"started": {"started": True, "pid": 2222}}

        original_restart = win_device.WindowsBackend.restart
        original_wait = win_device.WindowsBackend.wait_for_new_device
        self.addCleanup(lambda: setattr(win_device.WindowsBackend, "restart", original_restart))
        self.addCleanup(lambda: setattr(win_device.WindowsBackend, "wait_for_new_device", original_wait))
        self.addCleanup(flow_runner_win._DEVICE_ALIASES.clear)
        win_device.WindowsBackend.restart = fake_restart

        def fast_wait(self, exclude_pids=(), timeout=120.0, **kwargs):
            # 真实等待逻辑照跑，只把 180s 期限缩短，别让单测等三分钟
            return original_wait(self, exclude_pids=exclude_pids, timeout=0.05, **kwargs)

        win_device.WindowsBackend.wait_for_new_device = fast_wait

        with self.assertRaises(RuntimeError) as ctx:
            self.run_config([{"type": "restartActivity", "label": "重启客户端"}])
        self.assertIn("重启后未等到新的客户端窗口", str(ctx.exception))

    def test_unknown_step_type_fails_loudly(self):
        """Dart 枚举里没有 screenshot：真出现了必须报清楚，而不是静默跳过。"""
        with self.assertRaises(RuntimeError) as ctx:
            self.run_config([{"type": "screenshot", "label": "截图"}])
        self.assertIn("不支持的步骤类型", str(ctx.exception))

    def test_recorded_flow_step_replays_actions(self):
        recorded = {
            "screenWidth": 1600,
            "screenHeight": 900,
            "actions": [
                {"type": "tap", "startX": 800, "startY": 450, "durationMs": 60},
                {"type": "tap", "startX": 200, "startY": 300, "durationMs": 60},
            ],
        }
        output = self.run_config(
            [{"type": "recordedFlow", "label": "回放",
              "recordedFlowName": "测试手势", "recordedFlowLoopCount": 1,
              "recordedFlowSpeed": 1000}],
            recordedFlows={"测试手势": recorded},
        )
        self.assertEqual(self.taps(), [(800, 450), (200, 300)])
        self.assertIn("回放结束", output)

    def test_recorded_flow_scales_from_recorded_resolution(self):
        """录制分辨率与当前设计分辨率不同时，回放坐标要按比例缩放。"""
        recorded = {
            "screenWidth": 800,
            "screenHeight": 450,
            "actions": [{"type": "tap", "startX": 400, "startY": 225, "durationMs": 60}],
        }
        self.run_config(
            [{"type": "recordedFlow", "label": "缩放回放",
              "recordedFlowName": "小分辨率", "recordedFlowLoopCount": 1,
              "recordedFlowSpeed": 1000}],
            recordedFlows={"小分辨率": recorded},
        )
        self.assertEqual(self.taps(), [(800, 450)])

    def test_unknown_recorded_flow_raises(self):
        with self.assertRaises(RuntimeError) as ctx:
            self.run_config([{"type": "recordedFlow", "label": "回放",
                              "recordedFlowName": "不存在"}])
        self.assertIn("未找到录制流程数据", str(ctx.exception))

    def test_missing_device_raises_by_default(self):
        with self.assertRaises(RuntimeError) as ctx:
            self.run_config([{"type": "wait", "label": "等", "waitMinMs": 1, "waitMaxMs": 1}],
                            device_ids=("9999",))
        self.assertIn("找不到时空客户端窗口", str(ctx.exception))

    def test_skip_device_check_only_skips_startup_preflight(self):
        """skipDeviceCheck 只跳过启动前校验；没有窗口时执行前仍会明确报错。

        时空版没有"在流程里启动客户端"的步骤（gameMode 已明确不支持），
        所有步骤都要求窗口存在，所以这个语义是对的——测试把它钉住，免得被误用。
        """
        with self.assertRaises(RuntimeError) as ctx:
            self.run_config(
                [{"type": "wait", "label": "等", "waitMinMs": 1, "waitMaxMs": 1}],
                device_ids=("9999",), skipDeviceCheck=True,
            )
        self.assertIn("找不到时空客户端窗口", str(ctx.exception))

    def test_window_device_id_form_is_accepted(self):
        """UI 侧传的是 win:<pid>，执行器内部必须归一化成数字 id。"""
        self.run_config([{
            "type": "coordinateTap", "label": "点", "x": 5, "y": 6,
            "postWaitMinMs": 0, "postWaitMaxMs": 0,
        }], device_ids=("win:1111",))
        self.assertEqual(self.taps(), [(5, 6)])

    def test_two_devices_both_execute(self):
        self.fake.add_game_window(0x2000, 2222, client_width=1600, client_height=900)
        self.run_config(
            [{"type": "coordinateTap", "label": "点", "x": 7, "y": 8,
              "postWaitMinMs": 0, "postWaitMaxMs": 0}],
            device_ids=("1111", "2222"), parallelDevices=True,
        )
        by_hwnd = {}
        for item in self.fake.messages:
            if item["msg"] == WM_LBUTTONDOWN:
                by_hwnd.setdefault(item["hwnd"], []).append(
                    (item["lparam"] & 0xFFFF, (item["lparam"] >> 16) & 0xFFFF))
        self.assertEqual(sorted(by_hwnd), [0x1000, 0x2000])
        for hwnd, points in by_hwnd.items():
            self.assertEqual(points, [(7, 8)], hwnd)

    def test_device_scope_skips_other_devices(self):
        self.fake.add_game_window(0x2000, 2222, client_width=1600, client_height=900)
        output = self.run_config(
            [{"type": "coordinateTap", "label": "只给第一个", "x": 11, "y": 12,
              "deviceScope": "first", "postWaitMinMs": 0, "postWaitMaxMs": 0}],
            device_ids=("1111", "2222"),
        )
        self.assertEqual(len(self.taps()), 1, output)
        self.assertIn("跳过", output)

class RecordRunnerExecutionTest(unittest.TestCase):
    """录制手势回放器：界面里"回放录制流程"直接启动它。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self._real_is_windows = win_api.IS_WINDOWS
        win_api.IS_WINDOWS = True
        self.fake = FakeWin32Api()
        self.fake.add_game_window(0x1000, 1111, client_width=1600, client_height=900)
        self.backend = win_device.WindowsBackend(
            config={"jitterRadius": 0, "pressGapMs": 0, "inputMethod": "postmessage"},
            api=self.fake,
        )
        record_runner_win.set_backend(self.backend)
        self.addCleanup(self._restore)

    def _restore(self):
        record_runner_win.set_backend(None)
        win_device.set_backend(None)
        win_api.set_api(None)
        win_api.IS_WINDOWS = self._real_is_windows

    def run_config(self, config):
        path = os.path.join(self.tmp.name, "record_config.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(config, fh, ensure_ascii=False)
        argv = list(sys.argv)
        sys.argv = ["record_runner_win.py", path]
        buffer = io.StringIO()
        try:
            with contextlib.redirect_stdout(buffer):
                record_runner_win.main()
        finally:
            sys.argv = argv
        return buffer.getvalue()

    def taps(self):
        points = []
        for item in self.fake.messages:
            if item["msg"] == WM_LBUTTONDOWN:
                lparam = item["lparam"]
                points.append((lparam & 0xFFFF, (lparam >> 16) & 0xFFFF))
        return points

    @staticmethod
    def flow(name, points, screen=(1600, 900)):
        return {
            "name": name,
            "screenWidth": screen[0],
            "screenHeight": screen[1],
            "actions": [
                {"type": "tap", "startX": x, "startY": y, "durationMs": 60}
                for x, y in points
            ],
        }

    def test_single_flow_replays_actions(self):
        output = self.run_config({
            "deviceId": "win:1111", "loopCount": 1,
            "flows": [self.flow("打坐", [(800, 450), (200, 300)])],
        })
        self.assertEqual(self.taps(), [(800, 450), (200, 300)])
        self.assertIn("flow 1/1", output)
        self.assertIn("flow completed: 打坐", output)

    def test_loop_count_repeats_the_queue(self):
        self.run_config({
            "deviceId": "1111", "loopCount": 2,
            "flows": [self.flow("单点", [(100, 120)])],
        })
        self.assertEqual(self.taps(), [(100, 120), (100, 120)])

    def test_multiple_flows_keep_order(self):
        output = self.run_config({
            "deviceId": "1111", "loopCount": 1,
            "flows": [self.flow("第一步", [(10, 20)]), self.flow("第二步", [(30, 40)])],
        })
        self.assertEqual(self.taps(), [(10, 20), (30, 40)])
        self.assertIn("flow 1/2: 第一步", output)
        self.assertIn("flow 2/2: 第二步", output)

    def test_recorded_resolution_is_scaled_to_design_space(self):
        self.run_config({
            "deviceId": "1111", "loopCount": 1,
            "flows": [self.flow("小分辨率", [(400, 225)], screen=(800, 450))],
        })
        self.assertEqual(self.taps(), [(800, 450)])

    def test_flow_without_actions_does_not_crash(self):
        output = self.run_config({
            "deviceId": "1111", "loopCount": 1,
            "flows": [{"name": "空流程", "actions": []}],
        })
        self.assertEqual(self.taps(), [])
        self.assertIn("(0 actions)", output)

    def test_unknown_device_fails_clearly(self):
        with self.assertRaises(RuntimeError) as ctx:
            self.run_config({
                "deviceId": "9999", "loopCount": 1,
                "flows": [self.flow("打坐", [(1, 2)])],
            })
        self.assertIn("找不到时空客户端窗口", str(ctx.exception))

    def test_skip_device_check_still_requires_window_before_replay(self):
        """和自定义流程运行器一致：skipDeviceCheck 只跳过启动前校验。"""
        with self.assertRaises(RuntimeError) as ctx:
            self.run_config({
                "deviceId": "9999", "loopCount": 1, "skipDeviceCheck": True,
                "flows": [self.flow("打坐", [(1, 2)])],
            })
        self.assertIn("找不到时空客户端窗口", str(ctx.exception))

    def test_missing_device_id_is_rejected(self):
        with self.assertRaises(RuntimeError) as ctx:
            self.run_config({"deviceId": "", "loopCount": 1, "flows": []})
        self.assertIn("device", str(ctx.exception).lower())

    def test_empty_flows_are_rejected(self):
        with self.assertRaises(RuntimeError) as ctx:
            self.run_config({"deviceId": "1111", "loopCount": 1, "flows": []})
        self.assertIn("recorded flows", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
