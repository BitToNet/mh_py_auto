#!/usr/bin/env python3
# coding=utf-8
"""手势录制测试：事件流 → 录制动作的聚合规则（钩子本身在 Windows 实机验证）。"""

from __future__ import annotations

import os
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "scripts", "win"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import win_api  # noqa: E402
import win_device  # noqa: E402
import win_record  # noqa: E402
import win_replay  # noqa: E402
from fake_win_api import FakeWin32Api  # noqa: E402


WM_LBUTTONDOWN = 0x0201
WM_LBUTTONUP = 0x0202


def build(events, **kwargs):
    return win_record.build_actions_from_events(events, **kwargs)


class GestureBuilderTest(unittest.TestCase):
    def test_tap(self):
        actions = build([
            (0, "down", 100, 200),
            (80, "up", 100, 200),
        ])
        self.assertEqual(len(actions), 1)
        action = actions[0]
        self.assertEqual(action["type"], "tap")
        self.assertEqual((action["startX"], action["startY"]), (100, 200))
        self.assertEqual((action["endX"], action["endY"]), (100, 200))
        self.assertEqual(action["durationMs"], 80)
        self.assertEqual(action["delayMs"], 0)
        self.assertEqual(action["dragPath"], [])

    def test_long_press(self):
        actions = build([
            (0, "down", 50, 60),
            (200, "move", 52, 61),
            (900, "up", 51, 60),
        ])
        self.assertEqual(actions[0]["type"], "longPress")
        self.assertEqual(actions[0]["durationMs"], 900)
        self.assertEqual(actions[0]["dragPath"], [])
        self.assertEqual(actions[0]["holdBeforeMoveMs"], 0)

    def test_swipe_samples_path(self):
        events = [(0, "down", 0, 0)]
        for index in range(1, 11):
            events.append((index * 20, "move", index * 40, 0))
        events.append((220, "up", 400, 0))
        actions = build(events, sample_interval_ms=16)
        action = actions[0]
        self.assertEqual(action["type"], "swipe")
        self.assertEqual((action["endX"], action["endY"]), (400, 0))
        self.assertGreaterEqual(len(action["dragPath"]), 5)
        self.assertEqual(action["dragPath"][0]["x"], 40)
        self.assertEqual(action["dragPath"][-1]["x"], 400)
        self.assertTrue(all(point["delayMs"] >= 0 for point in action["dragPath"]))

    def test_sampling_interval_is_respected(self):
        events = [(0, "down", 0, 0)]
        for index in range(1, 21):
            events.append((index * 5, "move", index * 20, 0))
        events.append((110, "up", 400, 0))
        action = build(events, sample_interval_ms=50)[0]
        delays = [point["delayMs"] for point in action["dragPath"]]
        # 采样间隔 50ms：相邻采样点间隔必须 >= 50ms（首点除外）
        self.assertTrue(all(delay >= 50 for delay in delays[1:]), delays)

    def test_long_press_swipe_keeps_hold_before_move(self):
        actions = build([
            (0, "down", 10, 10),
            (500, "move", 60, 10),
            (520, "move", 120, 10),
            (600, "up", 160, 10),
        ], sample_interval_ms=16)
        action = actions[0]
        self.assertEqual(action["type"], "longPressSwipe")
        self.assertEqual(action["holdBeforeMoveMs"], 500)
        self.assertEqual(action["durationMs"], 600)
        self.assertEqual((action["endX"], action["endY"]), (160, 10))

    def test_move_within_tolerance_still_counts_as_tap(self):
        actions = build([
            (0, "down", 100, 100),
            (30, "move", 102, 101),
            (60, "up", 101, 100),
        ])
        self.assertEqual(actions[0]["type"], "tap")

    def test_delay_between_actions_uses_gap(self):
        actions = build([
            (0, "down", 10, 10),
            (50, "up", 10, 10),
            (400, "down", 20, 20),
            (450, "up", 20, 20),
        ])
        self.assertEqual(len(actions), 2)
        self.assertEqual(actions[0]["delayMs"], 0)
        self.assertEqual(actions[1]["delayMs"], 350)

    def test_finish_flushes_unfinished_press(self):
        builder = win_record.GestureBuilder(long_press_ms=100)
        builder.feed(win_record.PointerEvent(time_ms=0, kind="down", x=5, y=5))
        builder.feed(win_record.PointerEvent(time_ms=700, kind="move", x=5, y=5))
        actions = builder.finish()
        self.assertEqual(len(actions), 1)
        self.assertEqual(actions[0]["type"], "longPress")

    def test_move_without_press_is_ignored(self):
        self.assertEqual(build([(0, "move", 10, 10), (10, "up", 10, 10)]), [])

    def test_path_point_cap(self):
        events = [(0, "down", 0, 0)]
        for index in range(1, 60):
            events.append((index * 30, "move", index * 10, 0))
        events.append((1900, "up", 600, 0))
        action = build(events, sample_interval_ms=1)[0]
        self.assertLessEqual(len(action["dragPath"]), 600)
        builder = win_record.GestureBuilder(sample_interval_ms=1, max_path_points=5)
        for time_ms, kind, x, y in events:
            builder.feed(win_record.PointerEvent(time_ms=time_ms, kind=kind, x=x, y=y))
        self.assertLessEqual(len(builder.finish()[0]["dragPath"]), 5)


