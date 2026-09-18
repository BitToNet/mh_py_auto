#!/usr/bin/env python3
# coding=utf-8
"""《梦幻西游：时空》Windows 客户端 —— 控制层探测工具（P1 阶段）

目的：在实机上回答四个问题
  1. 时空客户端窗口怎么识别（标题/类名/进程/子窗口）
  2. 哪种截图方式能拿到真实画面（后台/被遮挡/最小化时是否也能截）
  3. 哪种点击方式真的生效（后台消息 vs 前台真实输入）
  4. 窗口能不能被改成 1600x900 客户区（决定能否复用现有模板与坐标）

特点：纯 ctypes + 标准库实现，不需要安装任何第三方包。
用法：见 tools/README_win_probe.md

输出：
  <out>/win_probe_report.json   结构化结论
  <out>/probe_shots/*.bmp       各方法截图（可直接当模板素材）

风险提示：输入测试会真的点击游戏窗口。请先在游戏里切到一个"点了也没事"的界面
（例如空地上的场景视角），并确认当前没有正在进行的战斗/交易。
"""

from __future__ import annotations

import argparse
import ctypes
import json
import os
import platform
import sys
import threading
import time
import traceback
from dataclasses import asdict, dataclass, field
from typing import Any, Callable, Dict, List, Optional, Sequence, Tuple

IS_WINDOWS = os.name == "nt"

# --------------------------------------------------------------------------------------
# 基础类型（不用 ctypes.wintypes，保证非 Windows 平台也能 import / 语法检查）
# --------------------------------------------------------------------------------------
HWND = ctypes.c_void_p
HDC = ctypes.c_void_p
HBITMAP = ctypes.c_void_p
HGDIOBJ = ctypes.c_void_p
HINSTANCE = ctypes.c_void_p
HMENU = ctypes.c_void_p
HICON = ctypes.c_void_p
HCURSOR = ctypes.c_void_p
HBRUSH = ctypes.c_void_p
LPCWSTR = ctypes.c_wchar_p
LPWSTR = ctypes.c_wchar_p
BOOL = ctypes.c_int
DWORD = ctypes.c_uint32
UINT = ctypes.c_uint32
LONG = ctypes.c_int32
WORD = ctypes.c_uint16
WPARAM = ctypes.c_size_t
LPARAM = ctypes.c_ssize_t
LRESULT = ctypes.c_ssize_t
ULONG_PTR = ctypes.c_size_t
WNDPROC = getattr(ctypes, "WINFUNCTYPE", ctypes.CFUNCTYPE)(LRESULT, HWND, UINT, WPARAM, LPARAM)
# EnumWindows / EnumChildWindows 的回调（EnumWindowsProc）只有 **两个** 参数：(HWND, LPARAM)。
# 它和窗口过程 WNDPROC（4 个参数）不能混用：ctypes 按原型传参，用 WNDPROC 包出来的回调
# 会用 4 个参数去调用 2 个参数的 Python 函数，真机上直接 TypeError；回调里的异常被 ctypes
# 吞掉并返回 0，EnumWindows 便认为"要求停止"立刻返回 → 窗口列表恒为空。
# 这正是实机报告里 "cb() takes 2 positional arguments but 4 were given" 的根因。
ENUMPROC = getattr(ctypes, "WINFUNCTYPE", ctypes.CFUNCTYPE)(BOOL, HWND, LPARAM)


class RECT(ctypes.Structure):
    _fields_ = [("left", LONG), ("top", LONG), ("right", LONG), ("bottom", LONG)]

    @property
    def width(self) -> int:
        return int(self.right - self.left)

    @property
    def height(self) -> int:
        return int(self.bottom - self.top)


class POINT(ctypes.Structure):
    _fields_ = [("x", LONG), ("y", LONG)]


class MSG(ctypes.Structure):
    """winuser.h 的 MSG；末尾多留一个 DWORD 以防不同 SDK 版本结构差异。"""

    _fields_ = [
        ("hwnd", HWND),
        ("message", UINT),
        ("wParam", WPARAM),
        ("lParam", LPARAM),
        ("time", DWORD),
        ("pt", POINT),
        ("lPrivate", DWORD),
    ]


class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [
        ("biSize", DWORD),
        ("biWidth", LONG),
        ("biHeight", LONG),
        ("biPlanes", WORD),
        ("biBitCount", WORD),
        ("biCompression", DWORD),
        ("biSizeImage", DWORD),
        ("biXPelsPerMeter", LONG),
        ("biYPelsPerMeter", LONG),
        ("biClrUsed", DWORD),
        ("biClrImportant", DWORD),
    ]


class BITMAPINFO(ctypes.Structure):
    _fields_ = [("bmiHeader", BITMAPINFOHEADER), ("bmiColors", DWORD * 3)]


class WNDCLASSEXW(ctypes.Structure):
    _fields_ = [
        ("cbSize", UINT),
        ("style", UINT),
        ("lpfnWndProc", WNDPROC),
        ("cbClsExtra", ctypes.c_int),
        ("cbWndExtra", ctypes.c_int),
        ("hInstance", HINSTANCE),
        ("hIcon", HICON),
        ("hCursor", HCURSOR),
        ("hbrBackground", HBRUSH),
        ("lpszMenuName", LPCWSTR),
        ("lpszClassName", LPCWSTR),
        ("hIconSm", HICON),
    ]


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [
        ("dx", LONG),
        ("dy", LONG),
        ("mouseData", DWORD),
        ("dwFlags", DWORD),
        ("time", DWORD),
        ("dwExtraInfo", ULONG_PTR),
    ]


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [
        ("wVk", WORD),
        ("wScan", WORD),
        ("dwFlags", DWORD),
        ("time", DWORD),
        ("dwExtraInfo", ULONG_PTR),
    ]


class HARDWAREINPUT(ctypes.Structure):
    _fields_ = [("uMsg", DWORD), ("wParamL", WORD), ("wParamH", WORD)]


class _INPUTUNION(ctypes.Union):
    _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT), ("hi", HARDWAREINPUT)]


class INPUT(ctypes.Structure):
    _fields_ = [("type", DWORD), ("u", _INPUTUNION)]


# --------------------------------------------------------------------------------------
# 常量
# --------------------------------------------------------------------------------------
PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
GWL_STYLE = -16
GWL_EXSTYLE = -20
WS_CAPTION = 0x00C00000
WS_THICKFRAME = 0x00040000
WS_POPUP = 0x80000000
WS_CHILD = 0x40000000
WS_VISIBLE = 0x10000000
WS_EX_TOPMOST = 0x00000008
WS_EX_TOOLWINDOW = 0x00000080
PW_CLIENTONLY = 0x00000001
PW_RENDERFULLCONTENT = 0x00000002
SRCCOPY = 0x00CC0020
CAPTUREBLT = 0x40000000
DIB_RGB_COLORS = 0
BI_RGB = 0
SWP_NOSIZE = 0x0001
SWP_NOMOVE = 0x0002
SWP_NOZORDER = 0x0004
SWP_FRAMECHANGED = 0x0020
SWP_SHOWWINDOW = 0x0040
SW_RESTORE = 9
SW_MINIMIZE = 6
HWND_BOTTOM = 1
HWND_TOP = 0
HWND_TOPMOST = -1
WM_MOUSEMOVE = 0x0200
WM_LBUTTONDOWN = 0x0201
WM_LBUTTONUP = 0x0202
WM_RBUTTONDOWN = 0x0204
WM_RBUTTONUP = 0x0205
WM_MOUSEWHEEL = 0x020A
WM_CHAR = 0x0102
WM_KEYDOWN = 0x0100
WM_KEYUP = 0x0101
WM_ACTIVATE = 0x0006
WM_SETFOCUS = 0x0007
WM_CLOSE = 0x0010
MK_LBUTTON = 0x0001
MOUSEEVENTF_MOVE = 0x0001
MOUSEEVENTF_LEFTDOWN = 0x0002
MOUSEEVENTF_LEFTUP = 0x0004
MOUSEEVENTF_ABSOLUTE = 0x8000
KEYEVENTF_KEYUP = 0x0002
KEYEVENTF_UNICODE = 0x0004
INPUT_MOUSE = 0
INPUT_KEYBOARD = 1
VK_CONTROL = 0x11
VK_V = 0x56
CF_UNICODETEXT = 13
GMEM_MOVEABLE = 0x0002

