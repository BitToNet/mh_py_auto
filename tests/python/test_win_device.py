#!/usr/bin/env python3
# coding=utf-8
"""设备层单元测试：多开寻址、坐标换算、输入降级、截图归一化。"""

from __future__ import annotations

import os
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "scripts", "win"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import win_api  # noqa: E402
import win_capture  # noqa: E402
import win_device  # noqa: E402
from fake_win_api import FakeWindow, FakeWin32Api  # noqa: E402

WM_MOUSEMOVE = 0x0200
WM_LBUTTONDOWN = 0x0201
WM_LBUTTONUP = 0x0202
WM_MOUSEWHEEL = 0x020A
WM_CHAR = 0x0102


def make_backend(fake: FakeWin32Api, **config) -> win_device.WindowsBackend:
    config.setdefault("jitterRadius", 0)
    return win_device.WindowsBackend(config=config, api=fake)


def two_instances() -> FakeWin32Api:
    fake = FakeWin32Api()
    fake.add_game_window(0x1000, 1111, client_width=800, client_height=450, left=100, top=60)
    fake.add_game_window(0x2000, 2222, client_width=1600, client_height=900, left=1000, top=0)
    return fake


class DeviceListTest(unittest.TestCase):
    def test_list_and_ids(self):
        fake = two_instances()
        backend = make_backend(fake)
        devices = backend.list_devices()
        self.assertEqual([d["deviceId"] for d in devices], ["win:1111", "win:2222"])
        self.assertEqual(backend.device_ids(), ["win:1111", "win:2222"])
        self.assertEqual(devices[0]["clientSize"], [800, 450])

    def test_same_pid_keeps_largest_window(self):
        fake = two_instances()
        small = FakeWindow(hwnd=0x1100, pid=1111, title="小窗", exe="MyGame_x64r.exe",
                           client_width=400, client_height=300)
        small.exe = "MyGame_x64r.exe"
        fake.windows[0x1100] = small
        backend = make_backend(fake)
        devices = backend.list_devices()
        self.assertEqual(len(devices), 2)
        self.assertEqual(devices[0]["hwnd"], 0x1000)

    def test_resolve_by_device_id_and_hwnd(self):
        fake = two_instances()
        backend = make_backend(fake)
        self.assertEqual(backend.resolve("win:2222").pid, 2222)
        self.assertEqual(backend.resolve("0x1000").device_id, "win:1111")
        self.assertIsNone(backend.resolve("win:9999"))

    def test_is_alive(self):
        fake = two_instances()
        backend = make_backend(fake)
        self.assertTrue(backend.is_alive("win:1111"))
        self.assertFalse(backend.is_alive("win:9999"))


