#!/usr/bin/env python3
# coding=utf-8
"""时空客户端 Windows 版：鼠标手势录制（全局低级钩子）。

录制的是"人对着窗口做的操作"，输出结构与旧版 Android 录制完全一致
（`RecordedAction` JSON），因此录制数据可以被自定义流程与录制回放直接复用：

    {"type": "tap"|"longPress"|"swipe"|"longPressSwipe",
     "delayMs": 距上一个动作结束的等待,
     "durationMs": 从按下到抬起,
     "holdBeforeMoveMs": 按住多久之后才开始移动,
     "startX"/"startY"/"endX"/"endY": 设计分辨率(1600x900)坐标,
     "dragPath": [{"x":..,"y":..,"delayMs":..}, ...],
     "rawEvents": []}

坐标链：屏幕坐标 → 目标窗口客户区 → 减去截图目标偏移 → 缩放到设计分辨率。
这样录制与回放共用同一套换算，窗口多大都不用改流程。

依赖系统低级鼠标钩子 `WH_MOUSE_LL`（需要消息循环，所以在本模块自己的线程里跑）。
注意：钩子只能看到**同等或更低完整性级别**进程的输入，目标客户端若以管理员运行，
录制端也需要管理员权限，否则收不到事件。
"""

from __future__ import annotations

import ctypes
import sys
import threading
import time
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Tuple

import win_api

WH_MOUSE_LL = 14
WM_MOUSEMOVE = 0x0200
WM_LBUTTONDOWN = 0x0201
WM_LBUTTONUP = 0x0202
WM_RBUTTONDOWN = 0x0204
WM_RBUTTONUP = 0x0205
WM_MOUSEWHEEL = 0x020A
WM_QUIT = 0x0012
GA_ROOT = 2

DEFAULT_SAMPLE_INTERVAL_MS = 16
DEFAULT_LONG_PRESS_MS = 350
DEFAULT_MOVE_TOLERANCE_PX = 6
DEFAULT_MAX_PATH_POINTS = 600


@dataclass
class PointerEvent:
    """一次指针事件（坐标已经是设计分辨率坐标）。"""

    time_ms: float
    kind: str  # down / move / up
    x: int
    y: int


@dataclass
class _PendingPress:
    start: Tuple[int, int]
    start_time: float
    last_point: Tuple[int, int]
    last_time: float
    first_move_time: Optional[float] = None
    max_distance: float = 0.0
    path: List[Dict[str, int]] = field(default_factory=list)
    last_sample_time: float = 0.0


