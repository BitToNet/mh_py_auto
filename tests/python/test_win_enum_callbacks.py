#!/usr/bin/env python3
# coding=utf-8
"""枚举窗口回调原型的回归防线（实机 "cb() takes 2 positional arguments but 4 were given"）。

背景
----
``EnumWindows`` / ``EnumChildWindows`` 的回调（EnumWindowsProc）只有 **两个** 参数
``(HWND, LPARAM)``，而窗口过程 ``WNDPROC`` 是 **四个** 参数。两个模块一开始共用
``WNDPROC`` 这个 4 参数原型来包枚举回调，于是真机上 ctypes 按原型用 4 个参数调用
2 个参数的 Python 函数 → ``TypeError``；而 ctypes 会**吞掉**回调里的异常并按 0
（FALSE）返回，0 在 Windows 上的语义是"停止枚举"，因此 ``EnumWindows`` 立刻返回、
窗口列表恒为空。表现就是整个控制层不可用：探测"候选窗口 0 个"、冒烟"找到时空客户端
窗口 未通过"，而根因藏在被吞掉的 traceback 里。

为什么 macOS 单测没拦住
----------------------
测试夹具当时把原型换成了恒等函数
（``win_probe.WNDPROC = staticmethod(lambda callback: callback)``），
也就是**故意绕开了 ctypes 原型包装**——而"原型不匹配"恰恰只在这层包装上体现。
现在夹具直接调用真的 ctypes 回调对象，本文件再补上原型本身（声明 argtypes + 用法）
的断言：两者都必须是 2 参数的 ``ENUMPROC``。
"""

from __future__ import annotations

import ctypes
import os
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "scripts", "win"))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import win_api  # noqa: E402
import win_probe  # noqa: E402


class _FakeWinFunc:
    """像 ctypes 函数指针一样：既可以被调用，也能设置 argtypes / restype。"""

    def __init__(self, impl):
        self._impl = impl
        self.argtypes = None
        self.restype = None
        self.calls = 0

    def __call__(self, *args):
        self.calls += 1
        return self._impl(*args)


class FakeEnumUser32:
    """只实现枚举所需的部分。

    ``EnumWindows`` / ``EnumChildWindows`` **像真机一样直接调用传进来的 ctypes
    回调对象**（而不是像以前那样把原型换成恒等函数），所以回调原型一旦不匹配，
    这里就会立刻抛出来。
    """

    def __init__(self, top=(), children=None, stop_after=None):
        self.top = [int(hwnd) for hwnd in top]
        self.children = {int(key): [int(v) for v in value]
                         for key, value in (children or {}).items()}
        self.stop_after = stop_after
        self.EnumWindows = _FakeWinFunc(self._enum_windows)
        self.EnumChildWindows = _FakeWinFunc(self._enum_children)

    def _enum_windows(self, callback, lparam):
        for index, hwnd in enumerate(self.top):
            if self.stop_after is not None and index >= self.stop_after:
                break
            if not callback(hwnd, lparam):   # 返回 0 = 停止枚举（真机语义）
                break
        return True

    def _enum_children(self, hwnd, callback, lparam):
        key = int(getattr(hwnd, "value", hwnd) or 0)
        for child in self.children.get(key, []):
            if not callback(child, lparam):
                break
        return True


class CallbackPrototypeTest(unittest.TestCase):
    """两个模块的原型定义：枚举用 2 参数，窗口过程用 4 参数，且不是同一个东西。"""

    MODULES = (win_api, win_probe)

    def test_enum_prototype_takes_two_args_and_wndproc_takes_four(self):
        for module in self.MODULES:
            with self.subTest(module=module.__name__):
                self.assertEqual(len(module.ENUMPROC._argtypes_), 2)
                self.assertEqual(len(module.WNDPROC._argtypes_), 4)
                self.assertIsNot(module.ENUMPROC, module.WNDPROC)

    def test_enum_prototype_return_type_is_bool(self):
        # 返回值是 BOOL：返回 0 就等于告诉系统"停止枚举"，语义不能含糊
        for module in self.MODULES:
            with self.subTest(module=module.__name__):
                self.assertIs(module.ENUMPROC._restype_, module.BOOL)

    def test_callback_wrapped_with_enum_prototype_accepts_two_args(self):
        for module in self.MODULES:
            with self.subTest(module=module.__name__):
                seen = []
                proc = module.ENUMPROC(lambda hwnd, lparam: seen.append((hwnd, lparam)) or True)
                self.assertTrue(proc(0x1234, 0))
                self.assertEqual(seen, [(0x1234, 0)])