class CoordinateTest(unittest.TestCase):
    def test_design_to_real_mapping(self):
        fake = two_instances()
        backend = make_backend(fake)
        device = backend.resolve("win:1111")  # 客户区 800x450，设计 1600x900
        self.assertEqual(backend.to_real_point(device, 800, 450), (400, 225))
        self.assertEqual(backend.to_real_point(device, 0, 0), (0, 0))
        self.assertEqual(backend.to_real_point(device, 1600, 900), (800, 450))
        self.assertEqual(backend.to_design_point(device, 400, 225), (800, 450))

    def test_screen_point(self):
        fake = two_instances()
        backend = make_backend(fake)
        device = backend.resolve("win:1111")  # 窗口在 (100, 60)
        self.assertEqual(backend.to_screen_point(device, 800, 450), (500, 285))

    def test_child_capture_offset(self):
        fake = FakeWin32Api()
        fake.add_game_window(0x1000, 1111, client_width=1600, client_height=900, left=100, top=60)
        child = FakeWindow(hwnd=0x1001, pid=1111, client_width=1440, client_height=810,
                           parent=0x1000, child_offset=(80, 45), class_name="RenderChild")
        fake.windows[0x1001] = child
        fake.windows[0x1000].children = [0x1001]
        backend = make_backend(fake)
        device = backend.resolve("win:1111")
        self.assertTrue(device.is_child_capture)
        self.assertEqual(device.capture_hwnd, 0x1001)
        # 设计点 (100,100) → 子窗口坐标 (90,90) → 顶层客户区坐标 (170,135)
        self.assertEqual(backend.to_real_point(device, 100, 100), (170, 135))

    def test_input_target_capture_sends_to_render_child(self):
        """实机若发现顶层窗口收不到消息，可用 inputTarget=capture 改发渲染子窗口。"""
        fake = FakeWin32Api()
        fake.add_game_window(0x1000, 1111, client_width=1600, client_height=900, left=100, top=60)
        fake.windows[0x1001] = FakeWindow(
            hwnd=0x1001, pid=1111, client_width=1440, client_height=810,
            parent=0x1000, child_offset=(80, 45), class_name="RenderChild")
        fake.windows[0x1000].children = [0x1001]
        backend = make_backend(fake, inputTarget="capture")
        device = backend.resolve("win:1111")
        self.assertEqual(device.input_hwnd, 0x1001)
        self.assertEqual((device.offset_x, device.offset_y), (0, 0))
        self.assertEqual(device.capture_hwnd, 0x1001)
        # 坐标改成相对子窗口客户区：设计点 (100,100) → (90,90)
        self.assertEqual(backend.to_real_point(device, 100, 100), (90, 90))
        result = backend.tap("win:1111", 900, 450)
        self.assertTrue(result["ok"], result)
        self.assertEqual(fake.last_click_point(0x1001), (810, 405))
        self.assertEqual([m for m in fake.messages if m["hwnd"] == 0x1000], [])

    def test_input_target_capture_without_child_falls_back_to_top(self):
        fake = two_instances()
        backend = make_backend(fake, inputTarget="capture")
        device = backend.resolve("win:1111")
        self.assertEqual(device.input_hwnd, 0x1000)
        self.assertFalse(device.is_child_capture)

    def test_input_target_unknown_value_falls_back_to_top(self):
        fake = FakeWin32Api()
        fake.add_game_window(0x1000, 1111, client_width=1600, client_height=900)
        fake.windows[0x1001] = FakeWindow(
            hwnd=0x1001, pid=1111, client_width=1440, client_height=810,
            parent=0x1000, child_offset=(80, 45), class_name="RenderChild")
        fake.windows[0x1000].children = [0x1001]
        backend = make_backend(fake, inputTarget="随便写的")
        device = backend.resolve("win:1111")
        self.assertEqual(device.input_hwnd, 0x1000)
        self.assertEqual((device.offset_x, device.offset_y), (80, 45))


class TapTest(unittest.TestCase):
    def test_tap_posts_messages_in_order(self):
        fake = two_instances()
        backend = make_backend(fake)
        result = backend.tap("win:1111", 800, 450)
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["method"], "postmessage")
        self.assertEqual(result["realPoint"], [400, 225])
        hwnd = 0x1000
        kinds = [(m["msg"], m["kind"]) for m in fake.messages if m["hwnd"] == hwnd]
        self.assertEqual(kinds[0], (WM_MOUSEMOVE, "post"))
        self.assertIn((WM_LBUTTONDOWN, "post"), kinds)
        self.assertIn((WM_LBUTTONUP, "post"), kinds)
        self.assertLess(kinds.index((WM_LBUTTONDOWN, "post")), kinds.index((WM_LBUTTONUP, "post")))
        self.assertEqual(fake.last_click_point(hwnd), (400, 225))

    def test_tap_isolated_between_instances(self):
        fake = two_instances()
        backend = make_backend(fake)
        backend.tap("win:1111", 800, 450)
        self.assertEqual(fake.clicks_on(0x2000), [])

    def test_tap_multi_instance_second_device(self):
        fake = two_instances()
        backend = make_backend(fake)
        backend.tap("win:2222", 800, 450)
        self.assertEqual(fake.last_click_point(0x2000), (800, 450))

    def test_tap_unknown_device(self):
        fake = two_instances()
        backend = make_backend(fake)
        result = backend.tap("win:9999", 10, 10)
        self.assertFalse(result["ok"])
        self.assertIn("error", result)

    def test_fallback_when_postmessage_fails(self):
        fake = two_instances()
        fake.fail_post_message = True
        backend = make_backend(fake)
        result = backend.tap("win:1111", 800, 450)
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["method"], "sendmessage")
        self.assertEqual(fake.last_click_point(0x1000), (400, 225))

    def test_force_sendinput_method(self):
        fake = two_instances()
        backend = make_backend(fake)
        result = backend.tap("win:1111", 800, 450, method="sendinput")
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["method"], "sendinput")
        self.assertTrue(fake.inputs)
        self.assertIn(0x1000, fake.activate_calls)

    def test_jitter_radius(self):
        fake = two_instances()
        backend = make_backend(fake, jitterRadius=6)
        points = {tuple(backend.tap("win:1111", 800, 450)["realPoint"]) for _ in range(25)}
        self.assertTrue(all(abs(x - 400) <= 6 and abs(y - 225) <= 6 for x, y in points))

    def test_config_selected_input_method(self):
        fake = two_instances()
        backend = make_backend(fake, inputMethod="sendmessage")
        result = backend.tap("win:1111", 800, 450)
        self.assertEqual(result["method"], "sendmessage")

    def test_swipe_records_move_and_buttons(self):
        fake = two_instances()
        backend = make_backend(fake)
        result = backend.swipe("win:1111", 200, 200, 600, 400, duration_ms=60)
        self.assertTrue(result["ok"], result)
        hwnd = 0x1000
        moves = [m for m in fake.messages if m["hwnd"] == hwnd and m["msg"] == WM_MOUSEMOVE]
        self.assertGreaterEqual(len(moves), 4)
        self.assertTrue(fake.clicks_on(hwnd))
        ups = [m for m in fake.messages if m["hwnd"] == hwnd and m["msg"] == WM_LBUTTONUP]
        self.assertTrue(ups)
        lparam = ups[-1]["lparam"]
        self.assertEqual((lparam & 0xFFFF, (lparam >> 16) & 0xFFFF), (300, 200))

    def test_scroll(self):
        fake = two_instances()
        backend = make_backend(fake)
        result = backend.scroll("win:1111", 400, 300, delta=-240)
        self.assertTrue(result["ok"], result)
        wheels = [m for m in fake.messages if m["hwnd"] == 0x1000 and m["msg"] == WM_MOUSEWHEEL]
        self.assertEqual(len(wheels), 1)
        self.assertEqual((wheels[0]["wparam"] >> 16) & 0xFFFF, (0x10000 - 240) & 0xFFFF)


