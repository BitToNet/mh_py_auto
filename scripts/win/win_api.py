#!/usr/bin/env python3
# coding=utf-8
"""共享的 Win32 ctypes 绑定（时空客户端 Windows 版）。

设计要点：
* 非 Windows 平台 import 安全：DLL 只在 ``api()`` 首次调用时加载，
  这样 macOS/Linux 上也能跑单元测试（通过 ``set_api()`` 注入假实现）。
* 不做任何业务判断，只提供底层能力：窗口、进程、截图原语、输入原语、剪贴板。
"""

from __future__ import annotations

import ctypes
import os
import sys
import time
from typing import Any, Dict, List, Optional, Sequence, Tuple

IS_WINDOWS = os.name == "nt"

# --------------------------------------------------------------------------------------
# 基础类型
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
HHOOK = ctypes.c_void_p
HOOKPROC = getattr(ctypes, "WINFUNCTYPE", ctypes.CFUNCTYPE)(LRESULT, ctypes.c_int, WPARAM, LPARAM)


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


class MSLLHOOKSTRUCT(ctypes.Structure):
    """WH_MOUSE_LL / WH_KEYBOARD_LL 回调里 lParam 指向的结构（鼠标版）。"""

    _fields_ = [
        ("pt", POINT), ("mouseData", DWORD), ("flags", DWORD),
        ("time", DWORD), ("dwExtraInfo", ULONG_PTR),
    ]


class KBDLLHOOKSTRUCT(ctypes.Structure):
    _fields_ = [
        ("vkCode", DWORD), ("scanCode", DWORD), ("flags", DWORD),
        ("time", DWORD), ("dwExtraInfo", ULONG_PTR),
    ]


class MSG(ctypes.Structure):
    _fields_ = [
        ("hwnd", HWND), ("message", UINT), ("wParam", WPARAM), ("lParam", LPARAM),
        ("time", DWORD), ("pt", POINT), ("lPrivate", DWORD),
    ]


class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [
        ("biSize", DWORD), ("biWidth", LONG), ("biHeight", LONG), ("biPlanes", WORD),
        ("biBitCount", WORD), ("biCompression", DWORD), ("biSizeImage", DWORD),
        ("biXPelsPerMeter", LONG), ("biYPelsPerMeter", LONG), ("biClrUsed", DWORD),
        ("biClrImportant", DWORD),
    ]


class BITMAPINFO(ctypes.Structure):
    _fields_ = [("bmiHeader", BITMAPINFOHEADER), ("bmiColors", DWORD * 3)]


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [
        ("dx", LONG), ("dy", LONG), ("mouseData", DWORD), ("dwFlags", DWORD),
        ("time", DWORD), ("dwExtraInfo", ULONG_PTR),
    ]


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [
        ("wVk", WORD), ("wScan", WORD), ("dwFlags", DWORD),
        ("time", DWORD), ("dwExtraInfo", ULONG_PTR),
    ]


class HARDWAREINPUT(ctypes.Structure):
    _fields_ = [("uMsg", DWORD), ("wParamL", WORD), ("wParamH", WORD)]


class _INPUTUNION(ctypes.Union):
    _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT), ("hi", HARDWAREINPUT)]


class INPUT(ctypes.Structure):
    _fields_ = [("type", DWORD), ("u", _INPUTUNION)]


class PROCESSENTRY32W(ctypes.Structure):
    _fields_ = [
        ("dwSize", DWORD), ("cntUsage", DWORD), ("th32ProcessID", DWORD),
        ("th32DefaultHeapID", ULONG_PTR), ("th32ModuleID", DWORD), ("cntThreads", DWORD),
        ("th32ParentProcessID", DWORD), ("pcPriClassBase", LONG), ("dwFlags", DWORD),
        ("szExeFile", ctypes.c_wchar * 260),
    ]


