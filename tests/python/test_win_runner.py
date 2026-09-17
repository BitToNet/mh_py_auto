#!/usr/bin/env python3
# coding=utf-8
"""时空客户端流程运行器测试：坐标链、文本输入、录制回放、设备重绑、配置契约。"""

from __future__ import annotations

import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "scripts", "win"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import flow_runner_win  # noqa: E402
import record_runner_win  # noqa: E402
import win_device  # noqa: E402
import win_replay  # noqa: E402
from fake_win_api import FakeWin32Api  # noqa: E402

WM_CHAR = 0x0102
WM_LBUTTONDOWN = 0x0201
WM_LBUTTONUP = 0x0202


def make_backend(fake: FakeWin32Api, **config) -> win_device.WindowsBackend:
    config.setdefault("jitterRadius", 0)
    config.setdefault("textMethod", "wm_char")
    config.setdefault("inputMethod", "postmessage")
    return win_device.WindowsBackend(config=config, api=fake)


def single_instance(client_width: int = 800, client_height: int = 450) -> FakeWin32Api:
    fake = FakeWin32Api()
    fake.add_game_window(0x1000, 1111, client_width=client_width, client_height=client_height,
                         left=100, top=60)
    return fake


class RunnerShapeTest(unittest.TestCase):
    """确认生成出来的运行器里已经没有 Android 专有实现。"""

    def read(self, name: str) -> str:
        with open(os.path.join(ROOT, "scripts", "win", name), encoding="utf-8") as file:
            return file.read()

    def test_flow_runner_has_no_adb(self):
        source = self.read("flow_runner_win.py")
        for forbidden in ("['adb'", '"adb"', "sendevent", "AdbIME", "adbkeyboard", "dumpsys"):
            self.assertNotIn(forbidden, source, f"流程运行器仍残留 {forbidden}")

    def test_record_runner_has_no_adb(self):
        source = self.read("record_runner_win.py")
        for forbidden in ("['adb'", '"adb"', "sendevent", "AdbIME"):
            self.assertNotIn(forbidden, source, f"回放运行器仍残留 {forbidden}")

    def test_flow_runner_uses_device_layer(self):
        source = self.read("flow_runner_win.py")
        self.assertIn("win_device", source)
        self.assertIn("win_replay", source)
        self.assertIn("device_token", source)


class RunnerCliTest(unittest.TestCase):
    """运行器是给用户在 cmd 里手动跑的，参数处理必须友好（不能丢 traceback）。"""

    def run_runner(self, name: str, *args: str):
        script = os.path.join(ROOT, "scripts", "win", name)
        return subprocess.run([sys.executable, script, *args],
                              capture_output=True, text=True, timeout=120)

    def test_help_prints_usage(self):
        for name, marker in (("flow_runner_win.py", "deviceIds"),
                             ("record_runner_win.py", "flows")):
            result = self.run_runner(name, "--help")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("用法: python", result.stderr)
            self.assertIn(marker, result.stderr)

    def test_missing_config_exits_with_usage(self):
        for name in ("flow_runner_win.py", "record_runner_win.py"):
            result = self.run_runner(name)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("用法: python", result.stderr)
            self.assertNotIn("Traceback", result.stderr)

    def test_extra_args_are_rejected_with_usage(self):
        for name in ("flow_runner_win.py", "record_runner_win.py"):
            result = self.run_runner(name, "a.json", "b.json")
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("多余的参数", result.stderr)

    def test_missing_config_file_reports_readable_error(self):
        result = self.run_runner("flow_runner_win.py", "no_such_file.json")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no_such_file.json", result.stderr)


