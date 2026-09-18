#!/usr/bin/env python3
# coding=utf-8
"""探测工具（tools/win_probe.py）逻辑测试。

这是用户实机排查的第一步，一旦它自己崩了就什么都拿不到，
所以把纯逻辑（图像分析、候选判定、窗口枚举、命令行参数）都在 macOS 上钉住。
真正调用 Win32 截图/注入的部分只能在 Windows 上验证。
"""

from __future__ import annotations

import argparse
import contextlib
import ctypes
import io
import json
import os
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import win_probe  # noqa: E402


def bgra(pixel, width, height):
    return bytes(pixel) * (width * height)


class ImageAnalysisTest(unittest.TestCase):
    def test_black_frame_is_detected(self):
        result = win_probe.analyze_image(bgra((0, 0, 0, 255), 40, 30), 40, 30)
        self.assertTrue(result["valid"])
        self.assertEqual(result["black_ratio"], 1.0)
        self.assertEqual(result["mean_brightness"], 0.0)
        self.assertEqual(result["distinct_colors_sampled"], 1)

    def test_colorful_frame_has_many_colors(self):
        buf = bytearray()
        for index in range(40 * 30):
            buf += bytes((index % 251, (index * 7) % 251, (index * 13) % 251, 255))
        result = win_probe.analyze_image(bytes(buf), 40, 30)
        self.assertLess(result["black_ratio"], 0.1)
        self.assertGreater(result["distinct_colors_sampled"], 50)

    def test_truncated_buffer_is_invalid(self):
        self.assertEqual(win_probe.analyze_image(b"\x00" * 8, 40, 30), {"valid": False})
        self.assertEqual(win_probe.analyze_image(b"", 0, 0), {"valid": False})

    def test_diff_images(self):
        a = bgra((0, 0, 0, 255), 20, 20)
        self.assertEqual(win_probe.diff_images(a, a, 20, 20)["changed_ratio"], 0.0)
        self.assertFalse(win_probe.diff_images(a, None, 20, 20)["comparable"])
        self.assertFalse(win_probe.diff_images(a, b"\x00" * 4, 20, 20)["comparable"])
        white = bgra((255, 255, 255, 255), 20, 20)
        diff = win_probe.diff_images(a, white, 20, 20)
        self.assertTrue(diff["comparable"])
        self.assertEqual(diff["changed_ratio"], 1.0)
        self.assertGreater(diff["mean_abs_diff"], 200)


class HwndConversionTest(unittest.TestCase):
    """回调里的句柄既可能是 int 也可能是 c_void_p，int(c_void_p) 会直接 ValueError。"""

    def test_accepts_int_and_void_pointer(self):
        self.assertEqual(win_probe.hwnd_int(4096), 4096)
        self.assertEqual(win_probe.hwnd_int(ctypes.c_void_p(4096)), 4096)
        self.assertEqual(win_probe.hwnd_int(ctypes.c_void_p(None)), 0)
        self.assertEqual(win_probe.hwnd_int(None), 0)


class CandidateTest(unittest.TestCase):
    def test_matches_exe_title_and_engine_class(self):
        keywords = ("mygame",)
        titles = ("梦幻西游",)
        self.assertTrue(win_probe._looks_like_candidate(
            "MyGame_x64r.exe", "", "", keywords, titles))
        self.assertTrue(win_probe._looks_like_candidate(
            "other.exe", "梦幻西游：时空", "", keywords, titles))
        self.assertTrue(win_probe._looks_like_candidate(
            "other.exe", "", "MessiahWindow", keywords, titles))
        self.assertTrue(win_probe._looks_like_candidate(
            "other.exe", "", "MyGameRenderWnd", keywords, titles))
        self.assertFalse(win_probe._looks_like_candidate(
            "explorer.exe", "Program Manager", "Progman", keywords, titles))


def _as_int(value):
    """真机里 HWND 由 ctypes 传成 int；假 API 要自己解掉 c_void_p 包装。"""
    return int(getattr(value, "value", value))