class TextInputTest(unittest.TestCase):
    def test_default_unicode(self):
        fake = two_instances()
        backend = make_backend(fake)
        result = backend.input_text("win:1111", "abc")
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["method"], "unicode")
        self.assertEqual(len(fake.inputs), 3)

    def test_wm_char(self):
        fake = two_instances()
        backend = make_backend(fake, textMethod="wm_char")
        result = backend.input_text("win:1111", "你好")
        self.assertTrue(result["ok"], result)
        chars = [m for m in fake.messages if m["hwnd"] == 0x1000 and m["msg"] == WM_CHAR]
        self.assertEqual([m["wparam"] for m in chars], [ord("你"), ord("好")])

    def test_clipboard(self):
        fake = two_instances()
        backend = make_backend(fake)
        result = backend.input_text("win:1111", "中文文本", method="clipboard")
        self.assertTrue(result["ok"], result)
        self.assertEqual(fake.clipboard, "中文文本")

    def test_press_key(self):
        fake = two_instances()
        backend = make_backend(fake)
        result = backend.press_key("win:1111", 0x1B)
        self.assertTrue(result["ok"], result)
        keys = [m for m in fake.messages if m["hwnd"] == 0x1000 and m["msg"] in (0x0100, 0x0101)]
        self.assertEqual(len(keys), 2)


class DragPathTest(unittest.TestCase):
    """录制回放需要的按下-移动-抬起原语。"""

    def test_drag_path_moves_through_points(self):
        fake = two_instances()
        backend = make_backend(fake)
        result = backend.drag_path("win:1111", [(0, 0), (400, 225), (800, 450)],
                                   delays_ms=[1, 1])
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["points"], 3)
        downs = fake.clicks_on(0x1000)
        ups = [m for m in fake.messages if m["hwnd"] == 0x1000 and m["msg"] == 0x0202]
        self.assertEqual(len(downs), 1)
        self.assertEqual(len(ups), 1)
        # 设计坐标 800x450 客户区：真实坐标减半
        self.assertEqual((ups[0]["lparam"] & 0xFFFF, (ups[0]["lparam"] >> 16) & 0xFFFF),
                         (400, 225))
        moves = [m for m in fake.messages if m["hwnd"] == 0x1000 and m["msg"] == 0x0200]
        self.assertEqual(len(moves), 3)

    def test_drag_path_empty(self):
        fake = two_instances()
        backend = make_backend(fake)
        self.assertFalse(backend.drag_path("win:1111", [])["ok"])

    def test_hotkey_and_clear_text(self):
        fake = two_instances()
        backend = make_backend(fake)
        result = backend.hotkey("win:1111", [0x11, 0x41])
        self.assertTrue(result["ok"], result)
        keys = [m for m in fake.messages if m["hwnd"] == 0x1000 and m["msg"] in (0x0100, 0x0101)]
        self.assertEqual(len(keys), 4)
        cleared = backend.clear_text("win:1111")
        self.assertTrue(cleared["ok"], cleared)