class RunnerSyncTest(unittest.TestCase):
    """生成器与 lib/main.dart 内嵌运行器必须保持同步（防止上游改动后静默漂移）。"""

    def test_generated_runners_are_in_sync(self):
        script = os.path.join(ROOT, "scripts", "win", "build_win_runners.py")
        result = subprocess.run([sys.executable, script, "--check"],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_generator_rejects_unknown_anchor(self):
        import build_win_runners  # noqa: PLC0415

        with self.assertRaises(SystemExit):
            build_win_runners.replace_once("abc", "zzz", "yyy", "测试锚点")


class ReplayPlanTest(unittest.TestCase):
    """录制动作 -> 鼠标路径的翻译规则。"""

    def test_tap_is_single_click(self):
        plan = win_replay.build_replay_plan(
            {"type": "tap", "startX": 800, "startY": 450}, (1600, 900), (1600, 900))
        self.assertEqual(plan["kind"], "tap")
        self.assertEqual(plan["points"], [(800, 450)])
        self.assertEqual(plan["delaysMs"], [])

    def test_coordinates_are_scaled(self):
        plan = win_replay.build_replay_plan(
            {"type": "tap", "startX": 800, "startY": 450}, (1600, 900), (800, 450))
        self.assertEqual(plan["points"], [(400, 225)])

    def test_long_press_holds_same_point(self):
        plan = win_replay.build_replay_plan(
            {"type": "longPress", "startX": 100, "startY": 100, "durationMs": 800},
            (1600, 900), (1600, 900))
        self.assertEqual(plan["kind"], "drag")
        self.assertEqual(plan["points"], [(100, 100), (100, 100)])
        self.assertEqual(plan["delaysMs"], [800.0])

    def test_swipe_interpolates_steps(self):
        plan = win_replay.build_replay_plan(
            {"type": "swipe", "startX": 0, "startY": 0, "endX": 120, "endY": 0,
             "durationMs": 240},
            (1600, 900), (1600, 900))
        self.assertEqual(plan["kind"], "drag")
        self.assertEqual(plan["points"][0], (4, 4))
        self.assertEqual(plan["points"][-1][0], 120)
        self.assertEqual(len(plan["points"]), 13)
        self.assertTrue(all(delay >= win_replay.MIN_STEP_DELAY_MS for delay in plan["delaysMs"]))

    def test_drag_path_keeps_sampled_points(self):
        plan = win_replay.build_replay_plan(
            {"type": "longPressSwipe", "startX": 0, "startY": 0, "endX": 300, "endY": 0,
             "durationMs": 600, "holdBeforeMoveMs": 400,
             "dragPath": [{"x": 100, "y": 10, "delayMs": 50}, {"x": 300, "y": 0, "delayMs": 30}]},
            (1600, 900), (1600, 900))
        self.assertEqual(plan["delaysMs"][:3], [400.0, 50, 30])
        self.assertIn((100, 10), plan["points"])
        self.assertEqual(plan["points"][-1], (300, 4))  # y 被夹到上边距 4


class RunnerScreenshotTest(unittest.TestCase):
    def setUp(self):
        self.fake = single_instance()
        self.backend = make_backend(self.fake)
        flow_runner_win.set_backend(self.backend)
        flow_runner_win._device_screen_size_cache.clear()
        self.tmp = tempfile.mkdtemp(prefix="flow_runner_test_")

    def test_screenshot_saved_and_normalized(self):
        path = os.path.join(self.tmp, "shot.png")
        with contextlib.redirect_stdout(io.StringIO()):
            image = flow_runner_win.adb_screenshot("1111", path)
        self.assertTrue(os.path.exists(path))
        self.assertEqual((image.shape[1], image.shape[0]), (1600, 900))

    def test_screen_size_is_design_size(self):
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(flow_runner_win.get_device_screen_size("1111"), (1600, 900))

    def test_missing_device_raises(self):
        self.fake.windows.clear()
        with self.assertRaises(RuntimeError):
            with contextlib.redirect_stdout(io.StringIO()):
                flow_runner_win.adb_screenshot("1111", os.path.join(self.tmp, "x.png"))


class RunnerInputTest(unittest.TestCase):
    def setUp(self):
        self.fake = single_instance()
        self.backend = make_backend(self.fake)
        flow_runner_win.set_backend(self.backend)
        flow_runner_win._device_screen_size_cache.clear()

    def test_tap_maps_design_to_client(self):
        with contextlib.redirect_stdout(io.StringIO()):
            flow_runner_win.tap("1111", 800, 450)
        self.assertEqual(self.fake.last_click_point(0x1000), (400, 225))

    def test_tap_clamps_to_bounds(self):
        with contextlib.redirect_stdout(io.StringIO()):
            flow_runner_win.tap("1111", 99999, -5)
        x, y = self.fake.last_click_point(0x1000)
        self.assertLessEqual(x, 800)
        self.assertGreaterEqual(y, 0)

    def test_paste_text_step_sends_characters(self):
        step = {"type": "pasteText", "textContent": "ab"}
        with contextlib.redirect_stdout(io.StringIO()):
            flow_runner_win.run_paste_text_step("1111", step)
        chars = [m for m in self.fake.messages
                 if m["hwnd"] == 0x1000 and m["msg"] == WM_CHAR]
        self.assertEqual([chr(m["wparam"]) for m in chars], ["a", "b"])

    def test_paste_text_uses_loop_text(self):
        step = {"type": "pasteText", "useParentLoopText": True}
        with contextlib.redirect_stdout(io.StringIO()):
            flow_runner_win.run_paste_text_step("1111", step, {"currentLoopText": "xy"})
        chars = [m for m in self.fake.messages
                 if m["hwnd"] == 0x1000 and m["msg"] == WM_CHAR]
        self.assertEqual([chr(m["wparam"]) for m in chars], ["x", "y"])

    def test_paste_text_without_loop_text_raises(self):
        step = {"type": "pasteText", "useParentLoopText": True}
        with self.assertRaises(RuntimeError):
            with contextlib.redirect_stdout(io.StringIO()):
                flow_runner_win.run_paste_text_step("1111", step, {})


class RunnerStepsTest(unittest.TestCase):
    def setUp(self):
        self.fake = single_instance()
        self.backend = make_backend(self.fake)
        flow_runner_win.set_backend(self.backend)
        flow_runner_win._device_screen_size_cache.clear()
        self.tmp = tempfile.mkdtemp(prefix="flow_runner_steps_")

    def run_steps(self, steps, runtime_context=None):
        context = {"deviceIds": ["1111"]}
        context.update(runtime_context or {})
        with contextlib.redirect_stdout(io.StringIO()):
            flow_runner_win.execute_steps_uncoordinated(
                "1111", steps, {}, self.tmp, context)

    def test_wait_and_coordinate_tap(self):
        self.run_steps([
            {"type": "wait", "waitMinSeconds": 0, "waitMaxSeconds": 0},
            {"type": "coordinateTap", "x": 1600, "y": 900},
        ])
        # 设计空间先夹到 (1598, 898)，再按 800x450 客户区缩放
        self.assertEqual(self.fake.last_click_point(0x1000), (799, 449))

    def test_device_scope_others_skips_first_device(self):
        self.run_steps(
            [{"type": "coordinateTap", "x": 100, "y": 100, "deviceScope": "others"}],
            {"deviceIds": ["1111"]},
        )
        self.assertEqual(self.fake.clicks_on(0x1000), [])

    def test_game_mode_step_is_rejected(self):
        with self.assertRaises(RuntimeError):
            self.run_steps([{"type": "gameMode"}])

    def test_paste_text_step_inside_flow(self):
        self.run_steps([{"type": "pasteText", "textContent": "z"}])
        chars = [m for m in self.fake.messages
                 if m["hwnd"] == 0x1000 and m["msg"] == WM_CHAR]
        self.assertEqual([chr(m["wparam"]) for m in chars], ["z"])

    def test_loop_block_runs_children(self):
        self.run_steps([
            {"type": "loopBlock", "loopCount": 3, "loopMode": "fixedCount",
             "children": [{"type": "coordinateTap", "x": 100, "y": 100}]},
        ])
        self.assertEqual(len(self.fake.clicks_on(0x1000)), 3)


class RunnerRecordedFlowTest(unittest.TestCase):
    def setUp(self):
        self.fake = single_instance()
        self.backend = make_backend(self.fake)
        flow_runner_win.set_backend(self.backend)
        flow_runner_win._device_screen_size_cache.clear()

    def test_recorded_flow_replays_tap_and_swipe(self):
        flows = {
            "demo": {
                "screenWidth": 1600, "screenHeight": 900, "touchDevicePath": "/dev/input/event3",
                "actions": [
                    {"type": "tap", "startX": 800, "startY": 450},
                    {"type": "swipe", "startX": 100, "startY": 100, "endX": 300, "endY": 100,
                     "durationMs": 120},
                ],
            }
        }
        step = {"type": "recordedFlow", "recordedFlowName": "demo", "recordedFlowLoopCount": 1}
        with contextlib.redirect_stdout(io.StringIO()):
            flow_runner_win.run_recorded_flow_step(
                "1111", step, {"recordedFlows": flows, "deviceIds": ["1111"]})
        # 动作 1：设计坐标 (800, 450) -> 800x450 客户区 (400, 225)
        downs = self.fake.clicks_on(0x1000)
        self.assertEqual([(m["lparam"] & 0xFFFF, (m["lparam"] >> 16) & 0xFFFF) for m in downs],
                         [(400, 225), (50, 50)])
        ups = [m for m in self.fake.messages
               if m["hwnd"] == 0x1000 and m["msg"] == WM_LBUTTONUP]
        self.assertTrue(ups, "拖动结束应抬起左键")
        # 动作 2：横向滑动到设计坐标 (300, 100) 对应的 (150, 50)
        moves = [m for m in self.fake.messages
                 if m["hwnd"] == 0x1000 and m["msg"] == 0x0200]
        self.assertTrue(moves, "滑动过程中应有鼠标移动消息")
        self.assertEqual((moves[-1]["lparam"] & 0xFFFF, (moves[-1]["lparam"] >> 16) & 0xFFFF),
                         (150, 50))

    def test_recorded_flow_scales_from_other_resolution(self):
        flows = {
            "hd": {
                "screenWidth": 1280, "screenHeight": 720,
                "actions": [{"type": "tap", "startX": 640, "startY": 360}],
            }
        }
        step = {"type": "recordedFlow", "recordedFlowName": "hd", "recordedFlowLoopCount": 1}
        with contextlib.redirect_stdout(io.StringIO()):
            flow_runner_win.run_recorded_flow_step(
                "1111", step, {"recordedFlows": flows, "deviceIds": ["1111"]})
        # 1280x720 的中心 -> 设计空间中心 (800, 450) -> 800x450 客户区中心 (400, 225)
        self.assertEqual(self.fake.last_click_point(0x1000), (400, 225))

    def test_unknown_flow_raises(self):
        step = {"type": "recordedFlow", "recordedFlowName": "missing"}
        with self.assertRaises(RuntimeError):
            with contextlib.redirect_stdout(io.StringIO()):
                flow_runner_win.run_recorded_flow_step("1111", step, {"recordedFlows": {}})


class RunnerRestartTest(unittest.TestCase):
    def setUp(self):
        self.fake = single_instance()
        self.backend = make_backend(self.fake)
        flow_runner_win.set_backend(self.backend)
        flow_runner_win._device_screen_size_cache.clear()
        flow_runner_win._DEVICE_ALIASES.clear()

    def test_restart_activity_rebinds_to_new_pid(self):
        self.fake.add_game_window(0x2000, 2222, client_width=800, client_height=450)
        new_device = self.backend.resolve("win:2222")
        self.backend.restart = lambda device_id=None: {"started": {"started": True}}
        self.backend.wait_for_new_device = lambda exclude_pids=(), timeout=0: new_device

        with contextlib.redirect_stdout(io.StringIO()):
            flow_runner_win.restart_activity("1111", "")
        self.assertEqual(flow_runner_win.device_token("1111"), "win:2222")

        self.fake.messages.clear()
        with contextlib.redirect_stdout(io.StringIO()):
            flow_runner_win.tap("1111", 800, 450)
        self.assertEqual(self.fake.last_click_point(0x2000), (400, 225))

    def test_restart_without_new_window_raises(self):
        self.backend.restart = lambda device_id=None: {"started": {"started": True}}
        self.backend.wait_for_new_device = lambda exclude_pids=(), timeout=0: None
        with self.assertRaises(RuntimeError):
            with contextlib.redirect_stdout(io.StringIO()):
                flow_runner_win.restart_activity("1111", "")

    def test_detect_current_activity_returns_pseudo_component(self):
        with contextlib.redirect_stdout(io.StringIO()):
            component = flow_runner_win.detect_current_activity("1111")
        self.assertEqual(component, "win:1111/ShiKong")
        self.assertEqual(flow_runner_win.package_name_from_component(component), "win:1111")


class RunnerMainTest(unittest.TestCase):
    def setUp(self):
        self.fake = single_instance()
        self.backend = make_backend(self.fake)
        flow_runner_win.set_backend(self.backend)
        flow_runner_win._device_screen_size_cache.clear()
        flow_runner_win._DEVICE_ALIASES.clear()

    def run_main(self, config: dict) -> None:
        work_dir = tempfile.mkdtemp(prefix="flow_runner_main_")
        config_path = os.path.join(work_dir, "flow_config.json")
        with open(config_path, "w", encoding="utf-8") as file:
            json.dump(config, file, ensure_ascii=False)
        argv = sys.argv
        sys.argv = ["flow_runner_win.py", config_path]
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                flow_runner_win.main()
        finally:
            sys.argv = argv

    def test_main_runs_configured_flow(self):
        self.run_main({
            "deviceIds": ["win:1111"],
            "loopCount": 1,
            "steps": [
                {"type": "coordinateTap", "x": 800, "y": 450},
                {"type": "pasteText", "textContent": "ok"},
            ],
            "imagePaths": {},
            "recordedFlows": {},
        })
        self.assertEqual(self.fake.last_click_point(0x1000), (400, 225))
        chars = [m for m in self.fake.messages
                 if m["hwnd"] == 0x1000 and m["msg"] == WM_CHAR]
        self.assertEqual([chr(m["wparam"]) for m in chars], ["o", "k"])

    def test_main_without_devices_raises(self):
        with self.assertRaises(RuntimeError):
            self.run_main({"deviceIds": [], "steps": []})

    def test_main_with_unknown_device_raises(self):
        with self.assertRaises(RuntimeError):
            self.run_main({"deviceIds": ["win:9999"], "steps": []})


class RecordRunnerTest(unittest.TestCase):
    """单独回放录制流程的脚本。"""

    def setUp(self):
        self.fake = single_instance()
        self.backend = make_backend(self.fake)
        record_runner_win.set_backend(self.backend)
        record_runner_win._device_screen_size_cache.clear()

    def run_main(self, config: dict) -> None:
        work_dir = tempfile.mkdtemp(prefix="record_runner_")
        config_path = os.path.join(work_dir, "record_config.json")
        with open(config_path, "w", encoding="utf-8") as file:
            json.dump(config, file, ensure_ascii=False)
        argv = sys.argv
        sys.argv = ["record_runner_win.py", config_path]
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                record_runner_win.main()
        finally:
            sys.argv = argv

    def test_play_recorded_queue(self):
        self.run_main({
            "deviceId": "win:1111",
            "loopCount": 2,
            "flows": [
                {"name": "a", "screenWidth": 1600, "screenHeight": 900,
                 "actions": [{"type": "tap", "startX": 700, "startY": 400}]},
            ],
        })
        clicks = self.fake.clicks_on(0x1000)
        self.assertEqual(len(clicks), 2)
        self.assertEqual(self.fake.last_click_point(0x1000), (350, 200))

    def test_missing_device_raises(self):
        with self.assertRaises(RuntimeError):
            self.run_main({"deviceId": "", "flows": []})


if __name__ == "__main__":
    unittest.main()