class FakePointer:
    """够用的假 user32：只实现 list_windows 用到的部分。"""

    def __init__(self, windows, foreground):
        self.windows = windows
        self.foreground = foreground

    def GetForegroundWindow(self):
        return self.foreground

    def IsWindowVisible(self, hwnd):
        return bool(self.windows[_as_int(hwnd)]["visible"])

    def IsIconic(self, hwnd):
        return bool(self.windows[_as_int(hwnd)].get("minimized", False))

    def GetWindowLongW(self, hwnd, index):
        return int(self.windows[_as_int(hwnd)].get("style" if index == -16 else "exstyle", 0))

    def EnumWindows(self, callback, lparam):
        # callback 是真的 ctypes 回调对象：原型不匹配时回调体不会执行
        # （ctypes 吞掉异常），列表随之缺项，断言立刻失败
        for hwnd in list(self.windows):
            callback(hwnd, lparam)
        return True


class FakeProbeWin:
    def __init__(self, windows, foreground):
        self.user32 = FakePointer(windows, foreground)
        self.windows = windows

    def window_text(self, hwnd):
        return self.windows[_as_int(hwnd)].get("title", "")

    def class_name(self, hwnd):
        return self.windows[_as_int(hwnd)].get("class", "")

    def pid_of(self, hwnd):
        return self.windows[_as_int(hwnd)]["pid"]

    def process_path(self, pid):
        # 用正斜杠：测试在 macOS 上跑，os.path.basename 只认斜杠；
        # Windows 上真实路径是反斜杠，basename 同样成立。
        return "/games/shikong/%s" % ("MyGame_x64r.exe" if pid == 1111 else "other.exe")

    def client_rect(self, hwnd):
        return tuple(self.windows[_as_int(hwnd)]["client"])

    def window_rect(self, hwnd):
        left, top = self.windows[_as_int(hwnd)].get("origin", (0, 0))
        width, height = self.windows[_as_int(hwnd)]["client"]
        return (left, top, left + width, top + height)

    def dpi_of(self, hwnd):
        return 96


class ListWindowsTest(unittest.TestCase):
    def setUp(self):
        self.windows = {
            0x1000: {"title": "梦幻西游：时空", "class": "MessiahWindow", "pid": 1111,
                     "visible": True, "client": (1600, 900), "origin": (100, 60),
                     "style": win_probe.WS_THICKFRAME},
            0x2000: {"title": "", "class": "MessiahRenderChild", "pid": 1111,
                     "visible": True, "client": (1440, 810)},
            0x3000: {"title": "记事本", "class": "Notepad", "pid": 2222,
                     "visible": False, "client": (400, 300)},
            0x4000: {"title": "网易云音乐", "class": "Orpheus", "pid": 3333,
                     "visible": True, "client": (800, 600), "minimized": True},
        }
        self.previous = win_probe.WIN
        win_probe.WIN = FakeProbeWin(self.windows, foreground=0x1000)
        # 注意：这里**不能**把 win_probe.ENUMPROC 换成恒等函数。
        # 假 API 调用的就是真的 ctypes 回调对象，回调原型不匹配（比如误用 4 参数的
        # WNDPROC 包 2 参数的枚举回调）会立刻在这里暴露，而不是留到 Windows 实机上。
        self.addCleanup(self._restore)

    def _restore(self):
        win_probe.WIN = self.previous

    def test_filters_and_flags(self):
        result = win_probe.list_windows(("mygame",), ("梦幻西游",))
        by_hwnd = {item.hwnd: item for item in result}
        # 候选窗口（类名 MessiahWindow / 标题命中）
        self.assertIn(0x1000, by_hwnd)
        self.assertTrue(by_hwnd[0x1000].is_candidate)
        self.assertTrue(by_hwnd[0x1000].foreground)
        self.assertTrue(by_hwnd[0x1000].resizable)
        self.assertEqual((by_hwnd[0x1000].client_width, by_hwnd[0x1000].client_height),
                         (1600, 900))
        self.assertEqual(by_hwnd[0x1000].exe_name, "MyGame_x64r.exe")
        # 不可见窗口被跳过
        self.assertNotIn(0x3000, by_hwnd)
        # 有标题但不是候选的窗口仍会列出（噪声很大，但是事实）
        self.assertIn(0x4000, by_hwnd)
        self.assertFalse(by_hwnd[0x4000].is_candidate)
        self.assertTrue(by_hwnd[0x4000].minimized)

    def test_include_all_keeps_untitled_windows(self):
        result = win_probe.list_windows(("mygame",), ("梦幻西游",), include_all=True)
        hwnds = {item.hwnd for item in result}
        self.assertIn(0x2000, hwnds)  # 无标题、非候选，include_all 时才出现

    def test_window_info_is_json_serializable(self):
        import dataclasses
        import json

        result = win_probe.list_windows(("mygame",), ("梦幻西游",), include_all=True)
        payload = json.dumps([dataclasses.asdict(item) for item in result], ensure_ascii=False)
        self.assertIn("梦幻西游", payload)


