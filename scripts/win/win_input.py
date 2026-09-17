#!/usr/bin/env python3
# coding=utf-8
"""输入层：后台窗口消息 / 前台真实输入，多后端可切换。

三种后端：
* ``postmessage``  —— 投递消息，立即返回，最不打扰（被遮挡/后台也能用，若客户端接受）
* ``sendmessage``  —— 同步等待对方处理，能拿到返回值，但对方卡住会阻塞（带超时）
* ``sendinput``    —— 真实鼠标键盘事件，会抢前台，但兼容性最好

默认顺序由配置决定；实机探测（tools/win_probe.py）结果出来后可只改配置。
所有坐标都是"目标窗口客户区坐标"。
"""

from __future__ import annotations

import random
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Sequence, Tuple

from win_api import (INPUT, INPUT_KEYBOARD, INPUT_MOUSE, KEYBDINPUT, KEYEVENTF_KEYUP,
                     KEYEVENTF_UNICODE, MK_LBUTTON, MK_RBUTTON,
                     MOUSEEVENTF_ABSOLUTE, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP,
                     MOUSEEVENTF_MOVE, MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP,
                     MOUSEEVENTF_WHEEL, MOUSEINPUT, SEND_TIMEOUT_MS, VK_CONTROL, WM_CHAR,
                     WM_KEYDOWN, WM_KEYUP, WM_LBUTTONDOWN, WM_LBUTTONUP, WM_MOUSEMOVE,
                     WM_MOUSEWHEEL, WM_RBUTTONDOWN, WM_RBUTTONUP,
                     api as default_api, lparam_point, sleep_ms)

DEFAULT_METHOD_ORDER: Tuple[str, ...] = ("postmessage", "sendmessage", "sendinput")
MOUSE_BACKENDS = ("postmessage", "sendmessage", "sendinput")
# 文本输入方式：unicode 兼容性最好（走真实键盘事件），wm_char 纯后台，clipboard 最稳但改剪贴板
DEFAULT_TEXT_ORDER: Tuple[str, ...] = ("unicode", "wm_char", "clipboard")
# 相邻消息之间的小间隔（毫秒）。太快某些引擎会丢事件。
PRESS_GAP_MS = 40
MOVE_GAP_MS = 30
DEFAULT_DRAG_STEPS = 12


def human_delay(base_ms: float, spread_ms: float = 0.0) -> None:
    """带随机抖动的等待，避免机械化的固定节奏。"""
    sleep_ms(max(0.0, base_ms + (random.uniform(-spread_ms, spread_ms) if spread_ms else 0.0)))


def jitter_point(x: int, y: int, radius: int) -> Tuple[int, int]:
    """在点周围随机偏移，模拟人手落点。"""
    if radius <= 0:
        return int(x), int(y)
    return (int(x) + random.randint(-radius, radius), int(y) + random.randint(-radius, radius))


@dataclass
class InputResult:
    ok: bool
    method: str
    action: str
    detail: Dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> Dict[str, Any]:
        return {"ok": self.ok, "method": self.method, "action": self.action, **self.detail}


# --------------------------------------------------------------------------------------
# 鼠标
# --------------------------------------------------------------------------------------
def _make_mouse_input(dx: int, dy: int, flags: int, data: int = 0) -> INPUT:
    item = INPUT()
    item.type = INPUT_MOUSE
    item.u.mi = MOUSEINPUT(int(dx), int(dy), int(data), int(flags), 0, 0)
    return item


def _send_mouse_message(w: Any, hwnd: int, msg: int, x: int, y: int, wparam: int = 0,
                        timeout: Optional[int] = None) -> bool:
    lparam = lparam_point(x, y)
    if timeout is None:
        return bool(w.post_message(hwnd, msg, wparam, lparam))
    try:
        w.send_message_timeout(hwnd, msg, wparam, lparam, timeout)
        return True
    except Exception:
        return False