class DeclareEnumPrototypesTest(unittest.TestCase):
    """声明处（argtypes）也必须用 ENUMPROC —— 这正是当初写错的那一行。"""

    def test_win_api_declares_enum_windows_with_enum_prototype(self):
        user32 = FakeEnumUser32()
        win_api.declare_enum_prototypes(user32)
        self.assertIs(user32.EnumWindows.argtypes[0], win_api.ENUMPROC)
        self.assertEqual(len(user32.EnumWindows.argtypes), 2)
        self.assertIs(user32.EnumChildWindows.argtypes[1], win_api.ENUMPROC)
        self.assertEqual(len(user32.EnumChildWindows.argtypes), 3)
        self.assertIs(user32.EnumWindows.restype, win_api.BOOL)

    def test_win_probe_declares_enum_windows_with_enum_prototype(self):
        user32 = FakeEnumUser32()
        win_probe.declare_enum_prototypes(user32)
        self.assertIs(user32.EnumWindows.argtypes[0], win_probe.ENUMPROC)
        self.assertIs(user32.EnumChildWindows.argtypes[1], win_probe.ENUMPROC)


class WinApiEnumerationTest(unittest.TestCase):
    """真的走一遍 Win32Api.enum_top_windows / enum_child_windows（回调经 ctypes 包装）。"""

    def make_api(self, user32):
        # 不实例化 Win32Api（那需要真的 Windows DLL），只借用它的枚举方法
        api = win_api.Win32Api.__new__(win_api.Win32Api)
        api.user32 = user32
        return api

    def test_enum_top_windows_returns_every_window(self):
        api = self.make_api(FakeEnumUser32(top=[0x1000, 0x2000, 0xABCD]))
        self.assertEqual(api.enum_top_windows(), [0x1000, 0x2000, 0xABCD])

    def test_enum_top_windows_stops_when_callback_returns_zero(self):
        api = self.make_api(FakeEnumUser32(top=[0x1000, 0x2000], stop_after=0))
        self.assertEqual(api.enum_top_windows(), [])

    def test_enum_child_windows_uses_window_handle(self):
        api = self.make_api(FakeEnumUser32(children={0x1000: [0x2000, 0x3000]}))
        self.assertEqual(api.enum_child_windows(0x1000), [0x2000, 0x3000])
        self.assertEqual(api.enum_child_windows(0x9999), [])

    def test_enum_windows_is_actually_called(self):
        user32 = FakeEnumUser32(top=[0x1000])
        self.make_api(user32).enum_top_windows()
        self.assertEqual(user32.EnumWindows.calls, 1)


class CallbackSwallowingTest(unittest.TestCase):
    """把"ctypes 吞异常"这件事本身钉住：它是这个 bug 难以发现的根本原因。"""

    def test_exception_in_callback_does_not_reach_the_caller(self):
        """回调里抛异常时，异常不会传回调用点（只有 stderr 上几行 "Exception ignored"）。

        这正是原型写错时的处境：真机上窗口列表静默变空，脚本本身不报错。
        注意返回值是**未定义**的（libffi 不回填返回寄存器），所以不能靠
        "返回 0" 来判断回调是否出错——只能靠断言列表内容。
        """
        ran = []

        def boom(hwnd, lparam):
            ran.append(hwnd)
            raise RuntimeError("回调内部出错")

        proc = win_api.ENUMPROC(boom)
        proc(0x1, 0)          # 不抛异常、也不中断调用点
        self.assertEqual(ran, [0x1])


if __name__ == "__main__":
    unittest.main()