class ResolveTokenTest(unittest.TestCase):
    """设备标识解析：win:<pid> / 纯 pid / hwnd 三种写法都要能用。"""

    def test_bare_pid_and_prefixed(self):
        fake = two_instances()
        backend = make_backend(fake)
        for token in ("win:1111", "pid:1111", "1111", "0x1000"):
            device = backend.resolve(token)
            self.assertIsNotNone(device, token)
            self.assertEqual(device.device_id, "win:1111", token)

    def test_unknown_token(self):
        fake = two_instances()
        backend = make_backend(fake)
        self.assertIsNone(backend.resolve("win:9999"))

    def test_wait_for_new_device(self):
        fake = two_instances()
        backend = make_backend(fake)
        self.assertIsNone(backend.wait_for_new_device(exclude_pids=[1111, 2222], timeout=0))
        fake.add_game_window(0x3000, 3333, client_width=800, client_height=450)
        device = backend.wait_for_new_device(exclude_pids=[1111, 2222], timeout=0)
        self.assertIsNotNone(device)
        self.assertEqual(device.pid, 3333)


class ScreenshotTest(unittest.TestCase):
    def test_normalized_to_design_size(self):
        fake = two_instances()
        backend = make_backend(fake)
        image = backend.screenshot("win:1111")  # 真实客户区 800x450
        if image is None:
            self.skipTest("未安装 numpy")
        self.assertEqual(image.shape, (900, 1600, 3))

    def test_raw_size(self):
        fake = two_instances()
        backend = make_backend(fake)
        image = backend.screenshot("win:1111", normalize=False)
        if image is None:
            self.skipTest("未安装 numpy")
        self.assertEqual(image.shape, (450, 800, 3))

    def test_screen_size(self):
        fake = two_instances()
        backend = make_backend(fake)
        self.assertEqual(backend.screen_size("win:1111"), (1600, 900))
        self.assertEqual(backend.screen_size("win:1111", normalized=False), (800, 450))

    def test_save_path(self):
        import tempfile
        fake = two_instances()
        backend = make_backend(fake)
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "shot.bmp")
            backend.screenshot("win:1111", save_path=path, normalize=False)
            self.assertTrue(os.path.isfile(path))

    def test_capture_info(self):
        fake = two_instances()
        backend = make_backend(fake)
        info = backend.capture_info("win:1111")
        self.assertTrue(info["ok"])
        self.assertEqual(info["method"], "printwindow_renderfull")
        self.assertEqual(info["metrics"]["black_ratio"], 0.0)

    def test_child_capture_device(self):
        fake = FakeWin32Api()
        fake.capture_mode = "childonly"  # 只有子窗口能截到画面
        fake.add_game_window(0x1000, 1111, client_width=1600, client_height=900, with_child=True)
        backend = make_backend(fake)
        info = backend.capture_info("win:1111")
        self.assertTrue(info["ok"], info)
        self.assertEqual(info["device"]["captureHwnd"], 0x1001)


class WindowSizeTest(unittest.TestCase):
    def test_skipped_when_disabled(self):
        fake = two_instances()
        backend = make_backend(fake)
        result = backend.ensure_design_size("win:1111")
        self.assertFalse(result["ok"])
        self.assertTrue(result.get("skipped"))
        self.assertEqual(fake.resize_calls, [])

    def test_forced_resize(self):
        fake = two_instances()
        backend = make_backend(fake)
        result = backend.ensure_design_size("win:1111", force=True)
        self.assertTrue(result["matched"], result)
        self.assertEqual(fake.resize_calls[-1], (0x1000, 1600, 900))
        self.assertEqual(result["size"], [1600, 900])

    def test_already_correct_size(self):
        fake = two_instances()
        backend = make_backend(fake)
        result = backend.ensure_design_size("win:2222", force=True)
        self.assertTrue(result["already"])
        self.assertEqual(fake.resize_calls, [])

    def test_minimized_window(self):
        fake = two_instances()
        fake.windows[0x1000].minimized = True
        backend = make_backend(fake)
        result = backend.ensure_design_size("win:1111", force=True)
        self.assertFalse(result["ok"])
        self.assertIn("最小化", result["error"])