def _send_input_mouse(w: Any, hwnd: int, x: int, y: int, button: str,
                      activate: bool = True, wheel: int = 0) -> bool:
    if activate:
        w.activate(hwnd)
        sleep_ms(120)
    sx, sy = w.client_to_screen(hwnd, x, y)
    vx, vy, vw, vh = w.virtual_screen()
    vw = max(1, vw - 1)
    vh = max(1, vh - 1)
    abs_x = int((sx - vx) * 65535 / vw)
    abs_y = int((sy - vy) * 65535 / vh)
    flags_move = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE
    if wheel:
        seq = [
            _make_mouse_input(abs_x, abs_y, flags_move),
            _make_mouse_input(abs_x, abs_y, MOUSEEVENTF_WHEEL | MOUSEEVENTF_ABSOLUTE, wheel),
        ]
    elif button == "right":
        seq = [
            _make_mouse_input(abs_x, abs_y, flags_move),
            _make_mouse_input(abs_x, abs_y, MOUSEEVENTF_RIGHTDOWN | MOUSEEVENTF_ABSOLUTE),
            _make_mouse_input(abs_x, abs_y, MOUSEEVENTF_RIGHTUP | MOUSEEVENTF_ABSOLUTE),
        ]
    else:
        seq = [
            _make_mouse_input(abs_x, abs_y, flags_move),
            _make_mouse_input(abs_x, abs_y, MOUSEEVENTF_LEFTDOWN | MOUSEEVENTF_ABSOLUTE),
            _make_mouse_input(abs_x, abs_y, MOUSEEVENTF_LEFTUP | MOUSEEVENTF_ABSOLUTE),
        ]
    return bool(w.send_input(seq))


def move_mouse(hwnd: int, x: int, y: int, method: str = "postmessage", api: Any = None) -> bool:
    w = api or default_api()
    x, y = int(x), int(y)
    if method == "postmessage":
        return _send_mouse_message(w, hwnd, WM_MOUSEMOVE, x, y)
    if method == "sendmessage":
        return _send_mouse_message(w, hwnd, WM_MOUSEMOVE, x, y, timeout=SEND_TIMEOUT_MS)
    if method == "sendinput":
        sx, sy = w.client_to_screen(hwnd, x, y)
        vx, vy, vw, vh = w.virtual_screen()
        abs_x = int((sx - vx) * 65535 / max(1, vw - 1))
        abs_y = int((sy - vy) * 65535 / max(1, vh - 1))
        return bool(w.send_input([_make_mouse_input(abs_x, abs_y, MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE)]))
    raise ValueError(f"未知鼠标后端：{method}")


def click(hwnd: int, x: int, y: int, method: str = "postmessage", button: str = "left",
          api: Any = None, press_gap_ms: float = PRESS_GAP_MS, activate: bool = True,
          prime: bool = True) -> bool:
    """在客户区 (x, y) 单击一次。"""
    w = api or default_api()
    x, y = int(x), int(y)
    if method == "sendinput":
        return _send_input_mouse(w, hwnd, x, y, button, activate=activate)
    if method not in MOUSE_BACKENDS:
        raise ValueError(f"未知鼠标后端：{method}")
    timeout = SEND_TIMEOUT_MS if method == "sendmessage" else None
    if prime:
        _send_mouse_message(w, hwnd, WM_MOUSEMOVE, x, y, timeout=timeout)
        sleep_ms(MOVE_GAP_MS)
    if button == "right":
        down, up, state = WM_RBUTTONDOWN, WM_RBUTTONUP, MK_RBUTTON
    else:
        down, up, state = WM_LBUTTONDOWN, WM_LBUTTONUP, MK_LBUTTON
    ok_down = _send_mouse_message(w, hwnd, down, x, y, wparam=state, timeout=timeout)
    sleep_ms(press_gap_ms)
    ok_up = _send_mouse_message(w, hwnd, up, x, y, timeout=timeout)
    return bool(ok_down and ok_up)