# --------------------------------------------------------------------------------------
# 常量
# --------------------------------------------------------------------------------------
PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
PROCESS_TERMINATE = 0x0001
TH32CS_SNAPPROCESS = 0x00000002
GWL_STYLE = -16
GWL_EXSTYLE = -20
WS_CAPTION = 0x00C00000
WS_THICKFRAME = 0x00040000
WS_CHILD = 0x40000000
WS_VISIBLE = 0x10000000
PW_CLIENTONLY = 0x00000001
PW_RENDERFULLCONTENT = 0x00000002
SRCCOPY = 0x00CC0020
CAPTUREBLT = 0x40000000
DIB_RGB_COLORS = 0
BI_RGB = 0
SWP_NOSIZE = 0x0001
SWP_NOMOVE = 0x0002
SWP_NOZORDER = 0x0004
SWP_NOACTIVATE = 0x0010
SWP_FRAMECHANGED = 0x0020
SWP_SHOWWINDOW = 0x0040
SW_RESTORE = 9
WM_MOUSEMOVE = 0x0200
WM_LBUTTONDOWN = 0x0201
WM_LBUTTONUP = 0x0202
WM_RBUTTONDOWN = 0x0204
WM_RBUTTONUP = 0x0205
WM_MOUSEWHEEL = 0x020A
WM_CHAR = 0x0102
WM_KEYDOWN = 0x0100
WM_KEYUP = 0x0101
WM_SETCURSOR = 0x0020
WM_ACTIVATE = 0x0006
WM_SETFOCUS = 0x0007
WM_CLOSE = 0x0010
MK_LBUTTON = 0x0001
MK_RBUTTON = 0x0002
MOUSEEVENTF_MOVE = 0x0001
MOUSEEVENTF_LEFTDOWN = 0x0002
MOUSEEVENTF_LEFTUP = 0x0004
MOUSEEVENTF_RIGHTDOWN = 0x0008
MOUSEEVENTF_RIGHTUP = 0x0010
MOUSEEVENTF_WHEEL = 0x0800
MOUSEEVENTF_ABSOLUTE = 0x8000
KEYEVENTF_KEYUP = 0x0002
KEYEVENTF_UNICODE = 0x0004
INPUT_MOUSE = 0
INPUT_KEYBOARD = 1
VK_CONTROL = 0x11
VK_SHIFT = 0x10
VK_MENU = 0x12
VK_RETURN = 0x0D
VK_ESCAPE = 0x1B
VK_TAB = 0x09
VK_BACK = 0x08
VK_SPACE = 0x20
VK_V = 0x56
VK_A = 0x41
CF_UNICODETEXT = 13
GMEM_MOVEABLE = 0x0002
SM_XVIRTUALSCREEN = 76
SM_YVIRTUALSCREEN = 77
SM_CXVIRTUALSCREEN = 78
SM_CYVIRTUALSCREEN = 79

# SendMessageTimeout 超时（毫秒）；游戏主线程卡住时不至于把脚本挂死
SEND_TIMEOUT_MS = 800