class RecorderGuardTest(unittest.TestCase):
    def test_requires_windows(self):
        recorder = win_record.MouseHookRecorder.__new__(win_record.MouseHookRecorder)
        recorder._thread = None  # type: ignore[attr-defined]
        self.assertFalse(recorder.is_running)

    def test_start_refuses_on_non_windows(self):
        """macOS 上开发界面时会踩到：必须给可读错误，不能抛 ctypes 栈。"""
        if win_api.IS_WINDOWS:
            self.skipTest("Windows 上由实机验证")
        recorder = win_record.MouseHookRecorder(input_hwnd=1, api=object())
        with self.assertRaises(RuntimeError) as ctx:
            recorder.start()
        self.assertIn("Windows", str(ctx.exception))

    def test_cli_refuses_on_non_windows(self):
        if win_api.IS_WINDOWS:
            self.skipTest("Windows 上由实机验证")
        self.assertEqual(win_record.main(["3"]), 2)

    def test_action_schema_matches_dart_model(self):
        action = build([(0, "down", 1, 2), (30, "up", 1, 2)])[0]
        self.assertEqual(
            sorted(action.keys()),
            sorted([
                "type", "delayMs", "startX", "startY", "endX", "endY",
                "durationMs", "holdBeforeMoveMs", "dragPath", "rawEvents",
            ]),
        )