def double_click(hwnd: int, x: int, y: int, method: str = "postmessage", api: Any = None,
                 interval_ms: float = 90, **kwargs: Any) -> bool:
    first = click(hwnd, x, y, method=method, api=api, **kwargs)
    sleep_ms(interval_ms)
    second = click(hwnd, x, y, method=method, api=api, activate=False, **kwargs)
    return bool(first and second)


def mouse_down(hwnd: int, x: int, y: int, button: str = "left", method: str = "postmessage",
               api: Any = None) -> bool:
    """按下鼠标左/右键（录制回放需要精确控制按下-移动-抬起）。"""
    w = api or default_api()
    x, y = int(x), int(y)
    if method == "sendinput":
        sx, sy = w.client_to_screen(hwnd, x, y)
        vx, vy, vw, vh = w.virtual_screen()
        ax = int((sx - vx) * 65535 / max(1, vw - 1))
        ay = int((sy - vy) * 65535 / max(1, vh - 1))
        flag = MOUSEEVENTF_RIGHTDOWN if button == "right" else MOUSEEVENTF_LEFTDOWN
        return bool(w.send_input([
            _make_mouse_input(ax, ay, MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE),
            _make_mouse_input(ax, ay, flag | MOUSEEVENTF_ABSOLUTE),
        ]))
    if method not in MOUSE_BACKENDS:
        raise ValueError(f"未知鼠标后端：{method}")
    timeout = SEND_TIMEOUT_MS if method == "sendmessage" else None
    _send_mouse_message(w, hwnd, WM_MOUSEMOVE, x, y, timeout=timeout)
    msg = WM_RBUTTONDOWN if button == "right" else WM_LBUTTONDOWN
    state = MK_RBUTTON if button == "right" else MK_LBUTTON
    return _send_mouse_message(w, hwnd, msg, x, y, wparam=state, timeout=timeout)


def mouse_move(hwnd: int, x: int, y: int, button: Optional[str] = None,
               method: str = "postmessage", api: Any = None) -> bool:
    w = api or default_api()
    x, y = int(x), int(y)
    state = 0
    if button == "right":
        state = MK_RBUTTON
    elif button == "left":
        state = MK_LBUTTON
    if method == "sendinput":
        sx, sy = w.client_to_screen(hwnd, x, y)
        vx, vy, vw, vh = w.virtual_screen()
        ax = int((sx - vx) * 65535 / max(1, vw - 1))
        ay = int((sy - vy) * 65535 / max(1, vh - 1))
        return bool(w.send_input([_make_mouse_input(ax, ay, MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE)]))
    if method not in MOUSE_BACKENDS:
        raise ValueError(f"未知鼠标后端：{method}")
    timeout = SEND_TIMEOUT_MS if method == "sendmessage" else None
    return _send_mouse_message(w, hwnd, WM_MOUSEMOVE, x, y, wparam=state, timeout=timeout)


def mouse_up(hwnd: int, x: int, y: int, button: str = "left", method: str = "postmessage",
             api: Any = None) -> bool:
    w = api or default_api()
    x, y = int(x), int(y)
    if method == "sendinput":
        sx, sy = w.client_to_screen(hwnd, x, y)
        vx, vy, vw, vh = w.virtual_screen()
        ax = int((sx - vx) * 65535 / max(1, vw - 1))
        ay = int((sy - vy) * 65535 / max(1, vh - 1))
        flag = MOUSEEVENTF_RIGHTUP if button == "right" else MOUSEEVENTF_LEFTUP
        return bool(w.send_input([_make_mouse_input(ax, ay, flag | MOUSEEVENTF_ABSOLUTE)]))
    if method not in MOUSE_BACKENDS:
        raise ValueError(f"未知鼠标后端：{method}")
    timeout = SEND_TIMEOUT_MS if method == "sendmessage" else None
    msg = WM_RBUTTONUP if button == "right" else WM_LBUTTONUP
    return _send_mouse_message(w, hwnd, msg, x, y, timeout=timeout)