# --------------------------------------------------------------------------------------
# Win32 API 封装
# --------------------------------------------------------------------------------------
class Win32Api:
    """底层 Win32 调用集合。每个方法都是"薄封装"，方便测试时整体替换。"""

    def __init__(self) -> None:
        if not IS_WINDOWS:
            raise RuntimeError("Win32Api 只能在 Windows 上实例化")
        import ctypes as _ct

        self.ctypes = _ct
        self.user32 = _ct.WinDLL("user32", use_last_error=True)
        self.gdi32 = _ct.WinDLL("gdi32", use_last_error=True)
        self.kernel32 = _ct.WinDLL("kernel32", use_last_error=True)
        self.shell32 = _ct.WinDLL("shell32", use_last_error=True)
        self._declare()

    # -- 原型声明 --
    def _declare(self) -> None:
        u, g, k = self.user32, self.gdi32, self.kernel32

        u.EnumWindows.argtypes = [WNDPROC, LPARAM]
        u.EnumWindows.restype = BOOL
        u.EnumChildWindows.argtypes = [HWND, WNDPROC, LPARAM]
        u.EnumChildWindows.restype = BOOL
        u.GetWindowTextLengthW.argtypes = [HWND]
        u.GetWindowTextLengthW.restype = ctypes.c_int
        u.GetWindowTextW.argtypes = [HWND, LPWSTR, ctypes.c_int]
        u.GetWindowTextW.restype = ctypes.c_int
        u.GetClassNameW.argtypes = [HWND, LPWSTR, ctypes.c_int]
        u.GetClassNameW.restype = ctypes.c_int
        u.GetWindowThreadProcessId.argtypes = [HWND, ctypes.POINTER(DWORD)]
        u.GetWindowThreadProcessId.restype = DWORD
        u.IsWindow.argtypes = [HWND]
        u.IsWindow.restype = BOOL
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
        u.BringWindowToTop.argtypes = [HWND]
        u.BringWindowToTop.restype = BOOL
        u.PostMessageW.argtypes = [HWND, UINT, WPARAM, LPARAM]
        u.PostMessageW.restype = BOOL
        u.SendMessageW.argtypes = [HWND, UINT, WPARAM, LPARAM]
        u.SendMessageW.restype = LRESULT
        u.SendMessageTimeoutW.argtypes = [
            HWND, UINT, WPARAM, LPARAM, UINT, UINT, ctypes.POINTER(ULONG_PTR),
        ]
        u.SendMessageTimeoutW.restype = LRESULT
        u.SendInput.argtypes = [UINT, ctypes.POINTER(INPUT), ctypes.c_int]
        u.SendInput.restype = UINT
        u.AdjustWindowRectEx.argtypes = [ctypes.POINTER(RECT), DWORD, BOOL, DWORD]
        u.AdjustWindowRectEx.restype = BOOL
        u.IsWindowUnicode.argtypes = [HWND]
        u.IsWindowUnicode.restype = BOOL
        u.OpenClipboard.argtypes = [HWND]
        u.OpenClipboard.restype = BOOL
        u.CloseClipboard.restype = BOOL
        u.EmptyClipboard.restype = BOOL
        u.SetClipboardData.argtypes = [UINT, ctypes.c_void_p]
        u.SetClipboardData.restype = ctypes.c_void_p
        u.MapVirtualKeyW.argtypes = [UINT, UINT]
        u.MapVirtualKeyW.restype = UINT
        # 全局低级钩子（P5 录制用）
        u.SetWindowsHookExW.argtypes = [ctypes.c_int, HOOKPROC, HINSTANCE, DWORD]
        u.SetWindowsHookExW.restype = HHOOK
        u.CallNextHookEx.argtypes = [HHOOK, ctypes.c_int, WPARAM, LPARAM]
        u.CallNextHookEx.restype = LRESULT
        u.UnhookWindowsHookEx.argtypes = [HHOOK]
        u.UnhookWindowsHookEx.restype = BOOL
        u.GetMessageW.argtypes = [ctypes.POINTER(MSG), HWND, UINT, UINT]
        u.GetMessageW.restype = ctypes.c_int
        u.PeekMessageW.argtypes = [ctypes.POINTER(MSG), HWND, UINT, UINT, UINT]
        u.PeekMessageW.restype = BOOL
        u.TranslateMessage.argtypes = [ctypes.POINTER(MSG)]
        u.TranslateMessage.restype = BOOL
        u.DispatchMessageW.argtypes = [ctypes.POINTER(MSG)]
        u.DispatchMessageW.restype = LRESULT
        u.PostThreadMessageW.argtypes = [DWORD, UINT, WPARAM, LPARAM]
        u.PostThreadMessageW.restype = BOOL
        u.WindowFromPoint.argtypes = [POINT]
        u.WindowFromPoint.restype = HWND
        u.GetAncestor.argtypes = [HWND, UINT]
        u.GetAncestor.restype = HWND
        u.GetWindow.argtypes = [HWND, UINT]
        u.GetWindow.restype = HWND
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

        if hasattr(k, "GetCurrentThreadId"):
            k.GetCurrentThreadId.restype = DWORD
        k.OpenProcess.argtypes = [DWORD, BOOL, DWORD]
        k.OpenProcess.restype = ctypes.c_void_p
        k.TerminateProcess.argtypes = [ctypes.c_void_p, UINT]
        k.TerminateProcess.restype = BOOL
        k.CloseHandle.argtypes = [ctypes.c_void_p]
        k.CloseHandle.restype = BOOL
        k.QueryFullProcessImageNameW.argtypes = [ctypes.c_void_p, DWORD, LPWSTR, ctypes.POINTER(DWORD)]
        k.QueryFullProcessImageNameW.restype = BOOL
        k.CreateToolhelp32Snapshot.argtypes = [DWORD, DWORD]
        k.CreateToolhelp32Snapshot.restype = ctypes.c_void_p
        k.Process32FirstW.argtypes = [ctypes.c_void_p, ctypes.POINTER(PROCESSENTRY32W)]
        k.Process32FirstW.restype = BOOL
        k.Process32NextW.argtypes = [ctypes.c_void_p, ctypes.POINTER(PROCESSENTRY32W)]
        k.Process32NextW.restype = BOOL
        k.GlobalAlloc.argtypes = [UINT, ctypes.c_size_t]
        k.GlobalAlloc.restype = ctypes.c_void_p
        k.GlobalLock.argtypes = [ctypes.c_void_p]
        k.GlobalLock.restype = ctypes.c_void_p
        k.GlobalUnlock.argtypes = [ctypes.c_void_p]
        k.GlobalUnlock.restype = BOOL

    # -- DPI / 权限 --
    def set_dpi_aware(self) -> str:
        u = self.user32
        for name, ctx in (("PER_MONITOR_AWARE_V2", ctypes.c_void_p(-4)),
                          ("PER_MONITOR_AWARE", ctypes.c_void_p(-2)),
                          ("SYSTEM_AWARE", ctypes.c_void_p(-1))):
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

    # -- 窗口 --
    def enum_top_windows(self) -> List[int]:
        out: List[int] = []

        def cb(hwnd: int, _lparam: int) -> bool:
            out.append(hwnd_int(hwnd))
            return True

        proc = WNDPROC(cb)
        self.user32.EnumWindows(proc, 0)
        return out

    def enum_child_windows(self, hwnd: int) -> List[int]:
        out: List[int] = []

        def cb(child: int, _lparam: int) -> bool:
            out.append(hwnd_int(child))
            return True

        proc = WNDPROC(cb)
        self.user32.EnumChildWindows(HWND(hwnd), proc, 0)
        return out

    def is_window(self, hwnd: int) -> bool:
        return bool(self.user32.IsWindow(HWND(hwnd)))

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

    def pid_of(self, hwnd: int) -> int:
        pid = DWORD(0)
        self.user32.GetWindowThreadProcessId(HWND(hwnd), ctypes.byref(pid))
        return int(pid.value)

    def client_rect(self, hwnd: int) -> Tuple[int, int]:
        r = RECT()
        self.user32.GetClientRect(HWND(hwnd), ctypes.byref(r))
        return int(r.width), int(r.height)

    def window_rect(self, hwnd: int) -> Tuple[int, int, int, int]:
        r = RECT()
        self.user32.GetWindowRect(HWND(hwnd), ctypes.byref(r))
        return int(r.left), int(r.top), int(r.width), int(r.height)

    def client_to_screen(self, hwnd: int, x: int, y: int) -> Tuple[int, int]:
        pt = POINT(int(x), int(y))
        self.user32.ClientToScreen(HWND(hwnd), ctypes.byref(pt))
        return int(pt.x), int(pt.y)

    def screen_to_client(self, hwnd: int, x: int, y: int) -> Tuple[int, int]:
        pt = POINT(int(x), int(y))
        self.user32.ScreenToClient(HWND(hwnd), ctypes.byref(pt))
        return int(pt.x), int(pt.y)

    def get_style(self, hwnd: int) -> Tuple[int, int]:
        style = int(self.user32.GetWindowLongW(HWND(hwnd), GWL_STYLE))
        exstyle = int(self.user32.GetWindowLongW(HWND(hwnd), GWL_EXSTYLE))
        return style, exstyle

    def is_visible(self, hwnd: int) -> bool:
        return bool(self.user32.IsWindowVisible(HWND(hwnd)))

    def is_minimized(self, hwnd: int) -> bool:
        return bool(self.user32.IsIconic(HWND(hwnd)))

    def foreground_window(self) -> int:
        return int(self.user32.GetForegroundWindow() or 0)

    def dpi_of(self, hwnd: int) -> int:
        if hasattr(self.user32, "GetDpiForWindow"):
            try:
                return int(self.user32.GetDpiForWindow(HWND(hwnd))) or 96
            except Exception:
                return 96
        return 96

    def screen_size(self) -> Tuple[int, int]:
        return int(self.user32.GetSystemMetrics(0)), int(self.user32.GetSystemMetrics(1))

    def virtual_screen(self) -> Tuple[int, int, int, int]:
        return (
            int(self.user32.GetSystemMetrics(SM_XVIRTUALSCREEN)),
            int(self.user32.GetSystemMetrics(SM_YVIRTUALSCREEN)),
            int(self.user32.GetSystemMetrics(SM_CXVIRTUALSCREEN)),
            int(self.user32.GetSystemMetrics(SM_CYVIRTUALSCREEN)),
        )

    def resize_client(self, hwnd: int, width: int, height: int) -> bool:
        style, exstyle = self.get_style(hwnd)
        rect = RECT(0, 0, int(width), int(height))
        if not self.user32.AdjustWindowRectEx(ctypes.byref(rect), style, False, exstyle):
            return False
        left, top, _, _ = self.window_rect(hwnd)
        return bool(self.user32.SetWindowPos(
            HWND(hwnd), None, left, top, int(rect.width), int(rect.height),
            SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED,
        ))

    def show_window(self, hwnd: int, cmd: int = SW_RESTORE) -> bool:
        return bool(self.user32.ShowWindow(HWND(hwnd), cmd))

    def activate(self, hwnd: int) -> bool:
        self.show_window(hwnd, SW_RESTORE)
        ok = bool(self.user32.SetForegroundWindow(HWND(hwnd)))
        self.user32.BringWindowToTop(HWND(hwnd))
        return ok

    # -- 截图原语 --
    def grab_bgra(self, hwnd: int, width: int, height: int, paint) -> Optional[bytes]:
        """paint(hdc_mem) -> bool；返回 top-down 32bpp BGRA 原始字节。"""
        if width <= 0 or height <= 0:
            return None
        hdc_src = self.user32.GetDC(HWND(hwnd))
        if not hdc_src:
            return None
        hdc_mem = self.gdi32.CreateCompatibleDC(hdc_src)
        hbmp = self.gdi32.CreateCompatibleBitmap(hdc_src, width, height)
        old = self.gdi32.SelectObject(hdc_mem, hbmp)
        try:
            if not paint(hdc_mem):
                return None
            bi = BITMAPINFO()
            bi.bmiHeader.biSize = ctypes.sizeof(BITMAPINFOHEADER)
            bi.bmiHeader.biWidth = width
            bi.bmiHeader.biHeight = -height
            bi.bmiHeader.biPlanes = 1
            bi.bmiHeader.biBitCount = 32
            bi.bmiHeader.biCompression = BI_RGB
            buf = ctypes.create_string_buffer(width * height * 4)
            got = self.gdi32.GetDIBits(hdc_mem, hbmp, 0, height, ctypes.addressof(buf),
                                       ctypes.byref(bi), DIB_RGB_COLORS)
            if not got:
                return None
            return buf.raw
        finally:
            self.gdi32.SelectObject(hdc_mem, old)
            self.gdi32.DeleteObject(hbmp)
            self.gdi32.DeleteDC(hdc_mem)
            self.user32.ReleaseDC(HWND(hwnd), hdc_src)

    def print_window(self, hwnd: int, flags: int) -> Optional[bytes]:
        if flags & PW_CLIENTONLY:
            width, height = self.client_rect(hwnd)
        else:
            _, _, width, height = self.window_rect(hwnd)
        return self.grab_bgra(hwnd, width, height,
                              lambda hdc: bool(self.user32.PrintWindow(HWND(hwnd), hdc, flags)))

    def bit_blt_window(self, hwnd: int, use_window_dc: bool = False) -> Optional[bytes]:
        if use_window_dc:
            _, _, width, height = self.window_rect(hwnd)
        else:
            width, height = self.client_rect(hwnd)

        def paint(hdc_mem) -> bool:
            src = self.user32.GetWindowDC(HWND(hwnd)) if use_window_dc else self.user32.GetDC(HWND(hwnd))
            if not src:
                return False
            try:
                return bool(self.gdi32.BitBlt(hdc_mem, 0, 0, width, height, src, 0, 0,
                                              SRCCOPY | CAPTUREBLT))
            finally:
                self.user32.ReleaseDC(HWND(hwnd), src)

        return self.grab_bgra(hwnd, width, height, paint)

    # -- 输入原语 --
    def post_message(self, hwnd: int, msg: int, wparam: int = 0, lparam: int = 0) -> bool:
        return bool(self.user32.PostMessageW(HWND(hwnd), msg, WPARAM(wparam), LPARAM(lparam)))

    def send_message(self, hwnd: int, msg: int, wparam: int = 0, lparam: int = 0) -> int:
        return int(self.user32.SendMessageW(HWND(hwnd), msg, WPARAM(wparam), LPARAM(lparam)))

    def send_message_timeout(self, hwnd: int, msg: int, wparam: int = 0, lparam: int = 0,
                             timeout_ms: int = SEND_TIMEOUT_MS) -> int:
        result = ULONG_PTR(0)
        ret = self.user32.SendMessageTimeoutW(
            HWND(hwnd), msg, WPARAM(wparam), LPARAM(lparam), 0x0002, timeout_ms,  # SMTO_ABORTIFHUNG
            ctypes.byref(result),
        )
        return int(ret)

    def send_input(self, inputs: Sequence[INPUT]) -> int:
        arr = (INPUT * len(inputs))(*inputs)
        return int(self.user32.SendInput(len(inputs), arr, ctypes.sizeof(INPUT)))

    def map_virtual_key(self, vk: int, mode: int = 0) -> int:
        return int(self.user32.MapVirtualKeyW(int(vk), int(mode)))

    # -- 剪贴板 --
    def set_clipboard_text(self, text: str) -> bool:
        if not self.user32.OpenClipboard(None):
            return False
        try:
            self.user32.EmptyClipboard()
            size = (len(text) + 1) * ctypes.sizeof(ctypes.c_wchar)
            handle = self.kernel32.GlobalAlloc(GMEM_MOVEABLE, size)
            if not handle:
                return False
            ptr = self.kernel32.GlobalLock(handle)
            ctypes.memmove(ptr, ctypes.create_unicode_buffer(text), size)
            self.kernel32.GlobalUnlock(handle)
            self.user32.SetClipboardData(CF_UNICODETEXT, handle)
            return True
        finally:
            self.user32.CloseClipboard()

    # -- 进程 --
    def process_path(self, pid: int) -> str:
        handle = self.kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, int(pid))
        if not handle:
            return ""
        try:
            buf = ctypes.create_unicode_buffer(1024)
            size = DWORD(len(buf))
            if self.kernel32.QueryFullProcessImageNameW(handle, 0, buf, ctypes.byref(size)):
                return buf.value
            return ""
        finally:
            self.kernel32.CloseHandle(handle)

    def list_processes(self) -> List[Tuple[int, str]]:
        """返回 [(pid, exe_name)]。"""
        out: List[Tuple[int, str]] = []
        snap = self.kernel32.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
        if not snap or snap == ctypes.c_void_p(-1).value:
            return out
        try:
            entry = PROCESSENTRY32W()
            entry.dwSize = ctypes.sizeof(PROCESSENTRY32W)
            if not self.kernel32.Process32FirstW(snap, ctypes.byref(entry)):
                return out
            while True:
                out.append((int(entry.th32ProcessID), entry.szExeFile))
                if not self.kernel32.Process32NextW(snap, ctypes.byref(entry)):
                    break
            return out
        finally:
            self.kernel32.CloseHandle(snap)

    def terminate_process(self, pid: int) -> bool:
        handle = self.kernel32.OpenProcess(PROCESS_TERMINATE, False, int(pid))
        if not handle:
            return False
        try:
            return bool(self.kernel32.TerminateProcess(handle, 1))
        finally:
            self.kernel32.CloseHandle(handle)