class ArgParserTest(unittest.TestCase):
    """文档里让用户敲的参数必须真的存在。"""

    def parse(self, argv):
        return win_probe.build_arg_parser().parse_args(argv)

    def test_documented_flags(self):
        args = self.parse(["--resize", "1600x900", "--no-input", "--no-save-shots",
                           "--all-windows", "--interactive", "--yes"])
        self.assertEqual(args.resize, "1600x900")
        self.assertTrue(args.no_input)
        self.assertTrue(args.no_save_shots)
        self.assertTrue(args.all_windows)
        self.assertTrue(args.interactive)
        self.assertTrue(args.yes)
        self.assertFalse(args.list_only)

    def test_defaults_are_safe(self):
        args = self.parse([])
        self.assertEqual(args.out, "probe_out")
        self.assertEqual(args.click_x, -1)
        self.assertEqual(args.click_y, -1)
        self.assertEqual(args.text, "")
        self.assertEqual(args.exe_keyword, None)

    def test_auto_int_accepts_hex_and_decimal(self):
        self.assertEqual(win_probe.auto_int("12345"), 12345)
        self.assertEqual(win_probe.auto_int("0x1000"), 4096)
        with self.assertRaises(argparse.ArgumentTypeError):
            win_probe.auto_int("abc")

    def test_pid_and_hwnd_accept_hex(self):
        args = self.parse(["--pid", "0x10", "--hwnd", "0x2000"])
        self.assertEqual(args.pid, 16)
        self.assertEqual(args.hwnd, 0x2000)


class FakeGdi32:
    """极简 gdi32：GetDIBits 按 (像素下标, frame_seed) 生成确定性图案。

    同一个 seed 两帧完全一致（基线=0），seed 变了就整帧不同（点击"生效"）。
    """

    def CreateCompatibleDC(self, hdc):
        return 11

    def CreateCompatibleBitmap(self, hdc, width, height):
        return 12

    def SelectObject(self, dc, obj):
        return 13

    def DeleteObject(self, obj):
        return 1

    def DeleteDC(self, dc):
        return 1

    def BitBlt(self, *args):
        return 1

    def GetDIBits(self, dc, bmp, start, lines, bits, bi, usage):
        header = ctypes.cast(bi, ctypes.POINTER(win_probe.BITMAPINFO)).contents.bmiHeader
        width = int(header.biWidth)
        height = abs(int(header.biHeight)) or int(lines)
        seed = self.owner.frame_seed
        data = bytearray()
        for index in range(width * height):
            data += bytes(((index + seed) % 256, (index * 3 + seed) % 256,
                           (index * 7 + seed) % 256, 255))
        ctypes.memmove(bits, bytes(data), len(data))
        return height

    def __init__(self, owner):
        self.owner = owner


