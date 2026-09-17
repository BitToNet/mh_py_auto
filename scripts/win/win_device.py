#!/usr/bin/env python3
# coding=utf-8
"""设备层门面：把"窗口 + 截图 + 输入"包装成流程引擎熟悉的设备 API。

对上层（流程引擎、Flutter helper）只暴露：
    list_devices() / screenshot() / tap() / swipe() / input_text() / ...

坐标约定
--------
上层（自定义流程、录制流程、模板图片）**统一使用设计分辨率**（默认 1600x900），
本模块负责：
    设计坐标 --scale--> 真实客户区坐标 --加偏移--> 输入目标窗口坐标
截图则反向归一化到设计分辨率。这样即使窗口尺寸不是 1600x900，
已有的模板图片与流程坐标也能直接复用。
"""

from __future__ import annotations

import json
import os
import random
import sys
import time
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Sequence, Tuple

import win_capture
import win_input
import win_window
from win_api import (IS_WINDOWS, api as default_api, ensure_utf8_stdout, scale_point,
                     sleep_ms)

DEFAULT_CONFIG: Dict[str, Any] = {
    "designWidth": 1600,
    "designHeight": 900,
    "captureMethod": "auto",
    "captureOrder": list(win_capture.DEFAULT_ORDER),
    "captureOrderChild": list(win_capture.CHILD_ORDER),
    "blackRatioMax": win_capture.DEFAULT_BLACK_RATIO_MAX,
    "minColors": win_capture.DEFAULT_MIN_COLORS,
    "inputMethod": "auto",
    "inputTarget": "top",
    "textMethod": "auto",
    "inputOrder": list(win_input.DEFAULT_METHOD_ORDER),
    "textOrder": list(win_input.DEFAULT_TEXT_ORDER),
    "jitterRadius": 2,
    "pressGapMs": 40.0,
    "activateBeforeInput": True,
    "autoResize": False,
    "launcherPath": "",
    "installDir": "",
    "gameExePatterns": list(win_window.DEFAULT_GAME_EXE_PATTERNS),
    "launcherExePatterns": list(win_window.DEFAULT_LAUNCHER_EXE_PATTERNS),
    "titleKeywords": list(win_window.DEFAULT_TITLE_KEYWORDS),
}


@dataclass
class WinDevice:
    device_id: str
    pid: int
    hwnd: int
    title: str
    exe: str
    kind: str
    capture_hwnd: int
    input_hwnd: int
    offset_x: int
    offset_y: int
    capture_width: int
    capture_height: int
    client_width: int
    client_height: int
    is_child_capture: bool
    foreground: bool
    minimized: bool
    dpi: int

    def to_dict(self) -> Dict[str, Any]:
        return {
            "deviceId": self.device_id,
            "pid": self.pid,
            "hwnd": self.hwnd,
            "title": self.title,
            "exe": self.exe,
            "exeName": os.path.basename(self.exe or ""),
            "kind": self.kind,
            "captureHwnd": self.capture_hwnd,
            "inputHwnd": self.input_hwnd,
            "offset": [self.offset_x, self.offset_y],
            "captureSize": [self.capture_width, self.capture_height],
            "clientSize": [self.client_width, self.client_height],
            "isChildCapture": self.is_child_capture,
            "foreground": self.foreground,
            "minimized": self.minimized,
            "dpi": self.dpi,
        }


def default_config_path() -> Optional[str]:
    """<仓库根>/config/win_backend.json（存在则自动加载）。"""
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    path = os.path.join(root, "config", "win_backend.json")
    return path if os.path.isfile(path) else None