# 候选窗口的识别关键字（进程名 / 标题关键字），大小写不敏感
DEFAULT_EXE_KEYWORDS = ["mygame", "mypclauncher", "mylauncher", "mypreloader", "mygame_x64r"]
DEFAULT_TITLE_KEYWORDS = ["梦幻西游", "时空", "mhxy"]

SHOT_DIR_NAME = "probe_shots"
SAVE_SHOTS = True  # 由 --no-save-shots 关闭


def _maybe_save(out_dir: str, tag: str, name: str, buf: bytes, width: int, height: int) -> Optional[str]:
    if not SAVE_SHOTS:
        return None
    path = os.path.join(out_dir, SHOT_DIR_NAME, f"{tag}__{name}.bmp")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    save_bmp(path, buf, width, height)
    return os.path.relpath(path, out_dir)


# --------------------------------------------------------------------------------------
# Win32 绑定
# --------------------------------------------------------------------------------------
def declare_enum_prototypes(user32: Any) -> None:
    """声明枚举窗口用的回调原型。

    抽成模块级函数是为了能在 macOS 上单测：完整 ``Win32._declare`` 需要真正的
    Windows DLL，而这里给一个假 user32 就能验证 EnumWindows 用的确实是
    2 参数的 ENUMPROC（不是 4 参数的 WNDPROC）。
    """
    user32.EnumWindows.argtypes = [ENUMPROC, LPARAM]
    user32.EnumWindows.restype = BOOL
    user32.EnumChildWindows.argtypes = [HWND, ENUMPROC, LPARAM]
    user32.EnumChildWindows.restype = BOOL


class Win32:
    """按需加载 DLL，避免非 Windows 平台 import 报错。"""

    def __init__(self) -> None:
        if not IS_WINDOWS:
            raise RuntimeError("本工具只能在 Windows 上运行")
        self.user32 = ctypes.WinDLL("user32", use_last_error=True)
        self.gdi32 = ctypes.WinDLL("gdi32", use_last_error=True)
        self.kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        self.shell32 = ctypes.WinDLL("shell32", use_last_error=True)
        self._declare()

    # -- 原型声明，避免 64 位下指针被截断 --
    def _declare(self) -> None:
        u, g, k = self.user32, self.gdi32, self.kernel32

        declare_enum_prototypes(u)
        u.GetWindowTextLengthW.argtypes = [HWND]
        u.GetWindowTextLengthW.restype = ctypes.c_int
        u.GetWindowTextW.argtypes = [HWND, LPWSTR, ctypes.c_int]
        u.GetWindowTextW.restype = ctypes.c_int
        u.GetClassNameW.argtypes = [HWND, LPWSTR, ctypes.c_int]
        u.GetClassNameW.restype = ctypes.c_int
        u.GetWindowThreadProcessId.argtypes = [HWND, ctypes.POINTER(DWORD)]
        u.GetWindowThreadProcessId.restype = DWORD
        u.IsWindowVisible.argtypes = [HWND]
        u.IsWindowVisible.restype = BOOL
        u.IsIconic.argtypes = [HWND]
        u.IsIconic.restype = BOOL
        u.GetForegroundWindow.restype = HWND
        u.GetClientRect.argtypes = [HWND, ctypes.POINTER(RECT)]
        u.GetClientRect.restype = BOOL
        u.GetWindowRect.argtypes = [HWND, ctypes.POINTER(RECT)]
        u.GetWindowRect.restype = BOOL
        u.ClientToScreen.argtypes = [HWND, ctypes.POINTER(POINT)]
        u.ClientToScreen.restype = BOOL
        u.ScreenToClient.argtypes = [HWND, ctypes.POINTER(POINT)]
        u.ScreenToClient.restype = BOOL
        u.GetWindowLongW.argtypes = [HWND, ctypes.c_int]
        u.GetWindowLongW.restype = LONG
        u.GetSystemMetrics.argtypes = [ctypes.c_int]
        u.GetSystemMetrics.restype = ctypes.c_int
        u.PrintWindow.argtypes = [HWND, HDC, UINT]
        u.PrintWindow.restype = BOOL
        u.GetDC.argtypes = [HWND]
        u.GetDC.restype = HDC
        u.GetWindowDC.argtypes = [HWND]
        u.GetWindowDC.restype = HDC
        u.ReleaseDC.argtypes = [HWND, HDC]
        u.ReleaseDC.restype = ctypes.c_int
        u.SetWindowPos.argtypes = [HWND, HWND, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, UINT]
        u.SetWindowPos.restype = BOOL
        u.ShowWindow.argtypes = [HWND, ctypes.c_int]
        u.ShowWindow.restype = BOOL
        u.SetForegroundWindow.argtypes = [HWND]
        u.SetForegroundWindow.restype = BOOL
        u.PostMessageW.argtypes = [HWND, UINT, WPARAM, LPARAM]
        u.PostMessageW.restype = BOOL
        u.SendMessageW.argtypes = [HWND, UINT, WPARAM, LPARAM]
        u.SendMessageW.restype = LRESULT
        u.SendInput.argtypes = [UINT, ctypes.POINTER(INPUT), ctypes.c_int]
        u.SendInput.restype = UINT
        u.AdjustWindowRectEx.argtypes = [ctypes.POINTER(RECT), DWORD, BOOL, DWORD]
        u.AdjustWindowRectEx.restype = BOOL
        u.RegisterClassExW.argtypes = [ctypes.POINTER(WNDCLASSEXW)]
        u.RegisterClassExW.restype = ctypes.c_ushort
        u.CreateWindowExW.argtypes = [
            DWORD, LPCWSTR, LPCWSTR, DWORD, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
            HWND, HMENU, HINSTANCE, ctypes.c_void_p,
        ]
        u.CreateWindowExW.restype = HWND
        u.DestroyWindow.argtypes = [HWND]
        u.DestroyWindow.restype = BOOL
        u.DefWindowProcW.argtypes = [HWND, UINT, WPARAM, LPARAM]
        u.DefWindowProcW.restype = LRESULT
        u.PeekMessageW.argtypes = [ctypes.POINTER(MSG), HWND, UINT, UINT, UINT]
        u.PeekMessageW.restype = BOOL
        u.TranslateMessage.argtypes = [ctypes.POINTER(MSG)]
        u.DispatchMessageW.argtypes = [ctypes.POINTER(MSG)]
        u.DispatchMessageW.restype = LRESULT
        u.OpenClipboard.argtypes = [HWND]
        u.OpenClipboard.restype = BOOL
        u.CloseClipboard.restype = BOOL
        u.EmptyClipboard.restype = BOOL
        u.SetClipboardData.argtypes = [UINT, ctypes.c_void_p]
        u.SetClipboardData.restype = ctypes.c_void_p
        u.MapVirtualKeyW.argtypes = [UINT, UINT]
        u.MapVirtualKeyW.restype = UINT
        if hasattr(u, "GetDpiForWindow"):
            u.GetDpiForWindow.argtypes = [HWND]
            u.GetDpiForWindow.restype = UINT
        if hasattr(u, "SetProcessDpiAwarenessContext"):
            u.SetProcessDpiAwarenessContext.argtypes = [ctypes.c_void_p]
            u.SetProcessDpiAwarenessContext.restype = BOOL

        g.CreateCompatibleDC.argtypes = [HDC]
        g.CreateCompatibleDC.restype = HDC
        g.CreateCompatibleBitmap.argtypes = [HDC, ctypes.c_int, ctypes.c_int]
        g.CreateCompatibleBitmap.restype = HBITMAP
        g.SelectObject.argtypes = [HDC, HGDIOBJ]
        g.SelectObject.restype = HGDIOBJ
        g.DeleteObject.argtypes = [HGDIOBJ]
        g.DeleteObject.restype = BOOL
        g.DeleteDC.argtypes = [HDC]
        g.DeleteDC.restype = BOOL
        g.BitBlt.argtypes = [HDC, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, HDC, ctypes.c_int, ctypes.c_int, DWORD]
        g.BitBlt.restype = BOOL
        g.GetDIBits.argtypes = [HDC, HBITMAP, UINT, UINT, ctypes.c_void_p, ctypes.POINTER(BITMAPINFO), UINT]
        g.GetDIBits.restype = ctypes.c_int
        g.GetDeviceCaps.argtypes = [HDC, ctypes.c_int]
        g.GetDeviceCaps.restype = ctypes.c_int

        k.OpenProcess.argtypes = [DWORD, BOOL, DWORD]
        k.OpenProcess.restype = ctypes.c_void_p
        k.CloseHandle.argtypes = [ctypes.c_void_p]
        k.CloseHandle.restype = BOOL
        k.QueryFullProcessImageNameW.argtypes = [ctypes.c_void_p, DWORD, LPWSTR, ctypes.POINTER(DWORD)]
        k.QueryFullProcessImageNameW.restype = BOOL
        k.GetModuleHandleW.argtypes = [LPCWSTR]
        k.GetModuleHandleW.restype = HINSTANCE
        k.GlobalAlloc.argtypes = [UINT, ctypes.c_size_t]
        k.GlobalAlloc.restype = ctypes.c_void_p
        k.GlobalLock.argtypes = [ctypes.c_void_p]
        k.GlobalLock.restype = ctypes.c_void_p
        k.GlobalUnlock.argtypes = [ctypes.c_void_p]
        k.GlobalUnlock.restype = BOOL

    # -- 便捷方法 --
    def set_dpi_aware(self) -> str:
        """尽量让探测进程为 Per-Monitor V2 DPI 感知，否则坐标会被系统缩放。"""
        u = self.user32
        attempts = [
            ("PER_MONITOR_AWARE_V2", ctypes.c_void_p(-4)),
            ("PER_MONITOR_AWARE", ctypes.c_void_p(-2)),
            ("SYSTEM_AWARE", ctypes.c_void_p(-1)),
        ]
        for name, ctx in attempts:
            if hasattr(u, "SetProcessDpiAwarenessContext"):
                try:
                    if u.SetProcessDpiAwarenessContext(ctx):
                        return name
                except Exception:
                    pass
        try:
            ctypes.WinDLL("shcore").SetProcessDpiAwareness(2)
            return "SHCORE_PER_MONITOR"
        except Exception:
            pass
        try:
            u.SetProcessDPIAware()
            return "SYSTEM_AWARE_FALLBACK"
        except Exception:
            return "NONE"

    def is_admin(self) -> bool:
        try:
            return bool(self.shell32.IsUserAnAdmin())
        except Exception:
            return False

    def process_path(self, pid: int) -> str:
        h = self.kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
        if not h:
            return ""
        try:
            buf = ctypes.create_unicode_buffer(1024)
            size = DWORD(len(buf))
            if self.kernel32.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(size)):
                return buf.value
            return ""
        finally:
            self.kernel32.CloseHandle(h)

    def window_text(self, hwnd: int) -> str:
        length = self.user32.GetWindowTextLengthW(HWND(hwnd))
        if length <= 0:
            return ""
        buf = ctypes.create_unicode_buffer(length + 2)
        self.user32.GetWindowTextW(HWND(hwnd), buf, length + 2)
        return buf.value

    def class_name(self, hwnd: int) -> str:
        buf = ctypes.create_unicode_buffer(512)
        self.user32.GetClassNameW(HWND(hwnd), buf, 512)
        return buf.value

    def client_rect(self, hwnd: int) -> Tuple[int, int]:
        r = RECT()
        self.user32.GetClientRect(HWND(hwnd), ctypes.byref(r))
        return int(r.width), int(r.height)

    def window_rect(self, hwnd: int) -> Tuple[int, int, int, int]:
        r = RECT()
        self.user32.GetWindowRect(HWND(hwnd), ctypes.byref(r))
        return int(r.left), int(r.top), int(r.width), int(r.height)

    def pid_of(self, hwnd: int) -> int:
        pid = DWORD(0)
        self.user32.GetWindowThreadProcessId(HWND(hwnd), ctypes.byref(pid))
        return int(pid.value)

    def dpi_of(self, hwnd: int) -> int:
        if hasattr(self.user32, "GetDpiForWindow"):
            try:
                return int(self.user32.GetDpiForWindow(HWND(hwnd))) or 96
            except Exception:
                return 96
        return 96