class FakeUser32:
    def __init__(self, owner):
        self.owner = owner

    # -- 窗口枚举 --
    def GetForegroundWindow(self):
        return self.owner.foreground

    def IsWindowVisible(self, hwnd):
        return bool(self.owner.windows[_as_int(hwnd)]["visible"])

    def IsIconic(self, hwnd):
        return bool(self.owner.windows[_as_int(hwnd)].get("minimized", False))

    def GetWindowLongW(self, hwnd, index):
        return int(self.owner.windows[_as_int(hwnd)].get(
            "style" if index == -16 else "exstyle", 0))

    def EnumWindows(self, callback, lparam):
        for hwnd in list(self.owner.windows):
            if self.owner.windows[hwnd].get("top", True):
                callback(hwnd, lparam)
        return True

    def EnumChildWindows(self, hwnd, callback, lparam):
        for child in self.owner.children.get(_as_int(hwnd), []):
            callback(child, lparam)
        return True

    def GetSystemMetrics(self, index):
        # 0/1 = 主屏宽高；76..79 = 虚拟屏幕（供 SendInput 绝对坐标归一化）
        metrics = {0: 1920, 1: 1080, 76: 0, 77: 0, 78: 1920, 79: 1080}
        return metrics.get(int(index), 0)

    # -- 截图 --
    def GetDC(self, hwnd):
        return 21

    def GetWindowDC(self, hwnd):
        return 22

    def ReleaseDC(self, hwnd, dc):
        return 1

    def PrintWindow(self, hwnd, dc, flags):
        return 1 if self.owner.printwindow_ok else 0

    # -- 输入 / 尺寸 --
    def PostMessageW(self, hwnd, msg, wparam, lparam):
        self.owner.posted.append((_as_int(hwnd), msg))
        if msg == 0x0201:  # WM_LBUTTONDOWN：点击改变了画面
            self.owner.frame_seed += 97
        return 1

    def SendMessageW(self, hwnd, msg, wparam, lparam):
        self.owner.posted.append((_as_int(hwnd), msg))
        if msg == 0x0201:
            self.owner.frame_seed += 97
        return 1

    def SendInput(self, count, inputs, size):
        self.owner.frame_seed += 97
        return count

    def SetWindowPos(self, hwnd, insert_after, x, y, width, height, flags):
        self.owner.windows[_as_int(hwnd)]["client"] = (width, height)
        for child in self.owner.children.get(_as_int(hwnd), []):
            self.owner.windows[child]["client"] = (width - 160, height - 90)
        return 1

    def AdjustWindowRectEx(self, rect, style, menu, exstyle):
        return 1

    def SetForegroundWindow(self, hwnd):
        return 1

    def ShowWindow(self, hwnd, cmd):
        return 1

    def ClientToScreen(self, hwnd, point):
        origin = self.owner.windows[_as_int(hwnd)].get("origin", (0, 0))
        point._obj.x += origin[0]
        point._obj.y += origin[1]
        return 1

    def GetClientRect(self, hwnd, rect):
        width, height = self.owner.windows[_as_int(hwnd)]["client"]
        rect._obj.left, rect._obj.top = 0, 0
        rect._obj.right, rect._obj.bottom = width, height
        return 1

    def BringWindowToTop(self, hwnd):
        return 1

    def GetCursorPos(self, point):
        point._obj.x, point._obj.y = 100, 100
        return 1

    def SetCursorPos(self, x, y):
        return 1

    # -- 剪贴板 --
    def OpenClipboard(self, hwnd):
        return 1

    def EmptyClipboard(self):
        return 1

    def CloseClipboard(self):
        return 1

    def SetClipboardData(self, fmt, handle):
        self.owner.clipboard = (fmt, handle)
        return handle

    # -- 无关但可能被调用 --
    def DefineDosDeviceW(self, *args):
        return 1