# --------------------------------------------------------------------------------------
# 单例 / 测试注入
# --------------------------------------------------------------------------------------
_API: Optional[Any] = None


def is_windows() -> bool:
    return IS_WINDOWS


def api() -> Any:
    """取得全局 Win32 API 实例（非 Windows 平台会抛出明确错误）。"""
    global _API
    if _API is None:
        if not IS_WINDOWS:
            raise RuntimeError(
                "当前平台不是 Windows，无法直接控制时空客户端。"
                "单元测试请用 win_api.set_api(假实现) 注入。"
            )
        _API = Win32Api()
        try:
            _API.set_dpi_aware()
        except Exception:
            pass
    return _API


def set_api(impl: Optional[Any]) -> None:
    """注入实现（测试用，传 None 恢复默认）。"""
    global _API
    _API = impl


# --------------------------------------------------------------------------------------
# 图像与几何工具（与平台无关，可在 macOS 上单测）
# --------------------------------------------------------------------------------------
def hwnd_int(value: Any) -> int:
    """把回调里拿到的句柄转成 int。

    ctypes 在回调里既可能传 Python int（指针被转换过），
    也可能传 c_void_p 对象；两种都要接受，否则 int(c_void_p) 会直接 ValueError。
    """
    inner = getattr(value, "value", value)
    if inner is None:
        return 0
    return int(inner)


