#!/usr/bin/env python3
# coding=utf-8
"""窗口/进程层单元测试。"""

from __future__ import annotations

import os
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "scripts", "win"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import win_api  # noqa: E402
import win_window  # noqa: E402
from fake_win_api import FakeWindow, FakeWin32Api  # noqa: E402


def build_world() -> FakeWin32Api:
    fake = FakeWin32Api()
    fake.add_game_window(0x1000, 1111, title="梦幻西游：时空", exe="MyGame_x64r.exe",
                         client_width=1600, client_height=900, left=100, top=60)
    fake.add_game_window(0x2000, 2222, title="梦幻西游：时空", exe="MyGame_x64r.exe",
                         client_width=1280, client_height=720, left=1800, top=0)
    fake.add_game_window(0x3000, 3333, title="梦幻西游 PC 版启动器",
                         exe="MyPCLauncher_x64r.exe", client_width=900, client_height=600)
    # 无关窗口
    fake.windows[0x4000] = FakeWindow(hwnd=0x4000, pid=4444, title="新标签页",
                                      exe="chrome.exe", client_width=1200, client_height=800,
                                      class_name="Chrome_WidgetWin_1")
    fake.processes.append((4444, "chrome.exe"))
    fake.process_paths[4444] = "C:\\Program Files\\Google\\Chrome\\chrome.exe"
    return fake


class ClassifyTest(unittest.TestCase):
    def test_kinds(self):
        self.assertEqual(win_window.classify_exe("MyGame_x64r.exe"), "game")
        self.assertEqual(win_window.classify_exe("mymain.exe"), "game")
        self.assertEqual(win_window.classify_exe("MyPCLauncher_x64r.exe"), "launcher")
        self.assertEqual(win_window.classify_exe("MyPreloader_x64r.exe"), "launcher")
        self.assertEqual(win_window.classify_exe("chrome.exe"), "other")
        self.assertEqual(win_window.classify_exe(""), "other")


class ListWindowsTest(unittest.TestCase):
    def test_only_client_windows_by_default(self):
        windows = win_window.list_windows(api=build_world())
        names = sorted(item.exe_name for item in windows)
        self.assertEqual(names, ["MyGame_x64r.exe", "MyGame_x64r.exe", "MyPCLauncher_x64r.exe"])
        # 游戏窗口排在启动器前面
        self.assertEqual(windows[0].kind, "game")
        self.assertEqual(windows[-1].kind, "launcher")

    def test_include_other(self):
        windows = win_window.list_windows(api=build_world(), include_other=True)
        self.assertEqual(len(windows), 4)
        self.assertTrue(any(item.kind == "other" for item in windows))

    def test_device_id_and_dict(self):
        windows = win_window.list_windows(api=build_world())
        game = windows[0]
        self.assertEqual(game.device_id, "win:1111")
        payload = game.to_dict()
        self.assertEqual(payload["deviceId"], "win:1111")
        self.assertEqual(payload["clientWidth"], 1600)
        self.assertTrue(payload["resizable"])

    def test_hidden_window_skipped(self):
        fake = build_world()
        fake.windows[0x1000].visible = False
        windows = win_window.list_windows(api=fake)
        self.assertNotIn(0x1000, [item.hwnd for item in windows])
        windows = win_window.list_windows(api=fake, include_hidden=True)
        self.assertIn(0x1000, [item.hwnd for item in windows])

    def test_client_windows_prefers_game(self):
        fake = build_world()
        fake.windows[0x1000].visible = False
        fake.windows[0x2000].visible = False
        only_launcher = win_window.client_windows(api=fake)
        self.assertEqual(len(only_launcher), 1)
        self.assertEqual(only_launcher[0].kind, "launcher")

    def test_list_client_processes(self):
        procs = win_window.list_client_processes(api=build_world())
        names = [item.exe_name for item in procs]
        self.assertEqual(names, ["MyGame_x64r.exe", "MyGame_x64r.exe", "MyPCLauncher_x64r.exe"])
        self.assertEqual(procs[0].kind, "game")