def drag_path(hwnd: int, points: Sequence[Tuple[int, int]],
              delays_ms: Optional[Sequence[float]] = None, method: str = "postmessage",
              button: str = "left", api: Any = None, activate: bool = True) -> bool:
    """按给定路径按下-移动-抬起（录制回放用，保留原始时间间隔）。

    ``points`` 至少两个点；``delays_ms[i]`` 表示第 i 步移动前的等待毫秒数。
    """
    coords = [(int(x), int(y)) for x, y in points]
    if not coords:
        return False
    if len(coords) == 1:
        return click(hwnd, coords[0][0], coords[0][1], method=method, button=button, api=api)
    delays = list(delays_ms or [])
    w = api or default_api()
    if method == "sendinput" and activate:
        w.activate(hwnd)
        sleep_ms(120)
    if not mouse_down(hwnd, coords[0][0], coords[0][1], button=button, method=method, api=w):
        return False
    ok = True
    for index in range(1, len(coords)):
        delay = delays[index - 1] if index - 1 < len(delays) else 0
        if delay:
            sleep_ms(delay)
        ok = mouse_move(hwnd, coords[index][0], coords[index][1], button=button,
                        method=method, api=w) and ok
    return mouse_up(hwnd, coords[-1][0], coords[-1][1], button=button, method=method, api=w) and ok


def scroll(hwnd: int, x: int, y: int, delta: int = -120, method: str = "postmessage",
           api: Any = None) -> bool:
    """滚轮：delta>0 向上，<0 向下（单位 120）。"""
    w = api or default_api()
    if method == "sendinput":
        return _send_input_mouse(w, hwnd, x, y, "left", activate=False, wheel=int(delta))
    if method not in MOUSE_BACKENDS:
        raise ValueError(f"未知鼠标后端：{method}")
    wparam = (int(delta) & 0xFFFF) << 16
    timeout = SEND_TIMEOUT_MS if method == "sendmessage" else None
    _send_mouse_message(w, hwnd, WM_MOUSEMOVE, x, y, timeout=timeout)
    return _send_mouse_message(w, hwnd, WM_MOUSEWHEEL, x, y, wparam=wparam, timeout=timeout)


def drag(hwnd: int, x1: int, y1: int, x2: int, y2: int, duration_ms: float = 400.0,
         steps: int = DEFAULT_DRAG_STEPS, method: str = "postmessage", button: str = "left",
         api: Any = None) -> bool:
    """按住拖动（镜头旋转、拉动物品等）。"""
    steps = max(2, int(steps))
    if method == "sendinput":
        w = api or default_api()
        w.activate(hwnd)
        sleep_ms(120)
        sx, sy = w.client_to_screen(hwnd, x1, y1)
        vx, vy, vw, vh = w.virtual_screen()
        vw = max(1, vw - 1)
        vh = max(1, vh - 1)
        abs_x = int((sx - vx) * 65535 / vw)
        abs_y = int((sy - vy) * 65535 / vh)
        down_flag = MOUSEEVENTF_RIGHTDOWN if button == "right" else MOUSEEVENTF_LEFTDOWN
        up_flag = MOUSEEVENTF_RIGHTUP if button == "right" else MOUSEEVENTF_LEFTUP
        seq = [_make_mouse_input(abs_x, abs_y, MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE),
               _make_mouse_input(abs_x, abs_y, down_flag | MOUSEEVENTF_ABSOLUTE)]
        w.send_input(seq)
        for i in range(1, steps + 1):
            t = i / steps
            px = int(round(x1 + (x2 - x1) * t))
            py = int(round(y1 + (y2 - y1) * t))
            psx, psy = w.client_to_screen(hwnd, px, py)
            pax = int((psx - vx) * 65535 / vw)
            pay = int((psy - vy) * 65535 / vh)
            w.send_input([_make_mouse_input(pax, pay, MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE)])
            sleep_ms(duration_ms / steps)
        esx, esy = w.client_to_screen(hwnd, x2, y2)
        eax = int((esx - vx) * 65535 / vw)
        eay = int((esy - vy) * 65535 / vh)
        return bool(w.send_input([_make_mouse_input(eax, eay, up_flag | MOUSEEVENTF_ABSOLUTE)]))
    if method not in MOUSE_BACKENDS:
        raise ValueError(f"未知鼠标后端：{method}")
    w = api or default_api()
    state = MK_RBUTTON if button == "right" else MK_LBUTTON
    down = WM_RBUTTONDOWN if button == "right" else WM_LBUTTONDOWN
    up = WM_RBUTTONUP if button == "right" else WM_LBUTTONUP
    timeout = SEND_TIMEOUT_MS if method == "sendmessage" else None
    _send_mouse_message(w, hwnd, WM_MOUSEMOVE, x1, y1, timeout=timeout)
    _send_mouse_message(w, hwnd, down, x1, y1, wparam=state, timeout=timeout)
    for i in range(1, steps + 1):
        t = i / steps
        px = int(round(x1 + (x2 - x1) * t))
        py = int(round(y1 + (y2 - y1) * t))
        _send_mouse_message(w, hwnd, WM_MOUSEMOVE, px, py, wparam=state, timeout=timeout)
        sleep_ms(duration_ms / steps)
    return _send_mouse_message(w, hwnd, up, x2, y2, timeout=timeout)