class FakeKernel32:
    """GlobalLock 必须返回真正可写的内存地址，否则 memmove 会直接段错误。"""

    def __init__(self):
        self.buffers = {}

    def GetModuleHandleW(self, name):
        return 1

    def GlobalAlloc(self, flags, size):
        handle = len(self.buffers) + 1
        self.buffers[handle] = ctypes.create_string_buffer(max(int(size), 1))
        return handle

    def GlobalLock(self, handle):
        buffer = self.buffers.get(handle)
        return ctypes.addressof(buffer) if buffer is not None else 0

    def GlobalUnlock(self, handle):
        return 1

    def CloseHandle(self, handle):
        return 1


class FakeShell32:
    def IsUserAnAdmin(self):
        return 1


class FullFakeProbeWin:
    """够跑 tools/win_probe.py 主流程的假 Win32（截图/输入/尺寸都覆盖）。"""

    def __init__(self, with_game: bool = True, printwindow_ok: bool = True):
        self.windows = {}
        self.children = {}
        self.foreground = 0
        self.frame_seed = 0
        self.posted = []
        self.system_metrics = (1920, 1080, 0)
        self.printwindow_ok = printwindow_ok
        if with_game:
            self.windows[0x1000] = {
                "title": "梦幻西游：时空", "class": "MessiahWindow", "pid": 1111,
                "visible": True, "client": (1600, 900), "origin": (100, 60),
                "style": win_probe.WS_THICKFRAME, "top": True,
            }
            self.windows[0x1001] = {
                "title": "", "class": "MessiahRenderChild", "pid": 1111,
                "visible": True, "client": (1440, 810), "top": False,
            }
            self.children[0x1000] = [0x1001]
            self.foreground = 0x1000
        self.user32 = FakeUser32(self)
        self.gdi32 = FakeGdi32(self)
        self.kernel32 = FakeKernel32()
        self.clipboard = None
        self.shell32 = FakeShell32()

    # -- Win32 包装层 --
    def set_dpi_aware(self):
        return "假 DPI 感知"

    def is_admin(self):
        return True

    def window_text(self, hwnd):
        return self.windows[_as_int(hwnd)].get("title", "")

    def class_name(self, hwnd):
        return self.windows[_as_int(hwnd)].get("class", "")

    def pid_of(self, hwnd):
        return self.windows[_as_int(hwnd)]["pid"]

    def process_path(self, pid):
        return "/games/shikong/MyGame_x64r.exe"

    def client_rect(self, hwnd):
        return tuple(self.windows[_as_int(hwnd)]["client"])

    def window_rect(self, hwnd):
        left, top = self.windows[_as_int(hwnd)].get("origin", (0, 0))
        width, height = self.windows[_as_int(hwnd)]["client"]
        return (left, top, left + width, top + height)

    def dpi_of(self, hwnd):
        return 96