class GestureBuilder:
    """把连续的指针事件聚合成录制动作（纯逻辑，可单测）。"""

    def __init__(
        self,
        sample_interval_ms: int = DEFAULT_SAMPLE_INTERVAL_MS,
        long_press_ms: int = DEFAULT_LONG_PRESS_MS,
        move_tolerance_px: int = DEFAULT_MOVE_TOLERANCE_PX,
        max_path_points: int = DEFAULT_MAX_PATH_POINTS,
    ) -> None:
        self.sample_interval_ms = max(int(sample_interval_ms), 1)
        self.long_press_ms = max(int(long_press_ms), 1)
        self.move_tolerance_px = max(int(move_tolerance_px), 0)
        self.max_path_points = max(int(max_path_points), 2)
        self._actions: List[Dict[str, Any]] = []
        self._pending: Optional[_PendingPress] = None
        self._last_end_time: Optional[float] = None

    # -- 输入 --
    def feed(self, event: PointerEvent) -> None:
        if event.kind == "down":
            self._close_pending(event.time_ms)
            self._pending = _PendingPress(
                start=(int(event.x), int(event.y)),
                start_time=float(event.time_ms),
                last_point=(int(event.x), int(event.y)),
                last_time=float(event.time_ms),
                last_sample_time=float(event.time_ms),
            )
            return
        pending = self._pending
        if pending is None:
            return
        if event.kind == "move":
            self._feed_move(pending, event)
            return
        if event.kind == "up":
            pending.last_point = (int(event.x), int(event.y))
            pending.last_time = float(event.time_ms)
            self._close_pending(event.time_ms)

    def _feed_move(self, pending: _PendingPress, event: PointerEvent) -> None:
        dx = event.x - pending.start[0]
        dy = event.y - pending.start[1]
        distance = (dx * dx + dy * dy) ** 0.5
        pending.max_distance = max(pending.max_distance, distance)
        pending.last_point = (int(event.x), int(event.y))
        pending.last_time = float(event.time_ms)
        if pending.max_distance <= self.move_tolerance_px:
            return
        if pending.first_move_time is None:
            pending.first_move_time = float(event.time_ms)
        elapsed = float(event.time_ms) - pending.last_sample_time
        if elapsed < self.sample_interval_ms and pending.path:
            return
        if len(pending.path) >= self.max_path_points:
            return
        pending.path.append(
            {
                "x": int(event.x),
                "y": int(event.y),
                "delayMs": max(int(round(elapsed)), 0),
            }
        )
        pending.last_sample_time = float(event.time_ms)

    # -- 收尾 --
    def _close_pending(self, now_ms: float) -> Optional[Dict[str, Any]]:
        pending = self._pending
        self._pending = None
        if pending is None:
            return None
        duration_ms = max(int(round(max(now_ms, pending.last_time) - pending.start_time)), 0)
        moved = pending.max_distance > self.move_tolerance_px
        if not moved:
            action_type = "longPress" if duration_ms >= self.long_press_ms else "tap"
            end_x, end_y = pending.start
            hold_before_move_ms = 0
            drag_path: List[Dict[str, int]] = []
        else:
            end_x, end_y = pending.last_point
            first_move = pending.first_move_time or pending.start_time
            hold_before_move_ms = max(int(round(first_move - pending.start_time)), 0)
            if hold_before_move_ms >= self.long_press_ms:
                action_type = "longPressSwipe"
                hold_before_move_ms = max(hold_before_move_ms, self.long_press_ms)
            else:
                action_type = "swipe"
            drag_path = list(pending.path)
        delay_ms = 0
        if self._last_end_time is not None:
            delay_ms = max(int(round(pending.start_time - self._last_end_time)), 0)
        self._last_end_time = max(now_ms, pending.last_time)
        action = {
            "type": action_type,
            "delayMs": delay_ms,
            "startX": int(pending.start[0]),
            "startY": int(pending.start[1]),
            "endX": int(end_x),
            "endY": int(end_y),
            "durationMs": duration_ms,
            "holdBeforeMoveMs": hold_before_move_ms,
            "dragPath": drag_path,
            "rawEvents": [],
        }
        self._actions.append(action)
        return action

    def finish(self) -> List[Dict[str, Any]]:
        """录制结束时调用：没抬起的按下动作按长按收尾。"""
        if self._pending is not None:
            self._close_pending(self._pending.last_time)
        return self.actions()

    def actions(self) -> List[Dict[str, Any]]:
        return [dict(action) for action in self._actions]

    @property
    def action_count(self) -> int:
        return len(self._actions)