# --------------------------------------------------------------------------------------
# 键盘 / 文本
# --------------------------------------------------------------------------------------
def _key_input(vk: int, up: bool = False, scan: int = 0, unicode_mode: bool = False,
               ch: int = 0) -> INPUT:
    item = INPUT()
    item.type = INPUT_KEYBOARD
    flags = KEYEVENTF_KEYUP if up else 0
    if unicode_mode:
        flags |= KEYEVENTF_UNICODE
        item.u.ki = KEYBDINPUT(0, int(ch), flags, 0, 0)
    else:
        item.u.ki = KEYBDINPUT(int(vk), int(scan), flags, 0, 0)
    return item


def send_text(hwnd: int, text: str, method: str = "unicode", api: Any = None,
              per_char_gap_ms: float = 35.0, activate: bool = True) -> bool:
    """向窗口发送文本。

    * ``unicode``：SendInput + KEYEVENTF_UNICODE，等价于真实键盘逐字输入（需窗口有焦点）
    * ``wm_char``：PostMessage(WM_CHAR)，纯后台，依赖引擎自己处理字符消息
    * ``clipboard``：写剪贴板 + Ctrl+V（对中文/长文本最稳，但会改写用户剪贴板）
    """
    w = api or default_api()
    if not text:
        return True
    if method == "wm_char":
        ok = True
        for ch in text:
            ok = bool(w.post_message(hwnd, WM_CHAR, ord(ch), 0)) and ok
            sleep_ms(per_char_gap_ms)
        return ok
    if method == "unicode":
        if activate:
            w.activate(hwnd)
            sleep_ms(150)
        for ch in text:
            w.send_input([_key_input(0, up=False, unicode_mode=True, ch=ord(ch)),
                          _key_input(0, up=True, unicode_mode=True, ch=ord(ch))])
            sleep_ms(per_char_gap_ms)
        return True
    if method == "clipboard":
        if not w.set_clipboard_text(text):
            return False
        if activate:
            w.activate(hwnd)
            sleep_ms(150)
        sleep_ms(80)
        w.send_input([_key_input(VK_CONTROL, up=False), _key_input(0x56, up=False),
                      _key_input(0x56, up=True), _key_input(VK_CONTROL, up=True)])
        sleep_ms(120)
        return True
    raise ValueError(f"未知文本输入方式：{method}")


def send_key(hwnd: int, vk: int, method: str = "postmessage", api: Any = None,
             scan: int = 0) -> bool:
    """按键（虚拟键码）。"""
    w = api or default_api()
    if method == "sendinput":
        try:
            log_scan = int(w.map_virtual_key(vk))
        except Exception:
            log_scan = 0
        return bool(w.send_input([_key_input(vk, up=False, scan=log_scan),
                                  _key_input(vk, up=True, scan=log_scan)]))
    if method == "sendmessage":
        w.send_message_timeout(hwnd, WM_KEYDOWN, vk, 0)
        sleep_ms(PRESS_GAP_MS)
        w.send_message_timeout(hwnd, WM_KEYUP, vk, 0)
        return True
    ok = bool(w.post_message(hwnd, WM_KEYDOWN, vk, 0))
    sleep_ms(PRESS_GAP_MS)
    return bool(w.post_message(hwnd, WM_KEYUP, vk, 0)) and ok