class RecordToReplayRoundTripTest(unittest.TestCase):
    """录制的动作 JSON 直接喂给回放器：回放点到的屏幕位置必须等于录制时按下的位置。

    这是 P5 的核心承诺（"录制数据可直接复用/回放"），也是唯一能把
    "钩子采集 → 设计坐标 → 回放换算"整条链一次跑通的地方。
    """

    def setUp(self):
        self.fake = FakeWin32Api()
        # 800x450 客户区、窗口在 (100,60)：设计坐标与真实客户区是 2:1，能查出缩放错误
        self.fake.add_game_window(0x1000, 1111, client_width=800, client_height=450,
                                  left=100, top=60)
        self.backend = win_device.WindowsBackend(
            config={"jitterRadius": 0, "inputMethod": "postmessage"}, api=self.fake)
        win_device.set_backend(self.backend)
        device = self.backend.resolve("win:1111")
        self.recorder = win_record.MouseHookRecorder(
            input_hwnd=device.input_hwnd,
            top_hwnd=device.hwnd,
            offset=(device.offset_x, device.offset_y),
            capture_size=(device.capture_width, device.capture_height),
            design_size=(1600, 900),
            api=self.fake,
        )

    def tearDown(self):
        win_device.set_backend(None)

    def record(self, events):
        """events: [(time_ms, kind, screen_x, screen_y)]，坐标是屏幕坐标。"""
        for time_ms, kind, screen_x, screen_y in events:
            design_x, design_y = self.recorder._to_design(screen_x, screen_y)
            self.recorder.builder.feed(
                win_record.PointerEvent(time_ms=time_ms, kind=kind, x=design_x, y=design_y))
        return self.recorder.builder.finish()

    def replay(self, actions):
        # 录制产物已经是设计坐标，回放时源尺寸=目标尺寸=1600x900（等价于不需要缩放）
        return win_replay.replay_actions(
            self.backend, "win:1111", actions, (1600, 900), (1600, 900),
            log=lambda _message: None, sleep=lambda _ms: None)

    def test_tap_round_trip_hits_the_same_screen_point(self):
        # 屏幕 (500,285) → 客户区 (400,225) → 设计坐标 (800,450)
        actions = self.record([(0, "down", 500, 285), (80, "up", 500, 285)])
        self.assertEqual(len(actions), 1)
        self.assertEqual((actions[0]["startX"], actions[0]["startY"]), (800, 450))

        self.replay(actions)
        device = self.backend.resolve("win:1111")
        self.assertEqual(self.fake.last_click_point(0x1000), (400, 225))
        self.assertEqual(self.backend.to_screen_point(device, 800, 450), (500, 285))

    def test_swipe_round_trip_keeps_start_and_end(self):
        events = [(0, "down", 300, 200)]
        for index in range(1, 13):
            events.append((index * 20, "move", 300 + index * 40, 200))
        events.append((260, "up", 780, 200))
        actions = self.record(events)
        self.assertEqual(actions[0]["type"], "swipe")
        self.assertEqual((actions[0]["startX"], actions[0]["startY"]), (400, 280))
        self.assertEqual((actions[0]["endX"], actions[0]["endY"]), (1360, 280))

        self.replay(actions)
        downs = [m for m in self.fake.messages
                 if m["hwnd"] == 0x1000 and m["msg"] == WM_LBUTTONDOWN]
        ups = [m for m in self.fake.messages
               if m["hwnd"] == 0x1000 and m["msg"] == WM_LBUTTONUP]
        self.assertEqual(len(downs), 1)
        self.assertEqual(len(ups), 1)
        # 按下点 = 录制起点（拖动不是点击，last_click_point 记的是按下那次）
        self.assertEqual(self.fake.last_click_point(0x1000), (200, 140))
        # 最后一次移动的落点 = 录制结束时鼠标所在的屏幕位置
        raw = [m["lparam"] for m in self.fake.messages
               if m["hwnd"] == 0x1000 and m["msg"] == 0x0200]
        moves = [(value & 0xFFFF, (value >> 16) & 0xFFFF) for value in raw]
        self.assertEqual(moves[-1], (680, 140))
        self.assertEqual(
            self.backend.to_screen_point(self.backend.resolve("win:1111"), 1360, 280),
            (780, 200),
        )

    def test_long_press_round_trip_stays_on_one_point(self):
        actions = self.record([(0, "down", 500, 285), (700, "up", 500, 285)])
        self.assertEqual(actions[0]["type"], "longPress")
        self.assertEqual(actions[0]["durationMs"], 700)
        self.replay(actions)
        self.assertEqual(self.fake.last_click_point(0x1000), (400, 225))

    def test_recorded_flow_json_survives_dart_model_keys(self):
        """录制产物必须是 Dart RecordedAction.fromJson 能吃的结构。"""
        action = self.record([(0, "down", 500, 285), (80, "up", 500, 285)])[0]
        self.assertEqual(action["type"], "tap")
        self.assertIsInstance(action["dragPath"], list)
        self.assertIsInstance(action["rawEvents"], list)
        for key in ("delayMs", "startX", "startY", "endX", "endY",
                    "durationMs", "holdBeforeMoveMs"):
            self.assertIsInstance(action[key], int, key)


if __name__ == "__main__":
    unittest.main()