WIN: Optional[Win32] = None


def win() -> Win32:
    assert WIN is not None
    return WIN


# --------------------------------------------------------------------------------------
# 图像工具：BMP 保存 + 简单分析
# --------------------------------------------------------------------------------------
def save_bmp(path: str, buf: bytes, width: int, height: int) -> None:
    """buf 为 top-down 32bpp BGRA；写成 24bpp 自下而上的 BMP。

    用切片级操作做 BGRA→BGR 与行序翻转，避免逐像素 Python 循环。
    """
    if width <= 0 or height <= 0 or len(buf) < width * height * 4:
        return
    b = buf[0::4]
    g = buf[1::4]
    r = buf[2::4]
    interleaved = bytearray(width * height * 3)
    interleaved[0::3] = b
    interleaved[1::3] = g
    interleaved[2::3] = r
    row_size = ((width * 3 + 3) // 4) * 4
    pad = row_size - width * 3
    rows = []
    for y in range(height - 1, -1, -1):  # BMP 自下而上
        rows.append(bytes(interleaved[y * width * 3:(y + 1) * width * 3]))
        if pad:
            rows.append(b"\x00" * pad)
    pixel_bytes = b"".join(rows)
    file_size = 54 + len(pixel_bytes)
    header = bytearray(54)
    header[0:2] = b"BM"
    header[2:6] = file_size.to_bytes(4, "little")
    header[10:14] = (54).to_bytes(4, "little")
    header[14:18] = (40).to_bytes(4, "little")
    header[18:22] = width.to_bytes(4, "little", signed=True)
    header[22:26] = height.to_bytes(4, "little", signed=True)
    header[26:28] = (1).to_bytes(2, "little")
    header[28:30] = (24).to_bytes(2, "little")
    header[34:38] = len(pixel_bytes).to_bytes(4, "little")
    with open(path, "wb") as fh:
        fh.write(bytes(header))
        fh.write(bytes(pixel_bytes))


def analyze_image(buf: bytes, width: int, height: int) -> Dict[str, Any]:
    """黑屏率 / 平均亮度 / 颜色数 / 唯一颜色采样。"""
    total = width * height
    if total <= 0 or len(buf) < total * 4:
        return {"valid": False}
    black = 0
    brightness_sum = 0
    colors = set()
    step = 1 if total <= 200_000 else max(1, total // 200_000)
    sampled = 0
    for i in range(0, total, step):
        off = i * 4
        b, g, r = buf[off], buf[off + 1], buf[off + 2]
        lum = (r * 299 + g * 587 + b * 114) // 1000
        brightness_sum += lum
        if r < 10 and g < 10 and b < 10:
            black += 1
        colors.add((r >> 3, g >> 3, b >> 3))
        sampled += 1
    return {
        "valid": True,
        "black_ratio": round(black / max(1, sampled), 4),
        "mean_brightness": round(brightness_sum / max(1, sampled), 2),
        "distinct_colors_sampled": len(colors),
        "sampled_pixels": sampled,
    }


def diff_images(a: Optional[bytes], b: Optional[bytes], width: int, height: int) -> Dict[str, Any]:
    """两帧差异：变化像素占比 + 平均绝对差。用于判断点击是否真的生效。"""
    if not a or not b or len(a) != len(b):
        return {"comparable": False}
    total = width * height
    changed = 0
    acc = 0
    step = 1 if total <= 200_000 else max(1, total // 200_000)
    sampled = 0
    for i in range(0, total, step):
        off = i * 4
        d = (
            abs(a[off] - b[off])
            + abs(a[off + 1] - b[off + 1])
            + abs(a[off + 2] - b[off + 2])
        ) // 3
        acc += d
        if d > 12:
            changed += 1
        sampled += 1
    return {
        "comparable": True,
        "changed_ratio": round(changed / max(1, sampled), 4),
        "mean_abs_diff": round(acc / max(1, sampled), 2),
    }


# --------------------------------------------------------------------------------------
# 窗口枚举
# --------------------------------------------------------------------------------------
@dataclass
class WindowInfo:
    hwnd: int
    title: str
    class_name: str
    pid: int
    exe: str
    exe_name: str
    client_width: int
    client_height: int
    window_rect: Tuple[int, int, int, int]
    visible: bool
    minimized: bool
    foreground: bool
    dpi: int
    style: int
    exstyle: int
    resizable: bool
    is_candidate: bool
    children: List[Dict[str, Any]] = field(default_factory=list)


def dependency_versions() -> Dict[str, Any]:
    """报告里带上依赖与解释器信息：实机排障时不用再问一轮"你装了吗"。"""
    info: Dict[str, Any] = {
        "executable": sys.executable,
        "scriptsDir": os.path.dirname(os.path.abspath(__file__)),
    }
    for module_name, key in (("numpy", "numpy"), ("cv2", "opencv"), ("rapidocr", "rapidocr")):
        try:
            module = __import__(module_name)
            info[key] = str(getattr(module, "__version__", "") or "unknown")
        except Exception:  # noqa: BLE001 - 缺包/加载失败都算不可用
            info[key] = None
    return info


def hwnd_int(value: Any) -> int:
    """回调用：句柄可能是 int，也可能是 c_void_p，两种都要能转。"""
    inner = getattr(value, "value", value)
    if inner is None:
        return 0
    return int(inner)


def _enum_child_windows(hwnd: int) -> List[Dict[str, Any]]:
    """EnumChildWindows 会枚举所有后代窗口，这里直接返回扁平列表。

    游戏的真正渲染窗口通常是一个子窗口，所以这份清单很重要。
    """
    out: List[Dict[str, Any]] = []
    w = win()

    def cb(child: int, _lparam: int) -> bool:
        cw, ch = w.client_rect(child)
        out.append({
            "hwnd": hwnd_int(child),
            "class_name": w.class_name(child),
            "title": w.window_text(child),
            "client_size": [cw, ch],
            "visible": bool(w.user32.IsWindowVisible(HWND(child))),
        })
        return True

    proc = ENUMPROC(cb)
    w.user32.EnumChildWindows(HWND(hwnd), proc, 0)
    return out


def _looks_like_candidate(exe_name: str, title: str, cls: str,
                          exe_keywords: Sequence[str], title_keywords: Sequence[str]) -> bool:
    exe_l = exe_name.lower()
    title_l = title.lower()
    cls_l = cls.lower()
    if any(k and k in exe_l for k in exe_keywords):
        return True
    if any(k and k in title_l for k in title_keywords):
        return True
    # Messiah 引擎窗口类名兜底
    if "messiah" in cls_l or "mygame" in cls_l:
        return True
    return False


def list_windows(exe_keywords: Sequence[str], title_keywords: Sequence[str],
                 include_all: bool = False) -> List[WindowInfo]:
    w = win()
    fg = w.user32.GetForegroundWindow()
    results: List[WindowInfo] = []

    def cb(hwnd: int, _lparam: int) -> bool:
        if not w.user32.IsWindowVisible(HWND(hwnd)):
            return True
        title = w.window_text(hwnd)
        cls = w.class_name(hwnd)
        pid = w.pid_of(hwnd)
        exe = w.process_path(pid)
        exe_name = os.path.basename(exe)
        # 没有标题且不是候选进程的窗口直接跳过，减少噪声
        candidate = _looks_like_candidate(exe_name, title, cls, exe_keywords, title_keywords)
        if not include_all and not candidate and not title:
            return True
        cw, ch = w.client_rect(hwnd)
        style = int(w.user32.GetWindowLongW(HWND(hwnd), GWL_STYLE))
        exstyle = int(w.user32.GetWindowLongW(HWND(hwnd), GWL_EXSTYLE))
        info = WindowInfo(
            hwnd=hwnd_int(hwnd),
            title=title,
            class_name=cls,
            pid=pid,
            exe=exe,
            exe_name=exe_name,
            client_width=cw,
            client_height=ch,
            window_rect=w.window_rect(hwnd),
            visible=True,
            minimized=bool(w.user32.IsIconic(HWND(hwnd))),
            foreground=bool(fg == hwnd),
            dpi=w.dpi_of(hwnd),
            style=style,
            exstyle=exstyle,
            resizable=bool(style & WS_THICKFRAME),
            is_candidate=candidate,
        )
        results.append(info)
        return True

    w.user32.EnumWindows(ENUMPROC(cb), 0)
    return results


# --------------------------------------------------------------------------------------
# 截图后端
# --------------------------------------------------------------------------------------
def _grab(hwnd: int, width: int, height: int, paint: Callable[[HDC], bool]) -> Optional[bytes]:
    w = win()
    if width <= 0 or height <= 0:
        return None
    hdc_src = w.user32.GetDC(HWND(hwnd))
    if not hdc_src:
        return None
    hdc_mem = w.gdi32.CreateCompatibleDC(hdc_src)
    hbmp = w.gdi32.CreateCompatibleBitmap(hdc_src, width, height)
    old = w.gdi32.SelectObject(hdc_mem, hbmp)
    try:
        if not paint(hdc_mem):
            return None
        bi = BITMAPINFO()
        bi.bmiHeader.biSize = ctypes.sizeof(BITMAPINFOHEADER)
        bi.bmiHeader.biWidth = width
        bi.bmiHeader.biHeight = -height  # top-down
        bi.bmiHeader.biPlanes = 1
        bi.bmiHeader.biBitCount = 32
        bi.bmiHeader.biCompression = BI_RGB
        buf = ctypes.create_string_buffer(width * height * 4)
        got = w.gdi32.GetDIBits(hdc_mem, hbmp, 0, height, ctypes.addressof(buf), ctypes.byref(bi), DIB_RGB_COLORS)
        if got == 0:
            return None
        return buf.raw
    finally:
        w.gdi32.SelectObject(hdc_mem, old)
        w.gdi32.DeleteObject(hbmp)
        w.gdi32.DeleteDC(hdc_mem)
        w.user32.ReleaseDC(HWND(hwnd), hdc_src)


def capture_printwindow(hwnd: int, flags: int) -> Optional[Tuple[bytes, int, int]]:
    w = win()
    width, height = w.client_rect(hwnd)
    if flags & PW_CLIENTONLY:
        pass
    else:
        # 非 CLIENTONLY 时以窗口整体尺寸为准
        _, _, width, height = w.window_rect(hwnd)
    buf = _grab(hwnd, width, height, lambda hdc: bool(w.user32.PrintWindow(HWND(hwnd), hdc, flags)))
    return (buf, width, height) if buf else None


def capture_bitblt(hwnd: int, use_window_dc: bool) -> Optional[Tuple[bytes, int, int]]:
    w = win()
    if use_window_dc:
        _, _, width, height = w.window_rect(hwnd)
    else:
        width, height = w.client_rect(hwnd)

    def paint(hdc_mem: HDC) -> bool:
        src = w.user32.GetWindowDC(HWND(hwnd)) if use_window_dc else w.user32.GetDC(HWND(hwnd))
        if not src:
            return False
        try:
            return bool(w.gdi32.BitBlt(hdc_mem, 0, 0, width, height, src, 0, 0, SRCCOPY | CAPTUREBLT))
        finally:
            w.user32.ReleaseDC(HWND(hwnd), src)

    buf = _grab(hwnd, width, height, paint)
    return (buf, width, height) if buf else None


CAPTURE_METHODS: List[Tuple[str, Callable[[int], Optional[Tuple[bytes, int, int]]]]] = [
    ("printwindow_renderfull", lambda h: capture_printwindow(h, PW_CLIENTONLY | PW_RENDERFULLCONTENT)),
    # 名字必须和 scripts/win/win_capture.py 的 METHODS 完全一致，
    # 否则"测出来的后端"和"运行时能选的后端"对不上（有契约测试盯着）。
    ("printwindow_client", lambda h: capture_printwindow(h, PW_CLIENTONLY)),
    ("printwindow_window", lambda h: capture_printwindow(h, 0)),
    ("bitblt_client", lambda h: capture_bitblt(h, False)),
    ("bitblt_window", lambda h: capture_bitblt(h, True)),
]


def run_capture_suite(hwnd: int, out_dir: str, tag: str) -> Dict[str, Any]:
    """逐个截图后端实测，返回每个方法的图像指标。"""
    methods: List[Dict[str, Any]] = []
    best_name: Optional[str] = None
    best_score = -1.0
    for name, fn in CAPTURE_METHODS:
        entry: Dict[str, Any] = {"method": name}
        t0 = time.perf_counter()
        try:
            result = fn(hwnd)
        except Exception as exc:  # noqa: BLE001
            entry.update({"ok": False, "error": repr(exc)})
            methods.append(entry)
            continue
        elapsed_ms = round((time.perf_counter() - t0) * 1000, 1)
        if not result:
            entry.update({"ok": False, "error": "返回空图像", "elapsed_ms": elapsed_ms})
            methods.append(entry)
            continue
        buf, cw, ch = result
        metrics = analyze_image(buf, cw, ch)
        # 有效性评分：非黑屏 + 颜色丰富 + 快
        score = (1.0 - float(metrics.get("black_ratio", 1.0))) * 2 + min(
            float(metrics.get("distinct_colors_sampled", 0)) / 500.0, 1.0
        ) - elapsed_ms / 5000.0
        entry.update({"ok": True, "size": [cw, ch], "elapsed_ms": elapsed_ms, "metrics": metrics,
                      "score": round(score, 3)})
        rel = _maybe_save(out_dir, tag, name, buf, cw, ch)
        if rel:
            entry["file"] = rel
        if score > best_score:
            best_score = score
            best_name = name
        methods.append(entry)
    return {"hwnd": hwnd_int(hwnd), "methods": methods, "best": best_name}


# --------------------------------------------------------------------------------------
# 输入后端
# --------------------------------------------------------------------------------------
def _lparam_point(x: int, y: int) -> int:
    return ((int(y) & 0xFFFF) << 16) | (int(x) & 0xFFFF)


def post_click(hwnd: int, x: int, y: int) -> None:
    w = win()
    lp = LPARAM(_lparam_point(x, y))
    w.user32.PostMessageW(HWND(hwnd), WM_MOUSEMOVE, 0, lp)
    time.sleep(0.03)
    w.user32.PostMessageW(HWND(hwnd), WM_LBUTTONDOWN, MK_LBUTTON, lp)
    time.sleep(0.05)
    w.user32.PostMessageW(HWND(hwnd), WM_LBUTTONUP, 0, lp)


def send_click(hwnd: int, x: int, y: int) -> None:
    w = win()
    lp = LPARAM(_lparam_point(x, y))
    w.user32.SendMessageW(HWND(hwnd), WM_MOUSEMOVE, 0, lp)
    time.sleep(0.03)
    w.user32.SendMessageW(HWND(hwnd), WM_LBUTTONDOWN, MK_LBUTTON, lp)
    time.sleep(0.05)
    w.user32.SendMessageW(HWND(hwnd), WM_LBUTTONUP, 0, lp)


def sendinput_click(hwnd: int, x: int, y: int, activate: bool = True) -> None:
    w = win()
    if activate:
        w.user32.ShowWindow(HWND(hwnd), SW_RESTORE)
        w.user32.SetForegroundWindow(HWND(hwnd))
        time.sleep(0.25)
    pt = POINT(x, y)
    w.user32.ClientToScreen(HWND(hwnd), ctypes.byref(pt))
    # 用虚拟屏幕范围做绝对坐标归一化，兼容多显示器/负坐标
    vx = w.user32.GetSystemMetrics(76)   # SM_XVIRTUALSCREEN
    vy = w.user32.GetSystemMetrics(77)   # SM_YVIRTUALSCREEN
    vw = max(1, w.user32.GetSystemMetrics(78) - 1)  # SM_CXVIRTUALSCREEN
    vh = max(1, w.user32.GetSystemMetrics(79) - 1)  # SM_CYVIRTUALSCREEN
    abs_x = int((pt.x - vx) * 65535 / vw)
    abs_y = int((pt.y - vy) * 65535 / vh)
    inputs = (INPUT * 3)()
    inputs[0].type = INPUT_MOUSE
    inputs[0].u.mi = MOUSEINPUT(abs_x, abs_y, 0, MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE, 0, 0)
    inputs[1].type = INPUT_MOUSE
    inputs[1].u.mi = MOUSEINPUT(abs_x, abs_y, 0, MOUSEEVENTF_LEFTDOWN | MOUSEEVENTF_ABSOLUTE, 0, 0)
    inputs[2].type = INPUT_MOUSE
    inputs[2].u.mi = MOUSEINPUT(abs_x, abs_y, 0, MOUSEEVENTF_LEFTUP | MOUSEEVENTF_ABSOLUTE, 0, 0)
    w.user32.SendInput(3, inputs, ctypes.sizeof(INPUT))


INPUT_METHODS: List[Tuple[str, Callable[[int, int, int], None]]] = [
    ("postmessage", post_click),
    ("sendmessage", send_click),
    ("sendinput", sendinput_click),
]


def send_wm_char_text(hwnd: int, text: str) -> None:
    w = win()
    for ch in text:
        w.user32.PostMessageW(HWND(hwnd), WM_CHAR, WPARAM(ord(ch)), 0)
        time.sleep(0.05)


def send_unicode_text(text: str) -> None:
    """SendInput + KEYEVENTF_UNICODE，等价于真实键盘输入。"""
    w = win()
    for ch in text:
        down = INPUT()
        down.type = INPUT_KEYBOARD
        down.u.ki = KEYBDINPUT(0, ord(ch), KEYEVENTF_UNICODE, 0, 0)
        up = INPUT()
        up.type = INPUT_KEYBOARD
        up.u.ki = KEYBDINPUT(0, ord(ch), KEYEVENTF_UNICODE | KEYEVENTF_KEYUP, 0, 0)
        arr = (INPUT * 2)(down, up)
        w.user32.SendInput(2, arr, ctypes.sizeof(INPUT))
        time.sleep(0.05)


def set_clipboard_text(text: str) -> bool:
    w = win()
    if not w.user32.OpenClipboard(None):
        return False
    try:
        w.user32.EmptyClipboard()
        size = (len(text) + 1) * ctypes.sizeof(ctypes.c_wchar)
        handle = w.kernel32.GlobalAlloc(GMEM_MOVEABLE, size)
        if not handle:
            return False
        ptr = w.kernel32.GlobalLock(handle)
        ctypes.memmove(ptr, ctypes.create_unicode_buffer(text), size)
        w.kernel32.GlobalUnlock(handle)
        w.user32.SetClipboardData(CF_UNICODETEXT, handle)
        return True
    finally:
        w.user32.CloseClipboard()


def send_ctrl_v() -> None:
    w = win()
    def key(vk: int, up: bool) -> INPUT:
        item = INPUT()
        item.type = INPUT_KEYBOARD
        item.u.ki = KEYBDINPUT(vk, 0, KEYEVENTF_KEYUP if up else 0, 0, 0)
        return item

    seq = (INPUT * 4)(key(VK_CONTROL, False), key(VK_V, False), key(VK_V, True), key(VK_CONTROL, True))
    w.user32.SendInput(4, seq, ctypes.sizeof(INPUT))


# --------------------------------------------------------------------------------------
# 遮挡窗口（验证被其它窗口盖住时还能不能截图）
# --------------------------------------------------------------------------------------
class CoverWindow(threading.Thread):
    """在目标窗口正上方盖一个置顶空白窗口，用于遮挡测试。"""

    def __init__(self, target_hwnd: int, hold_seconds: float = 2.5) -> None:
        super().__init__(daemon=True)
        self.target_hwnd = target_hwnd
        self.hold_seconds = hold_seconds
        self.ready = threading.Event()
        self._wndproc_ref = None

    def run(self) -> None:  # pragma: no cover - 仅 Windows 实机执行
        w = win()
        hinst = w.kernel32.GetModuleHandleW(None)
        class_name = f"ProbeCoverWindow_{os.getpid()}_{int(time.time())}"

        def wndproc(hwnd: int, msg: int, wparam: int, lparam: int) -> int:
            return w.user32.DefWindowProcW(HWND(hwnd), msg, wparam, lparam)

        self._wndproc_ref = WNDPROC(wndproc)
        wc = WNDCLASSEXW()
        wc.cbSize = ctypes.sizeof(WNDCLASSEXW)
        wc.style = 0
        wc.lpfnWndProc = self._wndproc_ref
        wc.hInstance = hinst
        wc.hbrBackground = HBRUSH(6)  # COLOR_WINDOW+1
        wc.lpszClassName = class_name
        if not w.user32.RegisterClassExW(ctypes.byref(wc)):
            return
        left, top, width, height = w.window_rect(self.target_hwnd)
        hwnd = w.user32.CreateWindowExW(
            WS_EX_TOPMOST | WS_EX_TOOLWINDOW, class_name, "probe cover",
            WS_POPUP | WS_VISIBLE, left, top, width, height, None, None, hinst, None,
        )
        if not hwnd:
            return
        w.user32.SetWindowPos(HWND(hwnd), HWND(HWND_TOPMOST), left, top, width, height, SWP_SHOWWINDOW)
        self.ready.set()
        deadline = time.time() + self.hold_seconds
        msg = MSG()
        while time.time() < deadline:
            while w.user32.PeekMessageW(ctypes.byref(msg), None, 0, 0, 1):
                w.user32.TranslateMessage(ctypes.byref(msg))
                w.user32.DispatchMessageW(ctypes.byref(msg))
            time.sleep(0.03)
        w.user32.DestroyWindow(HWND(hwnd))


# --------------------------------------------------------------------------------------
# 各项测试
# --------------------------------------------------------------------------------------
def test_occlusion(hwnd: int, out_dir: str, tag: str, capture_fn: Callable[[int], Optional[Tuple[bytes, int, int]]]) -> Dict[str, Any]:
    before = capture_fn(hwnd)
    cover = CoverWindow(hwnd)
    cover.start()
    cover.ready.wait(timeout=3)
    time.sleep(0.6)
    during = capture_fn(hwnd)
    cover.join(timeout=6)
    time.sleep(0.6)
    after = capture_fn(hwnd)
    out: Dict[str, Any] = {"cover_window_shown": cover.ready.is_set()}
    if before and during:
        buf_b, cw, ch = before
        buf_d, _, _ = during
        out["diff_before_vs_covered"] = diff_images(buf_b, buf_d, cw, ch)
        rel = _maybe_save(out_dir, tag, "covered", buf_d, cw, ch)
        if rel:
            out["covered_file"] = rel
        out["covered_metrics"] = analyze_image(buf_d, cw, ch)
    if after:
        out["after_restore_metrics"] = analyze_image(after[0], after[1], after[2])
    return out


def test_baseline_and_inputs(hwnd: int, out_dir: str, tag: str, click_point: Tuple[int, int],
                             capture_fn: Callable[[int], Optional[Tuple[bytes, int, int]]],
                             interactive: bool, delay: float = 1.2) -> Dict[str, Any]:
    """先测"什么都不做"的画面变化基线，再逐个输入方法对比。"""
    result: Dict[str, Any] = {"click_point": list(click_point)}

    def shot(name: str) -> Optional[Tuple[bytes, int, int]]:
        got = capture_fn(hwnd)
        if got:
            _maybe_save(out_dir, tag, name, got[0], got[1], got[2])
        return got

    base_a = shot("input_00_before")
    time.sleep(delay)
    base_b = shot("input_01_baseline_after")
    if base_a and base_b:
        result["baseline"] = diff_images(base_a[0], base_b[0], base_a[1], base_a[2])
    baseline_ratio = float(result.get("baseline", {}).get("changed_ratio", 0.0))

    x, y = click_point
    for name, fn in INPUT_METHODS:
        entry: Dict[str, Any] = {"method": name}
        before = shot(f"{name}_before")
        try:
            fn(hwnd, x, y)
        except Exception as exc:  # noqa: BLE001
            entry["error"] = repr(exc)
            result[name] = entry
            continue
        time.sleep(delay)
        after = shot(f"{name}_after")
        if before and after:
            diff = diff_images(before[0], after[0], before[1], before[2])
            entry["diff"] = diff
            entry["diff_vs_baseline"] = round(float(diff.get("changed_ratio", 0.0)) - baseline_ratio, 4)
            entry["likely_effective"] = bool(
                diff.get("comparable") and float(diff.get("changed_ratio", 0.0)) > max(0.002, baseline_ratio * 2.5)
            )
        if interactive:
            try:
                ans = input(f"    [{name}] 游戏界面出现预期变化了吗？(y/n，直接回车=未确认): ").strip().lower()
            except EOFError:
                ans = ""
            if ans:
                entry["user_confirmed"] = ans.startswith("y")
        result[name] = entry
    result["baseline_ratio"] = baseline_ratio
    result["recommendation"] = _pick_input_method(result)
    return result


def _pick_input_method(result: Dict[str, Any]) -> str:
    order = ["postmessage", "sendmessage", "sendinput"]
    confirmed = [m for m in order if result.get(m, {}).get("user_confirmed") is True]
    if confirmed:
        return confirmed[0]
    likely = [m for m in order if result.get(m, {}).get("likely_effective")]
    if likely:
        return likely[0]
    return ""


def test_keyboard(hwnd: int, out_dir: str, tag: str, text: str,
                  capture_fn: Callable[[int], Optional[Tuple[bytes, int, int]]]) -> Dict[str, Any]:
    result: Dict[str, Any] = {"text": text}
    before = capture_fn(hwnd)
    try:
        send_wm_char_text(hwnd, text)
    except Exception as exc:  # noqa: BLE001
        result["wm_char_error"] = repr(exc)
    time.sleep(0.8)
    mid = capture_fn(hwnd)
    if before and mid:
        _maybe_save(out_dir, tag, "kb_wmchar", mid[0], mid[1], mid[2])
        result["wm_char_diff"] = diff_images(before[0], mid[0], before[1], before[2])
    try:
        send_unicode_text(text)
    except Exception as exc:  # noqa: BLE001
        result["unicode_error"] = repr(exc)
    time.sleep(0.8)
    after = capture_fn(hwnd)
    if mid and after:
        _maybe_save(out_dir, tag, "kb_unicode", after[0], after[1], after[2])
        result["unicode_diff"] = diff_images(mid[0], after[0], mid[1], after[2])
    result["clipboard_fallback_available"] = set_clipboard_text(text)
    return result


def test_resize(hwnd: int, out_dir: str, tag: str, target_w: int, target_h: int,
                capture_fn: Callable[[int], Optional[Tuple[bytes, int, int]]]) -> Dict[str, Any]:
    w = win()
    before = w.client_rect(hwnd)
    style = int(w.user32.GetWindowLongW(HWND(hwnd), GWL_STYLE))
    exstyle = int(w.user32.GetWindowLongW(HWND(hwnd), GWL_EXSTYLE))
    rect = RECT(0, 0, target_w, target_h)
    ok_adjust = bool(w.user32.AdjustWindowRectEx(ctypes.byref(rect), style, False, exstyle))
    outer_w = int(rect.width)
    outer_h = int(rect.height)
    left, top, _, _ = w.window_rect(hwnd)
    ok_set = bool(
        w.user32.SetWindowPos(HWND(hwnd), None, left, top, outer_w, outer_h, SWP_NOZORDER | SWP_FRAMECHANGED)
    )
    time.sleep(0.8)
    after = w.client_rect(hwnd)
    result = {
        "target_client": [target_w, target_h],
        "before_client": list(before),
        "after_client": list(after),
        "adjust_ok": ok_adjust,
        "setwindowpos_ok": ok_set,
        "matched": list(after) == [target_w, target_h],
        "resizable_style": bool(style & WS_THICKFRAME),
    }
    got = capture_fn(hwnd)
    if got:
        rel = _maybe_save(out_dir, tag, "resized", got[0], got[1], got[2])
        if rel:
            result["resized_file"] = rel
        result["resized_metrics"] = analyze_image(got[0], got[1], got[2])
    return result


# --------------------------------------------------------------------------------------
# 主流程
# --------------------------------------------------------------------------------------
def auto_int(value: str) -> int:
    """支持 12345 与 0x00123456 两种写法。"""
    try:
        return int(value, 0)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"无法解析整数：{value}") from exc


def build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="《梦幻西游：时空》Windows 客户端控制层探测工具",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--out", default="probe_out", help="输出目录（默认 probe_out）")
    p.add_argument("--pid", type=auto_int, default=0, help="只测指定 PID 的实例")
    p.add_argument("--hwnd", type=auto_int, default=0, help="只测指定 HWND（支持 0x 前缀）")
    p.add_argument("--no-save-shots", action="store_true", help="不保存截图（只出报告，省磁盘）")
    p.add_argument("--exe-keyword", action="append", default=None,
                   help="叠加候选进程名关键字，可重复传")
    p.add_argument("--title-keyword", action="append", default=None,
                   help="叠加候选标题关键字，可重复传")
    p.add_argument("--list-only", action="store_true", help="只枚举窗口，不做任何测试")
    p.add_argument("--no-capture", action="store_true", help="跳过截图测试")
    p.add_argument("--no-input", action="store_true", help="跳过点击/键盘测试（不碰游戏）")
    p.add_argument("--no-occlusion", action="store_true", help="跳过遮挡测试")
    p.add_argument("--click-x", type=int, default=-1, help="点击测试的客户区 X（默认窗口中心）")
    p.add_argument("--click-y", type=int, default=-1, help="点击测试的客户区 Y（默认窗口中心）")
    p.add_argument("--text", default="", help="键盘注入测试文本（需先手动点开可输入框）")
    p.add_argument("--resize", default="", help="窗口尺寸测试目标，如 1600x900；留空=不做")
    p.add_argument("--interactive", action="store_true", help="每个点击方法结束后人工确认是否生效")
    p.add_argument("--yes", action="store_true", help="跳过输入测试的风险确认")
    p.add_argument("--all-windows", action="store_true", help="把枚举到的所有窗口都写进报告（默认只写候选）")
    return p


def _guarded(label: str, container: Dict[str, Any], tag: str,
             run: Callable[[], Any]) -> Any:
    """跑一个测试段并把结果写进报告：单段抛异常也要留下报告并继续后面的段。"""
    try:
        container[tag] = run()
    except Exception as exc:  # noqa: BLE001
        print(f"    ！{label} 段出错，已记录到报告并继续：{exc!r}")
        container[tag] = {"error": repr(exc), "traceback": traceback.format_exc()}
    return container.get(tag)


def _probe_one_target(info, tag: str, args, report: Dict[str, Any], out_dir: str,
                      do_input: bool, do_keyboard: bool) -> None:
    """对单个目标窗口跑完整套测试，结果写进 report（单段失败不影响其它段）。"""
    target_entry: Dict[str, Any] = {
        "hwnd": info.hwnd,
        "pid": info.pid,
        "title": info.title,
        "class_name": info.class_name,
        "exe": info.exe,
        "client_size": [info.client_width, info.client_height],
        "resizable": info.resizable,
        "dpi": info.dpi,
        "foreground": info.foreground,
        "minimized": info.minimized,
    }
    print("-" * 78)
    print(f"测试目标 pid={info.pid} hwnd=0x{info.hwnd:08X} 客户区={info.client_width}x{info.client_height}")
    print("-" * 78)

    # 子窗口树（游戏渲染子窗口经常才是可截图的那个）
    info.children = _guarded("子窗口枚举", report["children"], tag,
                             lambda: _enum_child_windows(info.hwnd)) or []
    if not isinstance(info.children, list):
        info.children = []
    target_entry["children"] = info.children
    if info.children:
        print("  子窗口：")
        for child in info.children:
            print(f"    - {child['class_name']!r} size={child['client_size']} "
                  f"visible={child['visible']} hwnd=0x{child['hwnd']:08X}")

    if not args.no_capture:
        print("  [截图] 逐后端实测…")
        suite = _guarded("截图", report["capture"], tag,
                         lambda: run_capture_suite(info.hwnd, out_dir, tag))
        for entry in (suite.get("methods") or []):
            if entry.get("ok"):
                m = entry["metrics"]
                print(f"    {entry['method']:<26} {entry['size'][0]}x{entry['size'][1]} "
                      f"黑屏率={m['black_ratio']:<6} 颜色数={m['distinct_colors_sampled']:<5} "
                      f"{entry['elapsed_ms']}ms")
            else:
                print(f"    {entry['method']:<26} 失败：{entry.get('error')}")
        print(f"    → 最佳后端：{suite.get('best') or '（无可用后端，请把本报告发回）'}")

        best_name = suite.get("best") or ""
        capture_fn = dict(CAPTURE_METHODS).get(best_name)
        if capture_fn is None:
            capture_fn = CAPTURE_METHODS[0][1]

        if not args.no_occlusion:
            print("  [遮挡] 用置顶空白窗口盖住游戏窗口，再截一次…")
            _guarded("遮挡", report["occlusion"], tag,
                     lambda: test_occlusion(info.hwnd, out_dir, tag, capture_fn))
            occ = report["occlusion"][tag]
            diff = occ.get("diff_before_vs_covered", {})
            print(f"    覆盖后画面变化比例={diff.get('changed_ratio')} "
                  f"(≈0 表示遮挡后仍能截到真实画面)")
    else:
        capture_fn = CAPTURE_METHODS[0][1]

    if args.resize:
        try:
            tw, th = (int(v) for v in args.resize.lower().split("x"))
        except Exception:
            print(f"  [尺寸] --resize 参数无法解析：{args.resize}")
        else:
            print(f"  [尺寸] 尝试把客户区改成 {tw}x{th}…")
            _guarded("尺寸", report["resize"], tag,
                     lambda: test_resize(info.hwnd, out_dir, tag, tw, th, capture_fn))
            rs = report["resize"][tag]
            print(f"    {rs['before_client']} → {rs['after_client']} "
                  f"matched={rs['matched']} 可调整={rs['resizable_style']}")

    if do_input:
        cx = args.click_x if args.click_x >= 0 else info.client_width // 2
        cy = args.click_y if args.click_y >= 0 else info.client_height // 2
        print(f"  [输入] 在客户区 ({cx},{cy}) 逐方法点击，检测画面变化…")
        _guarded("输入", report["input"], tag,
                 lambda: test_baseline_and_inputs(
                     info.hwnd, out_dir, tag, (cx, cy), capture_fn,
                     args.interactive))
        data = report["input"][tag]
        print(f"    基线变化比例={data.get('baseline_ratio')}")
        for name, _fn in INPUT_METHODS:
            entry = data.get(name, {})
            if "diff" in entry:
                print(f"    {name:<14} 变化比例={entry['diff'].get('changed_ratio'):<8} "
                      f"相对基线={entry.get('diff_vs_baseline'):<8} "
                      f"自动判定={'生效' if entry.get('likely_effective') else '未生效'}"
                      f"{' 人工确认=' + str(entry.get('user_confirmed')) if 'user_confirmed' in entry else ''}")
            else:
                print(f"    {name:<14} 失败：{entry.get('error')}")
        print(f"    → 建议输入后端：{data.get('recommendation') or '（需人工确认）'}")

    if do_keyboard:
        print(f"  [键盘] 注入文本 {args.text!r}（WM_CHAR / Unicode SendInput）…")
        _guarded("键盘", report["keyboard"], tag,
                 lambda: test_keyboard(info.hwnd, out_dir, tag, args.text, capture_fn))
        print(f"    {json.dumps(report['keyboard'][tag], ensure_ascii=False)}")

    report["targets"].append(target_entry)
    print()


def main(argv: Optional[Sequence[str]] = None) -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[attr-defined]
    except Exception:
        pass
    args = build_arg_parser().parse_args(argv)

    if not IS_WINDOWS:
        print("本工具只能在 Windows 上运行（当前平台：%s）。" % platform.platform())
        print("请在装有《梦幻西游：时空》客户端的 Windows 机器上执行：python tools\\win_probe.py")
        return 2

    global WIN, SAVE_SHOTS
    WIN = Win32()
    SAVE_SHOTS = not args.no_save_shots
    dpi_mode = WIN.set_dpi_aware()

    out_dir = os.path.abspath(args.out)
    os.makedirs(os.path.join(out_dir, SHOT_DIR_NAME), exist_ok=True)

    exe_keywords = list(DEFAULT_EXE_KEYWORDS) + list(args.exe_keyword or [])
    title_keywords = list(DEFAULT_TITLE_KEYWORDS) + list(args.title_keyword or [])

    print("=" * 78)
    print("时空客户端 Windows 控制层探测工具")
    print("=" * 78)
    print(f"平台        : {platform.platform()}")
    print(f"Python      : {sys.version.split()[0]}")
    print(f"管理员权限  : {'是' if WIN.is_admin() else '否（建议用管理员运行，否则可能无法控制以管理员启动的游戏）'}")
    print(f"DPI 感知    : {dpi_mode}")
    print(f"屏幕分辨率  : {WIN.user32.GetSystemMetrics(0)}x{WIN.user32.GetSystemMetrics(1)}")
    print(f"输出目录    : {out_dir}")
    print()

    windows = list_windows(
        exe_keywords,
        title_keywords,
        include_all=bool(args.all_windows or args.hwnd or args.pid),
    )
    candidates = [w for w in windows if w.is_candidate]
    total_windows = len(windows)
    # 交互式 Windows 桌面上永远存在可见顶层窗口（桌面、任务栏、输入法、其它程序），
    # 一个都枚举不到说明"枚举"这一步本身不成立：要么枚举回调/ctypes 层出错
    # （异常被 ctypes 吞掉，比如回调原型写错），要么本进程不在交互式桌面会话
    # （以服务、计划任务"不显示界面"方式运行）。这时把结论说成"客户端没启动"
    # 会把人带偏——实机验收报告里就出现过这种情况。
    enumeration_broken = total_windows == 0

    print(f"共枚举到 {total_windows} 个可见顶层窗口，其中候选 {len(candidates)} 个：")
    for idx, info in enumerate(candidates, 1):
        flag = " *前台*" if info.foreground else ""
        mini = " (最小化)" if info.minimized else ""
        print(f"  [{idx}] hwnd=0x{info.hwnd:08X} pid={info.pid} 类名={info.class_name!r}")
        print(f"      标题={info.title!r}")
        print(f"      进程={info.exe_name} 客户区={info.client_width}x{info.client_height} "
              f"dpi={info.dpi} 可调整={info.resizable}{flag}{mini}")
    if enumeration_broken:
        print()
        print("！！窗口枚举返回 0 个窗口：交互式 Windows 桌面上不可能出现这种情况。")
        print("   所以这不是「客户端没启动」，而是枚举机制本身失效：")
        print("   1) 枚举回调/ctypes 层报错（看本脚本输出里有没有 TypeError 之类 traceback）")
        print("   2) 本进程不在交互式桌面会话（以服务、计划任务「不显示界面」方式运行）")
        print("   3) 解释器位数 / 系统 DLL 异常")
        print("   请把完整输出一起反馈，先别去重启游戏。")
    elif not candidates:
        print()
        print("！！没有找到候选窗口。请确认：")
        print("   1) 《梦幻西游：时空》客户端已经启动并且是窗口化模式（不是最小化）")
        print("   2) 用管理员权限重新运行本脚本")
        print("   3) 若无标题窗口未被识别，可用 --exe-keyword/--title-keyword 指定关键字")
        print("   4) 或者加 --all-windows 看看完整窗口列表，再用 --hwnd 指定目标")
    print()

    # 目标窗口筛选
    targets = candidates
    if args.hwnd:
        targets = [w for w in windows if w.hwnd == args.hwnd]
    elif args.pid:
        targets = [w for w in windows if w.pid == args.pid]

    report: Dict[str, Any] = {
        "meta": {
            "time": time.strftime("%Y-%m-%d %H:%M:%S"),
            "platform": platform.platform(),
            "python": sys.version.split()[0],
            "admin": WIN.is_admin(),
            "dpi_mode": dpi_mode,
            "screen": [WIN.user32.GetSystemMetrics(0), WIN.user32.GetSystemMetrics(1)],
            "exe_keywords": exe_keywords,
            "title_keywords": title_keywords,
            "deps": dependency_versions(),
            # 枚举自检：0 个顶层窗口 = 枚举本身失效，不是"没找到游戏窗口"
            "windowScan": {
                "totalTopLevel": total_windows,
                "candidates": len(candidates),
                "enumerationBroken": enumeration_broken,
            },
        },
        "windows": [asdict(w) for w in (windows if args.all_windows else candidates)],
        "targets": [],
        "children": {},
        "capture": {},
        "occlusion": {},
        "resize": {},
        "input": {},
        "keyboard": {},
        "next": ("python tools/win_recommend.py --write  "
                 ":: 按本报告生成 config/win_backend.json"),
    }

    report_path = os.path.join(out_dir, "win_probe_report.json")

    def write_report() -> None:
        with open(report_path, "w", encoding="utf-8") as fh:
            json.dump(report, fh, ensure_ascii=False, indent=2)

    if args.list_only:
        write_report()
        print(f"已写入 {report_path}")
        return 0

    if not targets:
        write_report()
        print(f"已写入 {report_path}（没有可测目标）")
        return 1

    # 输入测试风险确认
    do_input = not args.no_input
    do_keyboard = bool(args.text.strip())
    if (do_input or do_keyboard) and not args.yes:
        print("！输入测试会真的操作游戏窗口（点击/按键）。")
        print("  请先把游戏切到一个点了也没关系的界面（例如站在空地上）。")
        try:
            confirm = input("  确认开始输入测试？(输入 yes 继续，其它任意键跳过): ").strip().lower()
        except EOFError:
            confirm = ""
        if confirm != "yes":
            do_input = False
            do_keyboard = False
            print("  已跳过输入测试。")
            print()

    for info in targets:
        tag = f"pid{info.pid}_hwnd{info.hwnd:08X}"
        try:
            _probe_one_target(info, tag, args, report, out_dir, do_input, do_keyboard)
        except Exception as exc:  # noqa: BLE001
            detail = traceback.format_exc()
            print(f"！目标 {tag} 探测过程中出错，已记录并继续下一个：{exc!r}")
            report.setdefault("targetErrors", {})[tag] = {
                "error": repr(exc),
                "traceback": detail,
            }

    write_report()

    print("=" * 78)
    print("结论汇总")
    print("=" * 78)
    for tag, suite in report["capture"].items():
        print(f"  {tag}: 截图后端 = {suite.get('best')}")
    for tag, data in report["input"].items():
        print(f"  {tag}: 输入后端 = {data.get('recommendation') or '（未自动判定，请以人工确认为准）'}")
    for tag, rs in report["resize"].items():
        print(f"  {tag}: 1600x900 归一化 = {'可行' if rs.get('matched') else '不可行，需要坐标缩放'}")
    print()
    print(f"报告：{report_path}")
    print(f"截图：{os.path.join(out_dir, SHOT_DIR_NAME)}")
    print("请把整个输出目录打包发回。")
    print()
    print("想一步到位（探测 + 推配置 + 冒烟 + 汇总报告）：")
    print(f"  python {os.path.join('tools', 'win_acceptance.py')}")
    print()
    print("下一步（可选）：直接按这份实测结果生成配置 ——")
    print(f"  python {os.path.join('tools', 'win_recommend.py')} --write")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