class CaptureTargetTest(unittest.TestCase):
    def test_no_child_uses_top_window(self):
        fake = FakeWin32Api()
        fake.add_game_window(0x1000, 1111, client_width=1600, client_height=900)
        target = win_window.resolve_capture_target(0x1000, api=fake)
        self.assertEqual(target.capture_hwnd, 0x1000)
        self.assertEqual(target.input_hwnd, 0x1000)
        self.assertFalse(target.is_child_capture)
        self.assertEqual((target.width, target.height), (1600, 900))

    def test_full_size_child_is_render_target(self):
        fake = FakeWin32Api()
        fake.add_game_window(0x1000, 1111, client_width=1600, client_height=900, with_child=True)
        target = win_window.resolve_capture_target(0x1000, api=fake)
        self.assertEqual(target.capture_hwnd, 0x1001)
        self.assertTrue(target.is_child_capture)
        self.assertEqual((target.offset_x, target.offset_y), (0, 0))

    def test_small_child_ignored(self):
        fake = FakeWin32Api()
        fake.add_game_window(0x1000, 1111, client_width=1600, client_height=900,
                             with_child=True, child_covers=0.5)
        target = win_window.resolve_capture_target(0x1000, api=fake)
        self.assertEqual(target.capture_hwnd, 0x1000)

    def test_inset_child_keeps_offset(self):
        fake = FakeWin32Api()
        fake.add_game_window(0x1000, 1111, client_width=1600, client_height=900, left=100, top=60)
        child = FakeWindow(hwnd=0x1001, pid=1111, client_width=1440, client_height=810,
                           parent=0x1000, child_offset=(80, 45), class_name="RenderChild")
        fake.windows[0x1001] = child
        fake.windows[0x1000].children = [0x1001]
        target = win_window.resolve_capture_target(0x1000, api=fake)
        self.assertEqual(target.capture_hwnd, 0x1001)
        self.assertEqual((target.offset_x, target.offset_y), (80, 45))
        self.assertEqual((target.width, target.height), (1440, 810))
        # 坐标换算：设计点 → 截图窗口坐标 → 顶层客户区坐标
        self.assertEqual(target.to_capture_coords(100, 100), (20, 55))
        self.assertEqual(target.to_top_coords(100, 100), (180, 145))

    def test_explicit_capture_hwnd(self):
        fake = FakeWin32Api()
        fake.add_game_window(0x1000, 1111, client_width=1600, client_height=900,
                             with_child=True, child_covers=0.5)
        target = win_window.resolve_capture_target(0x1000, api=fake, capture_hwnd=0x1001)
        self.assertEqual(target.capture_hwnd, 0x1001)
        self.assertTrue(target.is_child_capture)

    def test_child_windows_listing(self):
        fake = FakeWin32Api()
        fake.add_game_window(0x1000, 1111, with_child=True)
        children = win_window.child_windows(0x1000, api=fake)
        self.assertEqual(len(children), 1)
        self.assertEqual(children[0]["class_name"], "MessiahRenderChild")


class WaitAndMiscTest(unittest.TestCase):
    def test_wait_for_window_found(self):
        fake = build_world()
        info = win_window.wait_for_window(timeout=0.05, api=fake)
        self.assertIsNotNone(info)
        self.assertEqual(info.kind, "game")

    def test_wait_for_window_timeout(self):
        fake = build_world()
        info = win_window.wait_for_window(timeout=0.0, api=fake, pid=999999)
        self.assertIsNone(info)

    def test_wait_for_window_by_pid(self):
        fake = build_world()
        info = win_window.wait_for_window(timeout=0.05, api=fake, pid=2222)
        self.assertIsNotNone(info)
        self.assertEqual(info.pid, 2222)

    def test_foreground_device(self):
        fake = build_world()
        fake.foreground = 0x2000
        self.assertEqual(win_window.foreground_device_id(api=fake), "win:2222")

    def test_activate_and_resize(self):
        fake = build_world()
        self.assertTrue(win_window.activate(0x1000, api=fake))
        self.assertIn(0x1000, fake.activate_calls)
        self.assertTrue(win_window.resize_client(0x2000, 1600, 900, api=fake))
        self.assertEqual(fake.windows[0x2000].client_width, 1600)
        self.assertEqual(fake.resize_calls[-1], (0x2000, 1600, 900))

    def test_resolve_launcher_path_from_process(self):
        fake = build_world()
        install_dir = win_window.find_install_dir(api=fake)
        self.assertEqual(install_dir, "C:\\games\\shikong")
        # 目录在真实文件系统里不存在时应返回 None（不会误报）
        self.assertIsNone(win_window.resolve_launcher_path(install_dir=install_dir, api=fake))

    def test_start_stop_guarded_on_non_windows(self):
        if win_api.IS_WINDOWS:
            self.skipTest("Windows 上不做该断言")
        result = win_window.start_client(api=FakeWin32Api())
        self.assertFalse(result["started"])
        self.assertIn("error", result)
        stopped = win_window.stop_client(pid=1234, api=FakeWin32Api())
        self.assertEqual(stopped["stopped"], [])


if __name__ == "__main__":
    unittest.main()