class MouseHookRecorder:
    """在独立线程里安装 WH_MOUSE_LL，把目标窗口上的鼠标操作录成动作列表。"""

    def __init__(
        self,
        input_hwnd: int,
        top_hwnd: Optional[int] = None,
        offset: Tuple[int, int] = (0, 0),
        capture_size: Tuple[int, int] = (1600, 900),
        design_size: Tuple[int, int] = (1600, 900),
        sample_interval_ms: int = DEFAULT_SAMPLE_INTERVAL_MS,
        long_press_ms: int = DEFAULT_LONG_PRESS_MS,
        target_pid: Optional[int] = None,
        api: Any = None,
    ) -> None:
        # 非 Windows 平台不在构造期就抛错，留到 start() 给出可读提示
        self.api = api if api is not None else (win_api.api() if win_api.IS_WINDOWS else None)
        self.input_hwnd = int(input_hwnd)
        self.top_hwnd = int(top_hwnd or input_hwnd)
        self.offset = (int(offset[0]), int(offset[1]))
        self.capture_size = (max(int(capture_size[0]), 1), max(int(capture_size[1]), 1))
        self.design_size = (max(int(design_size[0]), 1), max(int(design_size[1]), 1))
        self.target_pid = target_pid
        self.builder = GestureBuilder(sample_interval_ms=sample_interval_ms,
                                      long_press_ms=long_press_ms)
        self._thread: Optional[threading.Thread] = None
        self._thread_id: Optional[int] = None
        self._hook: Any = None
        self._callback = None
        self._pressed = False
        self._error: Optional[str] = None
        self._started = threading.Event()
        self._lock = threading.Lock()
        self._event_count = 0

    # -- 生命周期 --
    def start(self) -> None:
        if self._thread is not None:
            raise RuntimeError("录制已经在进行中")
        if not win_api.IS_WINDOWS:
            raise RuntimeError("鼠标手势录制只能在 Windows 上运行")
        self._thread = threading.Thread(target=self._thread_main, name="win-mouse-recorder",
                                        daemon=True)
        self._thread.start()
        if not self._started.wait(timeout=5):
            raise RuntimeError("录制线程启动超时")
        if self._error:
            raise RuntimeError(f"安装鼠标钩子失败：{self._error}")

    def stop(self) -> List[Dict[str, Any]]:
        thread = self._thread
        if thread is None:
            return self.builder.actions()
        if self._thread_id:
            try:
                self.api.user32.PostThreadMessageW(int(self._thread_id), WM_QUIT, 0, 0)
            except Exception:
                pass
        thread.join(timeout=5)
        self._thread = None
        self._thread_id = None
        return self.builder.finish()

    @property
    def is_running(self) -> bool:
        return self._thread is not None

    def snapshot_actions(self) -> List[Dict[str, Any]]:
        """线程安全地取当前已录制的动作（录制过程中轮询用）。"""
        with self._lock:
            return self.builder.actions()

    def status(self) -> Dict[str, Any]:
        return {
            "running": self.is_running,
            "eventCount": self._event_count,
            "actionCount": self.builder.action_count,
            "error": self._error,
        }

    # -- 线程 --
    def _thread_main(self) -> None:
        user32 = self.api.user32
        try:
            self._thread_id = int(self.api.kernel32.GetCurrentThreadId())
        except Exception:
            self._thread_id = None
        try:
            self._callback = win_api.HOOKPROC(self._hook_proc)
            self._hook = user32.SetWindowsHookExW(WH_MOUSE_LL, self._callback, None, 0)
            if not self._hook:
                self._error = f"SetWindowsHookExW 返回 NULL（错误码 {ctypes.get_last_error()}）"
                self._started.set()
                return
        except Exception as exc:  # noqa: BLE001
            self._error = f"{type(exc).__name__}: {exc}"
            self._started.set()
            return
        self._started.set()
        msg = win_api.MSG()
        try:
            while user32.GetMessageW(ctypes.byref(msg), None, 0, 0) > 0:
                user32.TranslateMessage(ctypes.byref(msg))
                user32.DispatchMessageW(ctypes.byref(msg))
        finally:
            try:
                user32.UnhookWindowsHookEx(self._hook)
            except Exception:
                pass
            self._hook = None

    def _hook_proc(self, n_code: int, w_param: int, l_param: int) -> int:
        user32 = self.api.user32
        if n_code < 0:
            return int(user32.CallNextHookEx(None, n_code, w_param, l_param))
        try:
            self._handle_message(int(w_param), l_param)
        except Exception:
            pass
        return int(user32.CallNextHookEx(None, n_code, w_param, l_param))

    # -- 事件处理 --
    def _handle_message(self, message: int, l_param: int) -> None:
        if message not in (WM_MOUSEMOVE, WM_LBUTTONDOWN, WM_LBUTTONUP,
                           WM_RBUTTONDOWN, WM_RBUTTONUP, WM_MOUSEWHEEL):
            return
        info = ctypes.cast(l_param, ctypes.POINTER(win_api.MSLLHOOKSTRUCT)).contents
        screen_x, screen_y = int(info.pt.x), int(info.pt.y)
        if message == WM_MOUSEMOVE:
            if not self._pressed:
                return
            point = self._to_design(screen_x, screen_y)
            self._feed("move", point)
            return
        if message in (WM_LBUTTONDOWN, WM_RBUTTONDOWN):
            if not self._window_matches(screen_x, screen_y):
                return
            self._pressed = True
            self._feed("down", self._to_design(screen_x, screen_y))
            return
        if message in (WM_LBUTTONUP, WM_RBUTTONUP):
            if not self._pressed:
                return
            self._pressed = False
            self._feed("up", self._to_design(screen_x, screen_y))

    def _feed(self, kind: str, point: Tuple[int, int]) -> None:
        with self._lock:
            self._event_count += 1
            self.builder.feed(PointerEvent(time_ms=time.time() * 1000.0, kind=kind,
                                           x=point[0], y=point[1]))

    def _to_design(self, screen_x: int, screen_y: int) -> Tuple[int, int]:
        client_x, client_y = self.api.screen_to_client(self.input_hwnd, screen_x, screen_y)
        local_x = int(client_x) - self.offset[0]
        local_y = int(client_y) - self.offset[1]
        design_x = round(local_x / self.capture_size[0] * self.design_size[0])
        design_y = round(local_y / self.capture_size[1] * self.design_size[1])
        max_x = max(self.design_size[0] - 2, 0)
        max_y = max(self.design_size[1] - 2, 0)
        return (
            min(max(int(design_x), 0), max_x),
            min(max(int(design_y), 0), max_y),
        )

    def _window_matches(self, screen_x: int, screen_y: int) -> bool:
        """只在目标窗口上的按下才算录制起点（多开时不会串台）。"""
        try:
            point = win_api.POINT(int(screen_x), int(screen_y))
            hwnd = int(self.api.user32.WindowFromPoint(point) or 0)
            if not hwnd:
                return False
            root = int(self.api.user32.GetAncestor(hwnd, GA_ROOT) or hwnd)
            if root == self.top_hwnd:
                return True
            if self.target_pid is None:
                return False
            return int(self.api.pid_of(hwnd)) == int(self.target_pid)
        except Exception:
            return False


