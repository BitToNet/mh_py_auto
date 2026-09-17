#!/usr/bin/env python3
# coding=utf-8
"""win_helper JSON-Lines 协议单元测试（用假后端，不需要 Windows/游戏）。"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "scripts", "win"))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import win_device  # noqa: E402
import win_helper  # noqa: E402
from fake_win_api import FakeWin32Api  # noqa: E402


class FakeRecorder:
    """假的钩子录制器：只记录调用与固定动作。"""

    def __init__(self, **kwargs):
        self.kwargs = kwargs
        self.started = False
        self.running = False
        self.stopped = 0

    def start(self):
        self.started = True
        self.running = True

    def stop(self):
        self.stopped += 1
        self.running = False
        return [{"type": "tap", "delayMs": 0, "startX": 10, "startY": 20,
                 "endX": 10, "endY": 20, "durationMs": 60,
                 "holdBeforeMoveMs": 0, "dragPath": [], "rawEvents": []}]

    def status(self):
        return {"running": self.running, "eventCount": 3, "actionCount": 1, "error": None}

    def snapshot_actions(self):
        return [{"type": "tap", "delayMs": 0, "startX": 10, "startY": 20,
                 "endX": 10, "endY": 20, "durationMs": 60,
                 "holdBeforeMoveMs": 0, "dragPath": [], "rawEvents": []}]


class HelperProtocolTest(unittest.TestCase):
    def setUp(self):
        self.fake = FakeWin32Api()
        self.fake.add_game_window(0x1000, 1111, client_width=800, client_height=450)
        self.fake.add_game_window(0x2000, 2222, client_width=1600, client_height=900)
        self.tmp = tempfile.TemporaryDirectory()
        self.helper = win_helper.Helper()
        self.helper.shot_dir = self.tmp.name
        self.helper.backend = win_device.WindowsBackend(config={"jitterRadius": 0}, api=self.fake)
        win_device.set_backend(self.helper.backend)

    def tearDown(self):
        win_device.set_backend(None)
        win_helper.RECORDER_FACTORY = win_helper.win_record.MouseHookRecorder
        self.tmp.cleanup()

    # -- 辅助 --
    def call(self, cmd: str, **args):
        line = json.dumps({"id": 1, "cmd": cmd, "args": args})
        response = win_helper.handle_line(self.helper, line)
        self.assertIsNotNone(response)
        return response

    # -- 用例 --
    def test_record_start_poll_stop(self):
        """录制命令走可替换的录制器工厂（真实钩子在 Windows 实机验证）。"""
        created = []

        def factory(**kwargs):
            recorder = FakeRecorder(**kwargs)
            created.append(recorder)
            return recorder

        win_helper.RECORDER_FACTORY = factory
        started = self.call("record_start", deviceId="win:1111", sampleIntervalMs=20)
        recorder = created[0]
        self.assertTrue(started["ok"], started)
        self.assertTrue(started["data"]["ok"])
        self.assertEqual(recorder.kwargs["sample_interval_ms"], 20)
        self.assertEqual(recorder.kwargs["design_size"], (1600, 900))
        self.assertEqual(recorder.kwargs["capture_size"], (800, 450))
        self.assertTrue(recorder.started)

        poll = self.call("record_poll")
        self.assertTrue(poll["data"]["running"])
        self.assertEqual(poll["data"]["actionCount"], 1)
        self.assertEqual(poll["data"]["actions"][0]["type"], "tap")

        stopped = self.call("record_stop")
        payload = stopped["data"]
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["actionCount"], 1)
        self.assertEqual(payload["screenWidth"], 1600)
        self.assertEqual(payload["screenHeight"], 900)
        self.assertEqual(payload["deviceId"], "win:1111")
        self.assertFalse(recorder.running)
        self.assertIsNone(self.helper.recorder)

    def test_record_start_twice_fails(self):
        win_helper.RECORDER_FACTORY = lambda **kwargs: FakeRecorder()
        self.assertTrue(self.call("record_start", deviceId="win:1111")["ok"])
        second = self.call("record_start", deviceId="win:1111")
        self.assertFalse(second["ok"])
        self.assertIn("已有录制", second["error"])

    def test_record_poll_without_recording(self):
        payload = self.call("record_poll")["data"]
        self.assertFalse(payload["running"])
        self.assertEqual(payload["actions"], [])

    def test_record_stop_without_recording_fails(self):
        response = self.call("record_stop")
        self.assertFalse(response["ok"])
        self.assertIn("没有录制", response["error"])

    def test_record_start_unknown_device_fails(self):
        win_helper.RECORDER_FACTORY = lambda **kwargs: FakeRecorder()
        response = self.call("record_start", deviceId="win:9999")
        self.assertFalse(response["ok"])

    def test_ping(self):
        response = self.call("ping")
        self.assertTrue(response["ok"])
        self.assertEqual(response["data"]["protocol"], win_helper.PROTOCOL_VERSION)

    def test_list_devices(self):
        response = self.call("list_devices")
        self.assertTrue(response["ok"])
        ids = [item["deviceId"] for item in response["data"]["devices"]]
        self.assertEqual(ids, ["win:1111", "win:2222"])

    def test_health(self):
        response = self.call("health")
        self.assertTrue(response["ok"])
        self.assertEqual(response["data"]["deviceCount"], 2)

    def test_capture_writes_file(self):
        response = self.call("capture", deviceId="win:1111")
        self.assertTrue(response["ok"], response)
        path = response["data"]["path"]
        self.assertTrue(os.path.isfile(path), path)
        self.assertEqual(response["data"]["width"], 1600)   # 归一化到设计分辨率
        self.assertEqual(response["data"]["height"], 900)
        self.assertTrue(path.startswith(self.tmp.name))

    def test_capture_base64(self):
        response = self.call("capture", deviceId="win:1111", encode="png_base64",
                             normalize=False)
        self.assertTrue(response["ok"], response)
        self.assertTrue(response["data"]["pngBase64"])
        self.assertEqual((response["data"]["width"], response["data"]["height"]), (800, 450))

    def test_capture_unknown_device(self):
        response = self.call("capture", deviceId="win:9999")
        self.assertFalse(response["ok"])
        self.assertIn("截图失败", response["error"])

    def test_click_maps_design_coords(self):
        response = self.call("click", deviceId="win:1111", x=800, y=450)
        self.assertTrue(response["ok"], response)
        self.assertEqual(response["data"]["realPoint"], [400, 225])
        self.assertEqual(self.fake.last_click_point(0x1000), (400, 225))

    def test_click_raw_coords(self):
        response = self.call("click", deviceId="win:1111", x=10, y=20, designCoords=False)
        self.assertTrue(response["ok"], response)
        self.assertEqual(self.fake.last_click_point(0x1000), (10, 20))

    def test_text_and_key(self):
        self.assertTrue(self.call("text", deviceId="win:1111", text="abc")["ok"])
        self.assertEqual(len(self.fake.inputs), 3)
        self.assertTrue(self.call("key", deviceId="win:1111", vk=0x1B)["ok"])

    def test_swipe(self):
        response = self.call("swipe", deviceId="win:1111", x1=100, y1=100, x2=500, y2=300,
                             durationMs=60)
        self.assertTrue(response["ok"], response)
        self.assertTrue(self.fake.clicks_on(0x1000))

    def test_resize(self):
        response = self.call("resize", deviceId="win:1111")
        self.assertTrue(response["ok"], response)
        self.assertTrue(response["data"]["matched"])
        self.assertEqual(self.fake.resize_calls[-1], (0x1000, 1600, 900))

    def test_probe_capture(self):
        response = self.call("probe_capture", deviceId="win:1111")
        self.assertTrue(response["ok"], response)
        self.assertEqual(len(response["data"]["methods"]), len(win_helper.win_capture.DEFAULT_ORDER))

    def test_config_get_set(self):
        self.assertTrue(self.call("config", set={"jitterRadius": 5})["ok"])
        response = self.call("config")
        self.assertEqual(response["data"]["jitterRadius"], 5)

    def test_ensure_running(self):
        response = self.call("ensure_running", deviceId="win:1111")
        self.assertTrue(response["ok"], response)

    def test_activate(self):
        response = self.call("activate", deviceId="win:2222")
        self.assertTrue(response["ok"], response)
        self.assertIn(0x2000, self.fake.activate_calls)

    def test_stats(self):
        self.call("capture", deviceId="win:1111")
        response = self.call("stats")
        self.assertTrue(response["ok"])
        self.assertIn("capture", response["data"])

    # -- 协议健壮性 --
    def test_unknown_command(self):
        response = self.call("nope")
        self.assertFalse(response["ok"])
        self.assertIn("未知命令", response["error"])
        self.assertIn("commands", response)

    def test_invalid_json(self):
        response = win_helper.handle_line(self.helper, "{not json")
        self.assertFalse(response["ok"])
        self.assertIn("JSON", response["error"])

    def test_non_object_request(self):
        response = win_helper.handle_line(self.helper, "[1,2,3]")
        self.assertFalse(response["ok"])

    def test_blank_line_ignored(self):
        self.assertIsNone(win_helper.handle_line(self.helper, "   "))

    def test_bad_args_type(self):
        response = win_helper.handle_line(self.helper, json.dumps({"id": 7, "cmd": "ping", "args": 5}))
        self.assertFalse(response["ok"])
        self.assertEqual(response["id"], 7)

    def test_text_falls_back_when_unicode_fails(self):
        self.fake.fail_send_input = True
        response = self.call("text", deviceId="win:1111", text="x")
        self.assertTrue(response["ok"], response)
        self.assertEqual(response["data"]["method"], "wm_char")

    def test_command_error_does_not_crash(self):
        self.fake.fail_send_input = True
        self.fake.fail_post_message = True
        response = self.call("text", deviceId="win:1111", text="x")
        self.assertFalse(response["ok"])
        # 服务仍然可用
        self.assertTrue(self.call("ping")["ok"])

    def test_shutdown_raises(self):
        with self.assertRaises(win_helper._Shutdown):
            self.call("shutdown")


if __name__ == "__main__":
    unittest.main()