def lparam_point(x: int, y: int) -> int:
    return ((int(y) & 0xFFFF) << 16) | (int(x) & 0xFFFF)


def analyze_bgra(buf: Optional[bytes], width: int, height: int) -> Dict[str, Any]:
    total = width * height
    if not buf or total <= 0 or len(buf) < total * 4:
        return {"valid": False, "black_ratio": 1.0, "mean_brightness": 0.0, "distinct_colors_sampled": 0}
    step = 1 if total <= 120_000 else max(1, total // 120_000)
    black = 0
    lum_sum = 0
    colors = set()
    sampled = 0
    for i in range(0, total, step):
        off = i * 4
        b, g, r = buf[off], buf[off + 1], buf[off + 2]
        lum_sum += (r * 299 + g * 587 + b * 114) // 1000
        if r < 10 and g < 10 and b < 10:
            black += 1
        colors.add((r >> 3, g >> 3, b >> 3))
        sampled += 1
    return {
        "valid": True,
        "black_ratio": round(black / max(1, sampled), 4),
        "mean_brightness": round(lum_sum / max(1, sampled), 2),
        "distinct_colors_sampled": len(colors),
        "sampled_pixels": sampled,
    }


def diff_bgra(a: Optional[bytes], b: Optional[bytes], width: int, height: int) -> Dict[str, Any]:
    """两帧差异：变化像素占比 + 平均绝对差（用于校验点击/操作是否生效）。"""
    if not a or not b or len(a) != len(b):
        return {"comparable": False}
    total = width * height
    if total <= 0:
        return {"comparable": False}
    step = 1 if total <= 120_000 else max(1, total // 120_000)
    changed = 0
    acc = 0
    sampled = 0
    for i in range(0, total, step):
        off = i * 4
        d = (abs(a[off] - b[off]) + abs(a[off + 1] - b[off + 1])
             + abs(a[off + 2] - b[off + 2])) // 3
        acc += d
        if d > 12:
            changed += 1
        sampled += 1
    return {
        "comparable": True,
        "changed_ratio": round(changed / max(1, sampled), 4),
        "mean_abs_diff": round(acc / max(1, sampled), 2),
    }


def bgra_to_bgr_numpy(buf: bytes, width: int, height: int):
    """转成 OpenCV 习惯的 BGR ndarray（H, W, 3）。缺 numpy 时返回 None。"""
    try:
        import numpy as np
    except Exception:
        return None
    if not buf or len(buf) < width * height * 4:
        return None
    arr = np.frombuffer(buf, dtype=np.uint8).reshape(height, width, 4)
    return arr[:, :, :3].copy()


def save_bgra_bmp(path: str, buf: bytes, width: int, height: int) -> bool:
    """无第三方依赖地把 BGRA 存成 24bpp BMP（numpy/cv2 不可用时的兜底）。"""
    if not buf or width <= 0 or height <= 0 or len(buf) < width * height * 4:
        return False
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
    for y in range(height - 1, -1, -1):
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
    parent = os.path.dirname(os.path.abspath(path))
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(bytes(header))
        fh.write(pixel_bytes)
    return True


def save_bgr_image(path: str, image, buf: Optional[bytes] = None,
                   width: int = 0, height: int = 0) -> bool:
    """优先用 cv2 写 PNG/JPG，失败时按 BMP 兜底。"""
    if image is not None:
        try:
            import cv2
            return bool(cv2.imwrite(str(path), image))
        except Exception:
            pass
    if buf is not None:
        return save_bgra_bmp(path, buf, width, height)
    return False


def exe_basename(path: str) -> str:
    """取 Windows 路径的文件名；在非 Windows 上跑测试时也能正确切分。"""
    if not path:
        return ""
    if "\\" in path or (len(path) > 1 and path[1] == ":"):
        import ntpath
        return ntpath.basename(path)
    return os.path.basename(path)


def exe_dirname(path: str) -> str:
    """取 Windows 路径的目录；在非 Windows 上跑测试时也能正确切分。"""
    if not path:
        return ""
    if "\\" in path or (len(path) > 1 and path[1] == ":"):
        import ntpath
        return ntpath.dirname(path)
    return os.path.dirname(path)


def scale_point(x: int, y: int, source: Tuple[int, int], target: Tuple[int, int]) -> Tuple[int, int]:
    """按比例把坐标从 source 分辨率映射到 target 分辨率。"""
    sw, sh = max(1, int(source[0])), max(1, int(source[1]))
    tw, th = max(1, int(target[0])), max(1, int(target[1]))
    return int(round(x * tw / sw)), int(round(y * th / sh))


def clamp_point(x: int, y: int, size: Tuple[int, int], margin: int = 1) -> Tuple[int, int]:
    w, h = max(1, int(size[0])), max(1, int(size[1]))
    return (max(margin, min(int(x), w - 1 - margin)), max(margin, min(int(y), h - 1 - margin)))


def sleep_ms(ms: float) -> None:
    if ms > 0:
        time.sleep(ms / 1000.0)


def ensure_utf8_stdout() -> None:
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[attr-defined]
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[attr-defined]
    except Exception:
        pass