def build_actions_from_events(
    events: List[Tuple[float, str, int, int]],
    sample_interval_ms: int = DEFAULT_SAMPLE_INTERVAL_MS,
    long_press_ms: int = DEFAULT_LONG_PRESS_MS,
) -> List[Dict[str, Any]]:
    """给测试与离线分析用的便捷入口：events = [(time_ms, kind, x, y), ...]。"""
    builder = GestureBuilder(sample_interval_ms=sample_interval_ms, long_press_ms=long_press_ms)
    for time_ms, kind, x, y in events:
        builder.feed(PointerEvent(time_ms=float(time_ms), kind=kind, x=int(x), y=int(y)))
    return builder.finish()


def main(argv: Optional[List[str]] = None) -> int:
    """命令行自检：录 N 秒然后把动作 JSON 打到 stdout（Windows 实机排查用）。"""
    import json

    argv = list(argv if argv is not None else sys.argv[1:])
    if not win_api.IS_WINDOWS:
        print(
            f"鼠标手势录制只能在 Windows 上运行（当前平台：{sys.platform}）。\n"
            "请在装有《梦幻西游：时空》客户端的 Windows 机器上执行：\n"
            "  python scripts\\win\\win_record.py 10",
            file=sys.stderr,
        )
        return 2
    seconds = float(argv[0]) if argv else 10.0
    win_api.ensure_utf8_stdout()
    backend = None
    try:
        import win_device
        backend = win_device.backend()
    except Exception as exc:  # noqa: BLE001
        print(f"设备层不可用：{exc}", file=sys.stderr)
    device = backend.resolve(None) if backend else None
    if device is None:
        print("没有找到客户端窗口", file=sys.stderr)
        return 1
    recorder = MouseHookRecorder(
        input_hwnd=device.input_hwnd,
        top_hwnd=device.hwnd,
        offset=(device.offset_x, device.offset_y),
        capture_size=(device.capture_width, device.capture_height),
        design_size=(1600, 900),
        target_pid=device.pid,
        api=backend.api if backend else None,
    )
    recorder.start()
    print(f"开始录制 {seconds:.0f} 秒，请在客户端窗口上操作…", file=sys.stderr)
    time.sleep(max(seconds, 0.5))
    actions = recorder.stop()
    print(json.dumps(actions, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