class EnvironmentInfoTest(unittest.TestCase):
    """发布包排障：报告里必须能看出 Python 依赖、配置来源、生效的后端顺序。"""

    def test_reports_python_and_dependency_versions(self):
        info = win_device.environment_info()
        self.assertTrue(info["python"])
        self.assertIn("scriptsDir", info)
        self.assertIsInstance(info["fromExtractedRuntime"], bool)
        self.assertIn("configPath", info)
        self.assertIsInstance(info["configFound"], bool)
        for key in ("numpy", "opencv", "rapidocr"):
            self.assertIn(key, info)
            self.assertTrue(info[key] is None or isinstance(info[key], str))

    def test_reflects_config_overrides(self):
        """报告必须显示"实例真正在用的顺序"，否则排障时会看错后端。"""
        fake = two_instances()
        backend = make_backend(
            fake,
            inputTarget="capture",
            captureOrder=["bitblt_client"],
            inputOrder=["sendinput", "postmessage"],
        )
        info = win_device.environment_info(backend.config)
        self.assertEqual(info["inputTarget"], "capture")
        self.assertEqual(info["captureOrder"], ["bitblt_client"])
        self.assertEqual(info["inputOrder"], ["sendinput", "postmessage"])
        self.assertEqual(info["designSize"], [1600, 900])
        # 没被覆盖的字段回落到内置默认值
        self.assertEqual(info["captureOrderChild"], list(win_capture.CHILD_ORDER))

    def test_health_includes_environment(self):
        fake = two_instances()
        backend = make_backend(fake)
        health = backend.health()
        self.assertIn("environment", health)
        self.assertEqual(health["environment"]["python"], win_device.environment_info()["python"])


class LifecycleTest(unittest.TestCase):
    def test_ensure_running_existing(self):
        fake = two_instances()
        backend = make_backend(fake)
        result = backend.ensure_running("win:1111")
        self.assertTrue(result["ok"])
        self.assertTrue(result["already"])

    def test_ensure_running_restores_minimized(self):
        fake = two_instances()
        fake.windows[0x1000].minimized = True
        backend = make_backend(fake)
        result = backend.ensure_running("win:1111")
        self.assertTrue(result["restored"])
        self.assertIn(0x1000, fake.activate_calls)

    def test_ensure_running_without_client(self):
        fake = FakeWin32Api()
        backend = make_backend(fake)
        result = backend.ensure_running(timeout=0.01)
        self.assertFalse(result.get("ok", False))
        self.assertIn("error", result)

    def test_activate(self):
        fake = two_instances()
        backend = make_backend(fake)
        result = backend.activate("win:2222")
        self.assertTrue(result["ok"])
        self.assertIn(0x2000, fake.activate_calls)

    def test_health_structure(self):
        fake = two_instances()
        backend = make_backend(fake)
        info = backend.health()
        self.assertEqual(info["designSize"], [1600, 900])
        self.assertEqual(info["deviceCount"], 2)
        self.assertEqual(info["isWindows"], win_api.IS_WINDOWS)
        self.assertTrue(info["capture"]["ok"])

    def test_stats(self):
        fake = two_instances()
        backend = make_backend(fake)
        backend.screenshot("win:1111")
        backend.tap("win:1111", 10, 10)
        stats = backend.stats()
        self.assertIn("capture", stats)
        self.assertIn("input", stats)
        self.assertEqual(len(stats["devices"]), 2)


class ModuleFacadeTest(unittest.TestCase):
    def setUp(self):
        self.fake = two_instances()
        self.backend = make_backend(self.fake)
        win_device.set_backend(self.backend)

    def tearDown(self):
        win_device.set_backend(None)

    def test_facade_functions(self):
        self.assertEqual(win_device.list_connected_device_ids(), ["win:1111", "win:2222"])
        self.assertEqual(win_device.screen_size("win:1111"), (1600, 900))
        self.assertTrue(win_device.tap("win:1111", 800, 450)["ok"])
        self.assertTrue(win_device.swipe("win:1111", 10, 10, 100, 100, duration_ms=40)["ok"])
        self.assertTrue(win_device.input_text("win:1111", "x")["ok"])
        self.assertTrue(win_device.press_key("win:1111", 0x1B)["ok"])
        self.assertTrue(win_device.health()["deviceCount"] == 2)

    def test_facade_ensure_running(self):
        self.assertTrue(win_device.ensure_running("win:1111")["ok"])

    def test_facade_screenshot(self):
        self.assertIsNotNone(win_device.screenshot("win:1111"))


if __name__ == "__main__":
    unittest.main()