def load_config(path: Optional[str] = None, extra: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    config = dict(DEFAULT_CONFIG)
    target = path or default_config_path()
    if target and os.path.isfile(target):
        try:
            with open(target, "r", encoding="utf-8") as fh:
                data = json.load(fh)
            if isinstance(data, dict):
                config.update(data)
        except Exception:
            pass
    if extra:
        config.update(extra)
    return config


class WindowsBackend:
    """时空客户端设备后端（多开即多个设备）。"""

    def __init__(self, config: Optional[Dict[str, Any]] = None,
                 config_path: Optional[str] = None, api: Any = None,
                 capture_strategy: Optional[win_capture.CaptureStrategy] = None,
                 input_strategy: Optional[win_input.InputStrategy] = None) -> None:
        self.config = load_config(config_path, config)
        self.api = api
        self.capture = capture_strategy or win_capture.CaptureStrategy(
            order=self.config["captureOrder"],
            child_order=self.config["captureOrderChild"],
            black_ratio_max=self.config["blackRatioMax"],
            min_colors=self.config["minColors"],
            api=api,
        )
        self.input = input_strategy or win_input.InputStrategy(
            order=self.config["inputOrder"],
            text_order=self.config["textOrder"],
            api=api,
            activate=bool(self.config["activateBeforeInput"]),
            jitter_radius=int(self.config["jitterRadius"]),
            press_gap_ms=float(self.config["pressGapMs"]),
        )
        self._devices: Dict[str, WinDevice] = {}

    # -- 配置 --
    @property
    def design_size(self) -> Tuple[int, int]:
        return int(self.config["designWidth"]), int(self.config["designHeight"])

    def set_config(self, **kwargs: Any) -> None:
        self.config.update(kwargs)

    # -- 枚举 --
    def refresh(self, include_other: bool = False) -> List[WinDevice]:
        windows = win_window.list_windows(
            api=self.api,
            include_other=include_other,
            game_patterns=self.config["gameExePatterns"],
            launcher_patterns=self.config["launcherExePatterns"],
            title_keywords=self.config["titleKeywords"],
        )
        devices: List[WinDevice] = []
        grouped: Dict[int, win_window.WindowInfo] = {}
        for info in windows:
            current = grouped.get(info.pid)
            if current is None:
                grouped[info.pid] = info
                continue
            # 同一进程有多个顶层窗口时保留面积最大的那个（通常是游戏主窗口）
            if info.client_width * info.client_height > current.client_width * current.client_height:
                grouped[info.pid] = info
        for info in grouped.values():
            devices.append(self._build_device(info))
        self._devices = {device.device_id: device for device in devices}
        return devices

    def _input_target_mode(self) -> str:
        mode = str(self.config.get("inputTarget", "top") or "top").strip().lower()
        return mode if mode in ("top", "capture") else "top"

    def _build_device(self, info: win_window.WindowInfo) -> WinDevice:
        target = win_window.resolve_capture_target(info.hwnd, api=self.api)
        input_hwnd = target.input_hwnd
        offset_x, offset_y = target.offset_x, target.offset_y
        if self._input_target_mode() == "capture" and target.is_child_capture:
            # 有些引擎只认渲染子窗口上的消息：这时把输入直接发给截图目标，
            # 坐标改为相对该子窗口客户区（偏移归零），与截图坐标同一套换算。
            input_hwnd = target.capture_hwnd
            offset_x, offset_y = 0, 0
        return WinDevice(
            device_id=info.device_id, pid=info.pid, hwnd=info.hwnd, title=info.title,
            exe=info.exe, kind=info.kind, capture_hwnd=target.capture_hwnd,
            input_hwnd=input_hwnd, offset_x=offset_x, offset_y=offset_y,
            capture_width=target.width, capture_height=target.height,
            client_width=info.client_width, client_height=info.client_height,
            is_child_capture=target.is_child_capture, foreground=info.foreground,
            minimized=info.minimized, dpi=info.dpi,
        )

    def list_devices(self, include_other: bool = False) -> List[Dict[str, Any]]:
        return [device.to_dict() for device in self.refresh(include_other=include_other)]

    def device_ids(self, include_other: bool = False) -> List[str]:
        return [device.device_id for device in self.refresh(include_other=include_other)]

    def resolve(self, device_id: Optional[str] = None, refresh: bool = True) -> Optional[WinDevice]:
        """把设备标识解析成当前窗口状态；窗口句柄/进程变了会自动跟随。

        接受的写法：``win:12345``、``pid:12345``、``12345``（PID）、``0x1A2B``（HWND）。
        """
        if refresh or not self._devices:
            self.refresh()
        key = "" if device_id is None else str(device_id).strip()
        if not key:
            devices = list(self._devices.values())
            return devices[0] if devices else None
        found = self._devices.get(key)
        if found is not None:
            return found
        body = key.split(":", 1)[1] if ":" in key else key
        try:
            number = int(body, 0)
        except ValueError:
            return None
        by_pid = self._devices.get(f"win:{number}")
        if by_pid is not None:
            return by_pid
        # 当作 HWND 或 PID 再匹配一次（应对窗口重建、pid 前缀写法）
        for info in win_window.list_windows(
            api=self.api, include_other=True,
            game_patterns=self.config["gameExePatterns"],
            launcher_patterns=self.config["launcherExePatterns"],
            title_keywords=self.config["titleKeywords"],
        ):
            if info.hwnd == number or info.pid == number:
                device = self._build_device(info)
                self._devices[device.device_id] = device
                return device
        return None

    def wait_for_new_device(self, exclude_pids: Sequence[int] = (), timeout: float = 120.0,
                            interval: float = 1.5, game_only: bool = True) -> Optional[WinDevice]:
        """等待一个"新的"客户端窗口出现（重启客户端后重新绑定设备用）。"""
        excluded = {int(pid) for pid in exclude_pids}
        deadline = time.time() + max(0.0, timeout)
        while True:
            for device in self.refresh():
                if device.pid in excluded:
                    continue
                if game_only and device.kind != "game":
                    continue
                return device
            if time.time() >= deadline:
                return None
            time.sleep(interval)

    # -- 存活判断 --
    def is_alive(self, device_id: Optional[str] = None) -> bool:
        device = self.resolve(device_id)
        if device is None:
            return False
        w = self.api or default_api()
        return bool(w.is_window(device.input_hwnd))

    # -- 截图 --
    def screenshot(self, device_id: Optional[str] = None, method: Optional[str] = None,
                   normalize: bool = True, save_path: Optional[str] = None,
                   target_size: Optional[Tuple[int, int]] = None):
        """截一帧；默认归一化到设计分辨率，返回 OpenCV 风格 BGR ndarray。"""
        device = self.resolve(device_id)
        if device is None:
            return None
        chosen = None if method in (None, "auto") else method
        if chosen is None:
            chosen = None if self.config["captureMethod"] == "auto" else self.config["captureMethod"]
        result = self.capture.capture(device.capture_hwnd, method=chosen,
                                      is_child=device.is_child_capture)
        image = win_capture.to_numpy(result)
        if image is not None and normalize:
            image = win_capture.normalize_size(image, target_size or self.design_size)
        if save_path:
            if image is not None:
                from win_api import save_bgr_image
                save_bgr_image(save_path, image)
            elif result is not None:
                from win_api import save_bgr_image
                save_bgr_image(save_path, None, buf=result.buf, width=result.width,
                               height=result.height)
        return image

    def screen_size(self, device_id: Optional[str] = None,
                    normalized: bool = True) -> Tuple[int, int]:
        device = self.resolve(device_id)
        if device is None:
            return self.design_size
        if normalized:
            return self.design_size
        return device.capture_width, device.capture_height

    def capture_info(self, device_id: Optional[str] = None) -> Dict[str, Any]:
        device = self.resolve(device_id)
        if device is None:
            return {"ok": False, "error": "设备不存在"}
        result = self.capture.capture(device.capture_hwnd, is_child=device.is_child_capture)
        if result is None:
            return {"ok": False, "error": "截图失败", "device": device.to_dict()}
        return {
            "ok": True, "device": device.to_dict(), "method": result.method,
            "size": [result.width, result.height], "metrics": result.metrics,
            "elapsedMs": round(result.elapsed_ms, 1), "cached": self.capture.chosen_method(
                device.capture_hwnd),
        }

    # -- 坐标换算 --
    def to_real_point(self, device: WinDevice, x: int, y: int) -> Tuple[int, int]:
        """设计坐标 → 输入目标窗口客户区坐标。"""
        rx, ry = scale_point(x, y, self.design_size, (device.capture_width, device.capture_height))
        return rx + device.offset_x, ry + device.offset_y

    def to_design_point(self, device: WinDevice, x: int, y: int) -> Tuple[int, int]:
        rx, ry = int(x) - device.offset_x, int(y) - device.offset_y
        return scale_point(rx, ry, (device.capture_width, device.capture_height), self.design_size)

    def to_screen_point(self, device: WinDevice, x: int, y: int) -> Tuple[int, int]:
        ix, iy = self.to_real_point(device, x, y)
        w = self.api or default_api()
        return w.client_to_screen(device.input_hwnd, ix, iy)

    # -- 输入 --
    def tap(self, device_id: Optional[str] = None, x: int = 0, y: int = 0,
            design_coords: bool = True, random_radius: Optional[int] = None,
            method: Optional[str] = None, button: str = "left") -> Dict[str, Any]:
        device = self.resolve(device_id)
        if device is None:
            return {"ok": False, "error": "设备不存在", "deviceId": device_id}
        radius = self.config["jitterRadius"] if random_radius is None else int(random_radius)
        if design_coords:
            rx, ry = self.to_real_point(device, x, y)
        else:
            rx, ry = int(x), int(y)
        if radius > 0:
            rx += random.randint(-radius, radius)
            ry += random.randint(-radius, radius)
        chosen = None if method in (None, "auto") else method
        if chosen is None and self.config["inputMethod"] != "auto":
            chosen = self.config["inputMethod"]
        result = self.input.click(device.input_hwnd, rx, ry, button=button, method=chosen)
        payload = result.to_dict()
        payload.update({"deviceId": device.device_id, "designPoint": [x, y],
                        "realPoint": [rx, ry]})
        return payload

    def double_tap(self, device_id: Optional[str] = None, x: int = 0, y: int = 0,
                   **kwargs: Any) -> Dict[str, Any]:
        device = self.resolve(device_id)
        if device is None:
            return {"ok": False, "error": "设备不存在"}
        rx, ry = self.to_real_point(device, x, y)
        method = kwargs.get("method")
        chosen = None if method in (None, "auto") else method
        if chosen is None and self.config["inputMethod"] != "auto":
            chosen = self.config["inputMethod"]
        for candidate in ([chosen] if chosen else list(self.input.order)):
            try:
                ok = win_input.double_click(device.input_hwnd, rx, ry, method=candidate,
                                            api=self.api, activate=self.config["activateBeforeInput"])
            except Exception:
                continue
            if ok:
                return {"ok": True, "method": candidate, "realPoint": [rx, ry]}
        return {"ok": False, "error": "双击失败"}

    def drag(self, device_id: Optional[str] = None, x1: int = 0, y1: int = 0,
             x2: int = 0, y2: int = 0, duration_ms: float = 400.0, steps: int = 12,
             method: Optional[str] = None, button: str = "left") -> Dict[str, Any]:
        device = self.resolve(device_id)
        if device is None:
            return {"ok": False, "error": "设备不存在"}
        rx1, ry1 = self.to_real_point(device, x1, y1)
        rx2, ry2 = self.to_real_point(device, x2, y2)
        chosen = None if method in (None, "auto") else method
        if chosen is None and self.config["inputMethod"] != "auto":
            chosen = self.config["inputMethod"]
        result = self.input.drag(device.input_hwnd, rx1, ry1, rx2, ry2, duration_ms=duration_ms,
                                 steps=steps, button=button, method=chosen)
        payload = result.to_dict()
        payload.update({"deviceId": device.device_id, "realFrom": [rx1, ry1],
                        "realTo": [rx2, ry2]})
        return payload

    def swipe(self, device_id: Optional[str] = None, x1: int = 0, y1: int = 0,
              x2: int = 0, y2: int = 0, duration_ms: float = 300.0, **kwargs: Any) -> Dict[str, Any]:
        """与流程引擎的 swipe 语义对齐（时长单位毫秒）。"""
        steps = max(4, int(duration_ms / 30))
        return self.drag(device_id=device_id, x1=x1, y1=y1, x2=x2, y2=y2,
                         duration_ms=duration_ms, steps=steps, **kwargs)

    def drag_path(self, device_id: Optional[str] = None,
                  points: Optional[Sequence[Sequence[int]]] = None,
                  delays_ms: Optional[Sequence[float]] = None, method: Optional[str] = None,
                  button: str = "left") -> Dict[str, Any]:
        """按任意路径拖动（录制回放用）：points 是设计坐标点列。"""
        device = self.resolve(device_id)
        if device is None:
            return {"ok": False, "error": "设备不存在"}
        raw_points = [tuple(point) for point in (points or [])]
        if not raw_points:
            return {"ok": False, "error": "拖动路径为空"}
        real = [self.to_real_point(device, int(x), int(y)) for x, y in raw_points]
        chosen = None if method in (None, "auto") else method
        if chosen is None and self.config["inputMethod"] != "auto":
            chosen = self.config["inputMethod"]
        result = self.input.drag_path(device.input_hwnd, real, delays_ms=delays_ms,
                                      button=button, method=chosen)
        payload = result.to_dict()
        payload.update({"deviceId": device.device_id, "points": len(real)})
        return payload

    def hotkey(self, device_id: Optional[str] = None, keys: Optional[Sequence[int]] = None,
               method: Optional[str] = None) -> Dict[str, Any]:
        device = self.resolve(device_id)
        if device is None:
            return {"ok": False, "error": "设备不存在"}
        key_list = [int(key) for key in (keys or [])]
        if not key_list:
            return {"ok": False, "error": "未指定按键"}
        chosen = None if method in (None, "auto") else method
        result = self.input.hotkey(device.input_hwnd, key_list, method=chosen)
        payload = result.to_dict()
        payload["deviceId"] = device.device_id
        return payload

    def clear_text(self, device_id: Optional[str] = None, method: Optional[str] = None) -> Dict[str, Any]:
        """全选并删除，用于重复输入前清空输入框（尽力而为）。"""
        device = self.resolve(device_id)
        if device is None:
            return {"ok": False, "error": "设备不存在"}
        chosen = None if method in (None, "auto") else method
        select_all = self.input.hotkey(device.input_hwnd, [0x11, 0x41], method=chosen)  # Ctrl+A
        delete = self.input.key(device.input_hwnd, 0x2E, method=chosen)                 # VK_DELETE
        return {"ok": bool(select_all.ok and delete.ok), "deviceId": device.device_id,
                "method": select_all.method, "error": None if select_all.ok and delete.ok else "清空输入框失败"}

    def input_text(self, device_id: Optional[str] = None, text: str = "",
                   method: Optional[str] = None) -> Dict[str, Any]:
        device = self.resolve(device_id)
        if device is None:
            return {"ok": False, "error": "设备不存在"}
        chosen = None if method in (None, "auto") else method
        if chosen is None and self.config["textMethod"] != "auto":
            chosen = self.config["textMethod"]
        result = self.input.text(device.input_hwnd, text, method=chosen)
        payload = result.to_dict()
        payload["deviceId"] = device.device_id
        return payload

    def press_key(self, device_id: Optional[str] = None, vk: int = 0x1B,
                  method: Optional[str] = None) -> Dict[str, Any]:
        device = self.resolve(device_id)
        if device is None:
            return {"ok": False, "error": "设备不存在"}
        chosen = None if method in (None, "auto") else method
        result = self.input.key(device.input_hwnd, vk, method=chosen)
        payload = result.to_dict()
        payload["deviceId"] = device.device_id
        return payload

    def scroll(self, device_id: Optional[str] = None, x: int = 0, y: int = 0,
               delta: int = -120, method: Optional[str] = None) -> Dict[str, Any]:
        device = self.resolve(device_id)
        if device is None:
            return {"ok": False, "error": "设备不存在"}
        rx, ry = self.to_real_point(device, x, y)
        result = self.input.scroll(device.input_hwnd, rx, ry, delta=delta, method=method)
        payload = result.to_dict()
        payload["deviceId"] = device.device_id
        return payload

    def activate(self, device_id: Optional[str] = None) -> Dict[str, Any]:
        device = self.resolve(device_id)
        if device is None:
            return {"ok": False, "error": "设备不存在"}
        ok = win_window.activate(device.hwnd, api=self.api)
        sleep_ms(120)
        return {"ok": bool(ok), "deviceId": device.device_id}

    # -- 窗口尺寸 --
    def ensure_design_size(self, device_id: Optional[str] = None,
                           target: Optional[Tuple[int, int]] = None,
                           force: bool = False) -> Dict[str, Any]:
        """尝试把客户区改成设计分辨率；失败也没关系（截图/坐标会自动缩放）。"""
        device = self.resolve(device_id)
        if device is None:
            return {"ok": False, "error": "设备不存在"}
        width, height = target or self.design_size
        if (device.client_width, device.client_height) == (width, height):
            return {"ok": True, "already": True, "size": [width, height]}
        if device.minimized:
            return {"ok": False, "error": "窗口处于最小化状态，无法调整尺寸"}
        if not force and not self.config["autoResize"]:
            return {"ok": False, "skipped": True,
                    "reason": "autoResize 未开启", "size": [device.client_width, device.client_height]}
        if not win_window.resize_client(device.hwnd, width, height, api=self.api):
            return {"ok": False, "error": "SetWindowPos 失败"}
        sleep_ms(400)
        refreshed = self.resolve(device.device_id)
        if refreshed is None:
            return {"ok": False, "error": "设备消失"}
        matched = (refreshed.client_width, refreshed.client_height) == (width, height)
        return {"ok": matched, "size": [refreshed.client_width, refreshed.client_height],
                "matched": matched, "device": refreshed.to_dict()}

    # -- 启停 --
    def start(self, wait: bool = True, timeout: float = 120.0) -> Dict[str, Any]:
        return win_window.start_client(
            launcher_path=self.config.get("launcherPath") or None,
            install_dir=self.config.get("installDir") or None,
            timeout=timeout, wait=wait, api=self.api,
        )

    def ensure_running(self, device_id: Optional[str] = None,
                       timeout: float = 120.0) -> Dict[str, Any]:
        """确保有可用客户端：没有就拉起启动器并等待窗口出现。"""
        device = self.resolve(device_id, refresh=True)
        if device is not None and not device.minimized:
            return {"ok": True, "already": True, "device": device.to_dict()}
        if device is not None and device.minimized:
            ok = win_window.activate(device.hwnd, api=self.api)
            return {"ok": bool(ok), "restored": bool(ok), "device": device.to_dict()}
        started = self.start(wait=True, timeout=timeout)
        device = self.resolve(None, refresh=True)
        started["device"] = device.to_dict() if device else None
        started["ok"] = device is not None
        return started

    def stop(self, device_id: Optional[str] = None, include_launcher: bool = False) -> Dict[str, Any]:
        device = self.resolve(device_id, refresh=False)
        pid = device.pid if device else None
        result = win_window.stop_client(pid=pid, api=self.api, include_launcher=include_launcher,
                                        exe_patterns=self.config["gameExePatterns"])
        self.capture.invalidate()
        self.input.invalidate()
        return result

    def restart(self, device_id: Optional[str] = None, timeout: float = 120.0) -> Dict[str, Any]:
        """把流程里的"重启游戏/重启应用"映射到重启客户端。"""
        device = self.resolve(device_id, refresh=False)
        pid = device.pid if device else None
        result = win_window.restart_client(
            pid=pid,
            launcher_path=self.config.get("launcherPath") or None,
            install_dir=self.config.get("installDir") or None,
            timeout=timeout, api=self.api,
        )
        self.capture.invalidate()
        self.input.invalidate()
        return result

    def foreground_device(self) -> Optional[str]:
        device = self.resolve(None, refresh=True)
        for item in self._devices.values():
            if item.foreground:
                return item.device_id
        return device.device_id if device else None

    # -- 观测 --
    def stats(self) -> Dict[str, Any]:
        return {"capture": self.capture.stats(), "input": self.input.stats(),
                "devices": [d.to_dict() for d in self._devices.values()]}

    def health(self) -> Dict[str, Any]:
        """给 Flutter/冒烟脚本用的整体自检。"""
        info: Dict[str, Any] = {
            "platform": "windows" if IS_WINDOWS else os.name,
            "isWindows": IS_WINDOWS,
            "admin": None,
            "screen": None,
            "designSize": list(self.design_size),
            "configPath": default_config_path(),
            "environment": environment_info(self.config),
        }
        if IS_WINDOWS:
            w = self.api or default_api()
            info["admin"] = bool(w.is_admin())
            info["screen"] = list(w.screen_size())
        devices = self.refresh()
        info["deviceCount"] = len(devices)
        info["devices"] = [device.to_dict() for device in devices]
        if devices:
            info["capture"] = self.capture_info(devices[0].device_id)
        return info


def _module_version(name: str) -> Optional[str]:
    """返回已安装的模块版本；没有/装坏了都返回 None（不要在这里抛异常）。"""
    try:
        module = __import__(name)
    except Exception:  # noqa: BLE001 - 缺包、DLL 加载失败等一律视为不可用
        return None
    version = getattr(module, "__version__", "")
    return str(version) if version else "unknown"


def environment_info(config: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """发布包排障用：Python 环境、脚本来源、生效的后端顺序。

    这些字段是"实机报告里最需要看到的东西"：缺 numpy 会让截图失败，
    配置没生效会让默认后端一直是错的。
    """
    settings = dict(DEFAULT_CONFIG)
    settings.update(config or {})
    scripts_dir = os.path.dirname(os.path.abspath(__file__))
    # 注意：default_config_path() 只在文件存在时返回路径，
    # 排障时更需要知道"应该放在哪"，所以这里自己拼一个候选路径。
    root = os.path.dirname(os.path.dirname(scripts_dir))
    config_candidate = os.path.join(root, "config", "win_backend.json")
    config_path = default_config_path()
    return {
        "python": sys.version.split()[0],
        "pythonExecutable": sys.executable,
        "platform": sys.platform,
        "frozen": bool(getattr(sys, "frozen", False)),
        "scriptsDir": scripts_dir,
        "fromExtractedRuntime": os.path.basename(os.path.dirname(scripts_dir)) == "win_runtime"
        or "win_runtime" in scripts_dir,
        "configPath": config_path or config_candidate,
        "configFound": os.path.isfile(config_candidate),
        "designSize": [int(settings["designWidth"]), int(settings["designHeight"])],
        "numpy": _module_version("numpy"),
        "opencv": _module_version("cv2"),
        "rapidocr": _module_version("rapidocr"),
        # 报的是"这个后端实例真正在用的顺序"（含用户 config 覆盖），不是内置默认值
        "captureOrder": [str(item) for item in settings.get("captureOrder")
                         or win_capture.DEFAULT_ORDER],
        "captureOrderChild": [str(item) for item in settings.get("captureOrderChild")
                              or win_capture.CHILD_ORDER],
        "inputOrder": [str(item) for item in settings.get("inputOrder")
                       or win_input.DEFAULT_METHOD_ORDER],
        "textOrder": [str(item) for item in settings.get("textOrder")
                      or win_input.DEFAULT_TEXT_ORDER],
        "inputMethod": str(settings.get("inputMethod", "auto")),
        "textMethod": str(settings.get("textMethod", "auto")),
        "captureMethod": str(settings.get("captureMethod", "auto")),
        "blackRatioMax": float(settings.get("blackRatioMax", 0.9)),
        "minColors": int(settings.get("minColors", 0)),
        "activateBeforeInput": bool(settings.get("activateBeforeInput", True)),
        "jitterRadius": int(settings.get("jitterRadius", 0)),
        "launcherPath": str(settings.get("launcherPath", "") or ""),
        "inputTarget": str(settings.get("inputTarget", "top")),
    }


_BACKEND: Optional[WindowsBackend] = None


def backend(config: Optional[Dict[str, Any]] = None, api: Any = None,
            force_new: bool = False) -> WindowsBackend:
    """全局后端单例（测试请用 set_backend 注入）。"""
    global _BACKEND
    if _BACKEND is None or force_new:
        _BACKEND = WindowsBackend(config=config, api=api)
    return _BACKEND


def set_backend(instance: Optional[WindowsBackend]) -> None:
    global _BACKEND
    _BACKEND = instance


# --------------------------------------------------------------------------------------
# 与旧 adb API 对齐的便捷函数（流程引擎迁移时按名替换即可）
# --------------------------------------------------------------------------------------
def list_connected_device_ids() -> List[str]:
    return backend().device_ids()


def list_devices() -> List[Dict[str, Any]]:
    return backend().list_devices()


def screenshot(device_id: Optional[str] = None, save_path: Optional[str] = None):
    return backend().screenshot(device_id, save_path=save_path)


def screen_size(device_id: Optional[str] = None) -> Tuple[int, int]:
    return backend().screen_size(device_id)


def tap(device_id: Optional[str] = None, x: int = 0, y: int = 0, **kwargs: Any) -> Dict[str, Any]:
    return backend().tap(device_id, x, y, **kwargs)


def swipe(device_id: Optional[str] = None, x1: int = 0, y1: int = 0, x2: int = 0, y2: int = 0,
          duration_ms: float = 300.0, **kwargs: Any) -> Dict[str, Any]:
    return backend().swipe(device_id, x1, y1, x2, y2, duration_ms=duration_ms, **kwargs)


def input_text(device_id: Optional[str] = None, text: str = "", **kwargs: Any) -> Dict[str, Any]:
    return backend().input_text(device_id, text, **kwargs)


def drag_path(device_id: Optional[str] = None, points: Optional[Sequence[Sequence[int]]] = None,
              **kwargs: Any) -> Dict[str, Any]:
    return backend().drag_path(device_id, points, **kwargs)


def hotkey(device_id: Optional[str] = None, keys: Optional[Sequence[int]] = None,
           **kwargs: Any) -> Dict[str, Any]:
    return backend().hotkey(device_id, keys, **kwargs)


def press_key(device_id: Optional[str] = None, vk: int = 0x1B, **kwargs: Any) -> Dict[str, Any]:
    return backend().press_key(device_id, vk, **kwargs)


def ensure_running(device_id: Optional[str] = None, **kwargs: Any) -> Dict[str, Any]:
    return backend().ensure_running(device_id, **kwargs)


def restart_client(device_id: Optional[str] = None, **kwargs: Any) -> Dict[str, Any]:
    return backend().restart(device_id, **kwargs)


def health() -> Dict[str, Any]:
    return backend().health()


def _selftest() -> None:  # pragma: no cover - 手动执行
    ensure_utf8_stdout()
    print(json.dumps(health(), ensure_ascii=False, indent=2))


if __name__ == "__main__":  # pragma: no cover
    _selftest()
