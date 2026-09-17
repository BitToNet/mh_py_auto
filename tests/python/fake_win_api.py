#!/usr/bin/env python3
# coding=utf-8
"""假 Win32 后端：在 macOS/Linux 上验证窗口层/截图层/输入层/设备层逻辑。

只实现 win_api.Win32Api 里被上层用到的那些方法，行为尽量贴近真实：
* 窗口有屏幕位置与客户区尺寸，client_to_screen / screen_to_client 真算
* 截图按 capture_mode 决定哪个窗口/后端能拿到"有内容"的画面，其余返回纯黑
* 输入调用全部记录，方便断言"消息发给了哪个窗口、坐标是多少"
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional, Sequence, Tuple

WS_THICKFRAME = 0x00040000
PW_CLIENTONLY = 0x00000001
PW_RENDERFULLCONTENT = 0x00000002


class FakeWindow:
    def __init__(self, hwnd: int, pid: int, title: str = "", exe: str = "MyGame_x64r.exe",
                 client_width: int = 1600, client_height: int = 900,
                 left: int = 100, top: int = 60, children: Optional[Sequence[int]] = None,
                 parent: Optional[int] = None, child_offset: Tuple[int, int] = (0, 0),
                 minimized: bool = False, visible: bool = True,
                 class_name: str = "MessiahWindow", style: int = WS_THICKFRAME,
                 dpi: int = 96) -> None:
        self.hwnd = hwnd
        self.pid = pid
        self.title = title
        self.exe = exe
        self.client_width = client_width
        self.client_height = client_height
        self.left = left
        self.top = top
        self.children: List[int] = list(children or [])
        self.parent = parent
        self.child_offset = child_offset  # 相对父窗口客户区左上角
        self.minimized = minimized
        self.visible = visible
        self.class_name = class_name
        self.style = style
        self.dpi = dpi

    def screen_origin(self, windows: Dict[int, "FakeWindow"]) -> Tuple[int, int]:
        if self.parent is None:
            return self.left, self.top
        parent = windows[self.parent]
        px, py = parent.screen_origin(windows)
        return px + self.child_offset[0], py + self.child_offset[1]


class FakeWin32Api:
    def __init__(self) -> None:
        self.windows: Dict[int, FakeWindow] = {}
        self.processes: List[Tuple[int, str]] = []
        self.process_paths: Dict[int, str] = {}
        self.foreground = 0
        # 记录
        self.messages: List[Dict[str, int]] = []
        self.inputs: List[Any] = []
        self.clipboard = ""
        self.resize_calls: List[Tuple[int, int, int]] = []
        self.activate_calls: List[int] = []
        self.capture_calls: List[Tuple[int, str]] = []
        # 行为开关
        self.capture_mode = "good"   # good | childonly | black | bitblt
        self.fail_post_message = False
        self.fail_send_message = False
        self.fail_send_input = False
        self.dpi_aware = "FAKE"
        self.admin = True
        self.screen = (1920, 1080)
        # 每次鼠标按下让画面内容变一版，模拟"界面真的响应了点击"
        self.content_version = 0
        self.react_to_clicks = True

    # -- 构造辅助 --
    def add_game_window(self, hwnd: int, pid: int, title: str = "梦幻西游：时空",
                        exe: str = "MyGame_x64r.exe", client_width: int = 1600,
                        client_height: int = 900, left: int = 100, top: int = 60,
                        with_child: bool = False, child_covers: float = 1.0,
                        minimized: bool = False) -> FakeWindow:
        child_ids: List[int] = []
        window = FakeWindow(hwnd=hwnd, pid=pid, title=title, exe=exe,
                            client_width=client_width, client_height=client_height,
                            left=left, top=top, minimized=minimized)
        self.windows[hwnd] = window
        self.processes.append((pid, exe))
        self.process_paths[pid] = f"C:\\games\\shikong\\{exe}"
        if with_child:
            child_hwnd = hwnd + 1
            cw = int(client_width * child_covers)
            ch = int(client_height * child_covers)
            self.windows[child_hwnd] = FakeWindow(
                hwnd=child_hwnd, pid=pid, title="", exe=exe, client_width=cw,
                client_height=ch, parent=hwnd, child_offset=(0, 0),
                class_name="MessiahRenderChild",
            )
            child_ids.append(child_hwnd)
        window.children = child_ids
        if self.foreground == 0:
            self.foreground = hwnd
        return window

    # -- 窗口 --
    def enum_top_windows(self) -> List[int]:
        return [hwnd for hwnd, win in self.windows.items() if win.parent is None]

    def enum_child_windows(self, hwnd: int) -> List[int]:
        out: List[int] = []
        for child in self.windows.get(hwnd, FakeWindow(0, 0)).children:
            out.append(child)
            out.extend(self.enum_child_windows(child))
        return out

    def is_window(self, hwnd: int) -> bool:
        return hwnd in self.windows

    def window_text(self, hwnd: int) -> str:
        win = self.windows.get(hwnd)
        return win.title if win else ""

    def class_name(self, hwnd: int) -> str:
        win = self.windows.get(hwnd)
        return win.class_name if win else ""

    def pid_of(self, hwnd: int) -> int:
        win = self.windows.get(hwnd)
        return win.pid if win else 0

    def client_rect(self, hwnd: int) -> Tuple[int, int]:
        win = self.windows.get(hwnd)
        return (win.client_width, win.client_height) if win else (0, 0)

    def window_rect(self, hwnd: int) -> Tuple[int, int, int, int]:
        win = self.windows.get(hwnd)
        if not win:
            return 0, 0, 0, 0
        x, y = win.screen_origin(self.windows)
        return x, y, win.client_width, win.client_height

    def client_to_screen(self, hwnd: int, x: int, y: int) -> Tuple[int, int]:
        win = self.windows.get(hwnd)
        if not win:
            return int(x), int(y)
        ox, oy = win.screen_origin(self.windows)
        return ox + int(x), oy + int(y)

    def screen_to_client(self, hwnd: int, x: int, y: int) -> Tuple[int, int]:
        win = self.windows.get(hwnd)
        if not win:
            return int(x), int(y)
        ox, oy = win.screen_origin(self.windows)
        return int(x) - ox, int(y) - oy

    def get_style(self, hwnd: int) -> Tuple[int, int]:
        win = self.windows.get(hwnd)
        return (win.style, 0) if win else (0, 0)

    def is_visible(self, hwnd: int) -> bool:
        win = self.windows.get(hwnd)
        return bool(win and win.visible)

    def is_minimized(self, hwnd: int) -> bool:
        win = self.windows.get(hwnd)
        return bool(win and win.minimized)

    def foreground_window(self) -> int:
        return self.foreground

    def dpi_of(self, hwnd: int) -> int:
        win = self.windows.get(hwnd)
        return win.dpi if win else 96

    def screen_size(self) -> Tuple[int, int]:
        return self.screen

    def virtual_screen(self) -> Tuple[int, int, int, int]:
        return 0, 0, self.screen[0], self.screen[1]

    def resize_client(self, hwnd: int, width: int, height: int) -> bool:
        win = self.windows.get(hwnd)
        if not win:
            return False
        self.resize_calls.append((hwnd, width, height))
        win.client_width = int(width)
        win.client_height = int(height)
        for child in win.children:
            self.windows[child].client_width = int(width)
            self.windows[child].client_height = int(height)
        return True

    def show_window(self, hwnd: int, cmd: int = 9) -> bool:
        win = self.windows.get(hwnd)
        if not win:
            return False
        win.minimized = False
        return True

    def activate(self, hwnd: int) -> bool:
        if hwnd not in self.windows:
            return False
        self.activate_calls.append(hwnd)
        self.foreground = hwnd
        self.windows[hwnd].minimized = False
        return True

    # -- 截图 --
    # 11 个互不相同的非黑像素循环填充（11 与常见采样步长 12 互质，避免采样混叠），
    # 颜色丰富且无黑屏，填充本身是 C 级切片速度。
    GOOD_PATTERN = bytes([
        10, 20, 30, 255, 200, 100, 50, 255, 30, 240, 90, 255, 255, 255, 255, 255,
        77, 88, 99, 255, 12, 200, 255, 255, 240, 10, 130, 255, 60, 130, 170, 255,
        140, 70, 220, 255, 33, 99, 66, 255, 250, 180, 20, 255,
    ])
    # 点击后切换到的另一版画面
    GOOD_PATTERN_B = bytes([
        220, 40, 10, 255, 15, 190, 240, 255, 90, 30, 200, 255, 255, 255, 255, 255,
        40, 200, 60, 255, 200, 12, 190, 255, 20, 240, 200, 255, 130, 60, 30, 255,
        66, 99, 33, 255, 20, 180, 250, 255, 99, 77, 88, 255,
    ])

    def _buffer(self, width: int, height: int, content: str) -> bytes:
        size = max(0, width * height * 4)
        if content == "black":
            return bytes(size)
        pattern = self.GOOD_PATTERN
        if self.react_to_clicks and self.content_version % 2 == 1:
            pattern = self.GOOD_PATTERN_B
        return (pattern * (size // len(pattern) + 1))[:size]

    def _content_for(self, hwnd: int, method: str) -> str:
        win = self.windows.get(hwnd)
        if win is None or not win.visible:
            return "black"
        if self.capture_mode == "black":
            return "black"
        if self.capture_mode == "bitblt":
            return "good" if method == "bitblt" else "black"
        if self.capture_mode == "childonly":
            return "good" if win.parent is not None else "black"
        # good：printwindow 系可用，bitblt 系黑屏
        return "good" if method.startswith("printwindow") else "black"

    def print_window(self, hwnd: int, flags: int) -> Optional[bytes]:
        if (flags & PW_CLIENTONLY) and not (flags & PW_RENDERFULLCONTENT):
            method = "printwindow_client"
        elif flags & PW_RENDERFULLCONTENT:
            method = "printwindow_renderfull"
        else:
            method = "printwindow_window"
        self.capture_calls.append((hwnd, method))
        win = self.windows.get(hwnd)
        if win is None:
            return None
        if flags & PW_CLIENTONLY:
            width, height = win.client_width, win.client_height
        else:
            width, height = win.client_width, win.client_height
        return self._buffer(width, height, self._content_for(hwnd, method))

    def bit_blt_window(self, hwnd: int, use_window_dc: bool = False) -> Optional[bytes]:
        method = "bitblt_window" if use_window_dc else "bitblt_client"
        self.capture_calls.append((hwnd, method))
        win = self.windows.get(hwnd)
        if win is None:
            return None
        return self._buffer(win.client_width, win.client_height,
                            self._content_for(hwnd, "bitblt"))

    def grab_bgra(self, hwnd: int, width: int, height: int, paint) -> Optional[bytes]:
        raise AssertionError("上层不应直接调用 grab_bgra")

    # -- 输入 --
    def post_message(self, hwnd: int, msg: int, wparam: int = 0, lparam: int = 0) -> bool:
        if self.fail_post_message:
            raise RuntimeError("post_message 被配置为失败")
        self.messages.append({"hwnd": hwnd, "msg": msg, "wparam": wparam, "lparam": lparam,
                              "kind": "post"})
        if msg in (0x0201, 0x0204):  # 左/右键按下
            self.content_version += 1
        return True

    def send_message(self, hwnd: int, msg: int, wparam: int = 0, lparam: int = 0) -> int:
        if self.fail_send_message:
            raise RuntimeError("send_message 被配置为失败")
        self.messages.append({"hwnd": hwnd, "msg": msg, "wparam": wparam, "lparam": lparam,
                              "kind": "send"})
        if msg in (0x0201, 0x0204):
            self.content_version += 1
        return 1

    def send_message_timeout(self, hwnd: int, msg: int, wparam: int = 0, lparam: int = 0,
                             timeout_ms: int = 800) -> int:
        return self.send_message(hwnd, msg, wparam, lparam)

    def send_input(self, inputs: Sequence[Any]) -> int:
        if self.fail_send_input:
            raise RuntimeError("send_input 被配置为失败")
        self.inputs.append(list(inputs))
        if self.react_to_clicks:
            for item in inputs:
                if getattr(item, "type", None) == 0 and item.u.mi.dwFlags & 0x0002:
                    self.content_version += 1
                    break
        return len(inputs)

    def set_clipboard_text(self, text: str) -> bool:
        self.clipboard = text
        return True

    def map_virtual_key(self, vk: int, mode: int = 0) -> int:
        return int(vk)

    # -- 进程 --
    def process_path(self, pid: int) -> str:
        return self.process_paths.get(pid, "")

    def list_processes(self) -> List[Tuple[int, str]]:
        return list(self.processes)

    def terminate_process(self, pid: int) -> bool:
        return True

    # -- 杂项 --
    def is_admin(self) -> bool:
        return self.admin

    def set_dpi_aware(self) -> str:
        return self.dpi_aware

    # -- 断言辅助 --
    def clicks_on(self, hwnd: int) -> List[Dict[str, int]]:
        return [m for m in self.messages if m["hwnd"] == hwnd and m["msg"] == 0x0201]

    def last_click_point(self, hwnd: int) -> Tuple[int, int]:
        clicks = self.clicks_on(hwnd)
        assert clicks, "没有记录到点击"
        lparam = clicks[-1]["lparam"]
        x = lparam & 0xFFFF
        y = (lparam >> 16) & 0xFFFF
        return x, y