class ProbeMainTest(unittest.TestCase):
    """main() 是要交付给用户跑的第一条命令，报告必须能写出来。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.previous_win = win_probe.WIN
        self.previous_win32 = win_probe.Win32
        self.previous_is_windows = win_probe.IS_WINDOWS
        win_probe.IS_WINDOWS = True          # 让 main 走 Windows 分支
        # 同 ListWindowsTest：不替换 ENUMPROC，让假 API 走真的 ctypes 回调原型
        self.fake = FullFakeProbeWin()
        win_probe.WIN = self.fake
        # main() 里会 WIN = Win32()：把工厂也换掉（真机上才是真的 ctypes.WinDLL）
        win_probe.Win32 = lambda: self.fake
        self.addCleanup(self._restore)

    def _restore(self):
        win_probe.WIN = self.previous_win
        win_probe.Win32 = self.previous_win32
        win_probe.IS_WINDOWS = self.previous_is_windows

    def run_probe(self, *args):
        argv = ["--out", self.tmp.name, *args]
        with contextlib.redirect_stdout(io.StringIO()):
            code = win_probe.main(argv)
        return code

    def report(self):
        with open(os.path.join(self.tmp.name, "win_probe_report.json"), encoding="utf-8") as fh:
            return json.load(fh)

    def test_list_only(self):
        self.assertEqual(self.run_probe("--list-only"), 0)
        report = self.report()
        self.assertEqual(report["meta"]["admin"], True)
        self.assertEqual(report["meta"]["screen"], [1920, 1080])
        self.assertEqual(len(report["targets"]), 0)
        self.assertEqual(len(report["windows"]), 1)
        self.assertEqual(report["windows"][0]["class_name"], "MessiahWindow")

    def test_report_carries_dependency_versions(self):
        self.assertEqual(self.run_probe("--list-only"), 0)
        deps = self.report()["meta"]["deps"]
        for key in ("executable", "scriptsDir", "numpy", "opencv", "rapidocr"):
            self.assertIn(key, deps)
        self.assertTrue(deps["executable"])
        self.assertEqual(deps["numpy"], win_probe.dependency_versions()["numpy"])

    def test_capture_suite_and_report(self):
        code = self.run_probe("--no-input", "--no-occlusion", "--no-save-shots")
        self.assertEqual(code, 0)
        report = self.report()
        suite = next(iter(report["capture"].values()))
        self.assertEqual(len(suite["methods"]), len(win_probe.CAPTURE_METHODS))
        self.assertTrue(suite["best"])
        for entry in suite["methods"]:
            self.assertTrue(entry["ok"], entry)
        target = report["targets"][0]
        self.assertEqual(target["client_size"], [1600, 900])
        self.assertEqual(target["children"][0]["hwnd"], 0x1001)
        self.assertEqual(target["children"][0]["client_size"], [1440, 810])
        self.assertTrue(target["resizable"])

    def test_capture_failure_is_reported_not_crashed(self):
        win_probe.WIN.printwindow_ok = False
        win_probe.WIN.user32.GetDC = lambda hwnd: 0   # 连 BitBlt 也拿不到 DC
        code = self.run_probe("--no-input", "--no-occlusion", "--no-save-shots")
        self.assertEqual(code, 0)
        report = self.report()
        suite = next(iter(report["capture"].values()))
        self.assertFalse(suite["best"])
        for entry in suite["methods"]:
            self.assertFalse(entry["ok"])

    def test_resize_target(self):
        code = self.run_probe("--no-capture", "--no-input", "--no-occlusion",
                              "--resize", "1600x900")
        self.assertEqual(code, 0)
        resize = next(iter(self.report()["resize"].values()))
        self.assertEqual(resize["target_client"], [1600, 900])
        self.assertEqual(resize["after_client"], [1600, 900])
        self.assertTrue(resize["matched"])

    def test_input_effectiveness_detection(self):
        code = self.run_probe("--no-occlusion", "--no-save-shots", "--yes")
        self.assertEqual(code, 0)
        data = next(iter(self.report()["input"].values()))
        self.assertEqual(data["baseline"]["changed_ratio"], 0.0)
        for method, _fn in win_probe.INPUT_METHODS:
            entry = data[method]
            self.assertIn("diff", entry, method)
            self.assertTrue(entry["likely_effective"], method)
            self.assertGreater(entry["diff"]["changed_ratio"], 0.5)
        # 三种方式"都生效"时按顺序推荐第一个
        self.assertEqual(data["recommendation"], "postmessage")

    def test_keyboard_section(self):
        code = self.run_probe("--no-input", "--no-occlusion", "--no-save-shots",
                              "--yes", "--text", "ok")
        self.assertEqual(code, 0)
        keyboard = next(iter(self.report()["keyboard"].values()))
        self.assertEqual(keyboard["text"], "ok")
        self.assertIn("wm_char_diff", keyboard)
        self.assertIn("unicode_diff", keyboard)
        self.assertTrue(keyboard["clipboard_fallback_available"])

    def test_no_candidate_window_exits_nonzero(self):
        # main() 内部会 WIN = Win32()，所以要换掉假实例本身（工厂读的是 self.fake）
        self.fake = FullFakeProbeWin(with_game=False)
        code = self.run_probe("--no-input", "--no-occlusion")
        self.assertEqual(code, 1)
        report = self.report()
        self.assertEqual(report["targets"], [])
        self.assertEqual(report["capture"], {})

    def test_zero_windows_is_reported_as_broken_enumeration(self):
        """枚举到 0 个顶层窗口 ≠ 客户端没启动。

        交互式桌面上永远有顶层窗口，一个都没有只能是枚举机制本身失效
        （ctypes 回调报错、进程不在交互式桌面会话）。报告必须把这条讲清楚，
        否则会把人带去"重启游戏"的错误方向——实机验收报告里就这么误导过一次。
        """
        self.fake = FullFakeProbeWin(with_game=False)
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = win_probe.main(["--out", self.tmp.name, "--no-input", "--no-occlusion"])
        self.assertEqual(code, 1)
        scan = self.report()["meta"]["windowScan"]
        self.assertEqual(scan["totalTopLevel"], 0)
        self.assertTrue(scan["enumerationBroken"])
        output = buffer.getvalue()
        self.assertIn("枚举机制本身失效", output)
        self.assertNotIn("客户端已经启动", output)

    def test_window_scan_is_recorded_when_windows_exist(self):
        self.assertEqual(self.run_probe("--no-input", "--no-occlusion", "--no-save-shots"), 0)
        scan = self.report()["meta"]["windowScan"]
        self.assertGreater(scan["totalTopLevel"], 0)
        self.assertFalse(scan["enumerationBroken"])

    def test_section_error_still_writes_report(self):
        """任何一段出错都必须留下报告，否则这趟实机就白跑了。"""

        def boom(*_args, **_kwargs):
            raise RuntimeError("假的遮挡失败")

        original = win_probe.test_occlusion
        self.addCleanup(lambda: setattr(win_probe, "test_occlusion", original))
        win_probe.test_occlusion = boom

        code = self.run_probe("--no-input", "--no-save-shots")
        self.assertEqual(code, 0)
        report = self.report()
        tag = next(iter(report["occlusion"]))
        self.assertIn("假的遮挡失败", report["occlusion"][tag]["error"])
        self.assertIn("traceback", report["occlusion"][tag])
        # 其它段不受影响
        self.assertTrue(next(iter(report["capture"].values()))["best"])
        self.assertEqual(len(report["targets"]), 1)

    def test_capture_section_error_does_not_stop_other_sections(self):
        def boom(*_args, **_kwargs):
            raise RuntimeError("假的截图段失败")

        original = win_probe.run_capture_suite
        self.addCleanup(lambda: setattr(win_probe, "run_capture_suite", original))
        win_probe.run_capture_suite = boom

        code = self.run_probe("--no-occlusion", "--no-save-shots", "--yes",
                              "--resize", "1600x900")
        self.assertEqual(code, 0)
        report = self.report()
        tag = next(iter(report["capture"]))
        self.assertIn("假的截图段失败", report["capture"][tag]["error"])
        # 截图段挂了，后面的尺寸/输入段照样跑
        self.assertTrue(report["resize"], report)
        self.assertTrue(report["input"], report)

    def test_all_windows_flag_keeps_everything(self):
        code = self.run_probe("--list-only", "--all-windows")
        self.assertEqual(code, 0)
        self.assertGreaterEqual(len(self.report()["windows"]), 1)


class PlatformGuardTest(unittest.TestCase):
    def test_main_refuses_on_non_windows(self):
        if win_probe.IS_WINDOWS:
            self.skipTest("Windows 上由实机验证")
        self.assertEqual(win_probe.main(["--list-only"]), 2)


if __name__ == "__main__":
    unittest.main()