def send_hotkey(hwnd: int, keys: Sequence[int], method: str = "postmessage",
                api: Any = None) -> bool:
    """组合键（如 Ctrl+V）：按顺序按下，反序抬起。"""
    w = api or default_api()
    if method == "sendinput":
        seq = [_key_input(vk, up=False) for vk in keys]
        seq += [_key_input(vk, up=True) for vk in reversed(keys)]
        return bool(w.send_input(seq))
    ok = True
    for vk in keys:
        ok = bool(w.post_message(hwnd, WM_KEYDOWN, vk, 0)) and ok
        sleep_ms(20)
    for vk in reversed(keys):
        ok = bool(w.post_message(hwnd, WM_KEYUP, vk, 0)) and ok
        sleep_ms(20)
    return ok


def press_escape(hwnd: int, method: str = "postmessage", api: Any = None) -> bool:
    return send_key(hwnd, 0x1B, method=method, api=api)


# --------------------------------------------------------------------------------------
# 策略封装：记住每个窗口可用的后端，失败自动降级
# --------------------------------------------------------------------------------------
class InputStrategy:
    """按配置顺序使用鼠标后端；某个后端抛异常/返回失败时自动尝试下一个。"""

    def __init__(self, order: Sequence[str] = DEFAULT_METHOD_ORDER,
                 text_order: Sequence[str] = DEFAULT_TEXT_ORDER,
                 api: Any = None, activate: bool = True,
                 jitter_radius: int = 0, press_gap_ms: float = PRESS_GAP_MS) -> None:
        self.order = tuple(order) or DEFAULT_METHOD_ORDER
        self.text_order = tuple(text_order) or DEFAULT_TEXT_ORDER
        self._api = api
        self.activate = activate
        self.jitter_radius = int(jitter_radius)
        self.press_gap_ms = float(press_gap_ms)
        self._chosen: Dict[int, str] = {}
        self._chosen_text: Dict[int, str] = {}
        self._failures: Dict[str, int] = {}

    # -- 内部 --
    def _methods(self, hwnd: int) -> List[str]:
        chosen = self._chosen.get(hwnd)
        if not chosen:
            return list(self.order)
        return [chosen] + [m for m in self.order if m != chosen]

    def _record(self, hwnd: int, method: str, ok: bool) -> None:
        if ok:
            self._chosen[hwnd] = method
        else:
            self._failures[method] = self._failures.get(method, 0) + 1
            if self._chosen.get(hwnd) == method:
                self._chosen.pop(hwnd, None)

    # -- 对外 --
    def click(self, hwnd: int, x: int, y: int, button: str = "left",
              method: Optional[str] = None) -> InputResult:
        if self.jitter_radius:
            x, y = jitter_point(x, y, self.jitter_radius)
        last_error = ""
        for candidate in ([method] if method else self._methods(hwnd)):
            try:
                ok = click(hwnd, x, y, method=candidate, button=button, api=self._api,
                           press_gap_ms=self.press_gap_ms, activate=self.activate)
            except Exception as exc:  # noqa: BLE001
                last_error = repr(exc)
                self._record(hwnd, candidate, False)
                continue
            self._record(hwnd, candidate, ok)
            if ok:
                return InputResult(True, candidate, "click", {"x": x, "y": y, "button": button})
            last_error = "调用返回失败"
        return InputResult(False, method or (self.order[0] if self.order else ""), "click",
                           {"x": x, "y": y, "error": last_error})

    def move(self, hwnd: int, x: int, y: int, method: Optional[str] = None) -> InputResult:
        for candidate in ([method] if method else self._methods(hwnd)):
            try:
                ok = move_mouse(hwnd, x, y, method=candidate, api=self._api)
            except Exception:
                continue
            if ok:
                return InputResult(True, candidate, "move", {"x": x, "y": y})
        return InputResult(False, method or "", "move", {"x": x, "y": y})

    def drag(self, hwnd: int, x1: int, y1: int, x2: int, y2: int, duration_ms: float = 400.0,
             steps: int = DEFAULT_DRAG_STEPS, button: str = "left",
             method: Optional[str] = None) -> InputResult:
        for candidate in ([method] if method else self._methods(hwnd)):
            try:
                ok = drag(hwnd, x1, y1, x2, y2, duration_ms=duration_ms, steps=steps,
                          method=candidate, button=button, api=self._api)
            except Exception:
                continue
            if ok:
                return InputResult(True, candidate, "drag",
                                   {"from": [x1, y1], "to": [x2, y2]})
        return InputResult(False, method or "", "drag", {"from": [x1, y1], "to": [x2, y2]})

    def drag_path(self, hwnd: int, points: Sequence[Tuple[int, int]],
                  delays_ms: Optional[Sequence[float]] = None, button: str = "left",
                  method: Optional[str] = None) -> InputResult:
        coords = [(int(x), int(y)) for x, y in points]
        for candidate in ([method] if method else self._methods(hwnd)):
            try:
                ok = drag_path(hwnd, coords, delays_ms=delays_ms, method=candidate,
                               button=button, api=self._api, activate=self.activate)
            except Exception:
                continue
            if ok:
                return InputResult(True, candidate, "dragPath", {"points": len(coords)})
        return InputResult(False, method or "", "dragPath", {"points": len(coords)})

    def hotkey(self, hwnd: int, keys: Sequence[int], method: Optional[str] = None) -> InputResult:
        for candidate in ([method] if method else self._methods(hwnd)):
            try:
                ok = send_hotkey(hwnd, keys, method=candidate, api=self._api)
            except Exception:
                continue
            if ok:
                return InputResult(True, candidate, "hotkey", {"keys": list(keys)})
        return InputResult(False, method or "", "hotkey", {"keys": list(keys)})

    def text(self, hwnd: int, value: str, method: Optional[str] = None) -> InputResult:
        candidates = [method] if method else self.text_order
        for candidate in candidates:
            try:
                ok = send_text(hwnd, value, method=candidate, api=self._api,
                               activate=self.activate)
            except Exception:
                continue
            if ok:
                self._chosen_text[hwnd] = candidate
                return InputResult(True, candidate, "text", {"length": len(value)})
        return InputResult(False, method or "", "text", {"length": len(value)})

    def key(self, hwnd: int, vk: int, method: Optional[str] = None) -> InputResult:
        for candidate in ([method] if method else self._methods(hwnd)):
            try:
                ok = send_key(hwnd, vk, method=candidate, api=self._api)
            except Exception:
                continue
            if ok:
                return InputResult(True, candidate, "key", {"vk": vk})
        return InputResult(False, method or "", "key", {"vk": vk})

    def scroll(self, hwnd: int, x: int, y: int, delta: int = -120,
               method: Optional[str] = None) -> InputResult:
        for candidate in ([method] if method else self._methods(hwnd)):
            try:
                ok = scroll(hwnd, x, y, delta=delta, method=candidate, api=self._api)
            except Exception:
                continue
            if ok:
                return InputResult(True, candidate, "scroll", {"delta": delta})
        return InputResult(False, method or "", "scroll", {"delta": delta})

    def stats(self) -> Dict[str, Any]:
        return {
            "chosenMouse": dict(self._chosen),
            "chosenText": dict(self._chosen_text),
            "failures": dict(self._failures),
        }

    def invalidate(self, hwnd: Optional[int] = None) -> None:
        if hwnd is None:
            self._chosen.clear()
            self._chosen_text.clear()
        else:
            self._chosen.pop(hwnd, None)
            self._chosen_text.pop(hwnd, None)
