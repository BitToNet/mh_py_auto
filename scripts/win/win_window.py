#!/usr/bin/env python3
# coding=utf-8
"""窗口 / 进程层：识别时空客户端实例、解析截图目标、启停客户端。

设备标识统一为 ``win:<pid>``；HWND 只在运行期有效，PID 在客户端存活期内稳定，
所以对流程引擎暴露 PID，内部再解析成 HWND。
"""

from __future__ import annotations

import os
import subprocess
import time
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Sequence, Tuple

from win_api import (IS_WINDOWS, WS_THICKFRAME, api as default_api, clamp_point,
                     exe_basename, exe_dirname)

# 游戏窗口进程名（小写匹配）；不同版本/桌面版命名不同，全部兜住
DEFAULT_GAME_EXE_PATTERNS: Tuple[str, ...] = (
    "mygame", "mymain", "mhxy", "xyq", "shikong",
)
# 启动器 / 预加载器：用于"启动客户端""确保在运行"
DEFAULT_LAUNCHER_EXE_PATTERNS: Tuple[str, ...] = (
    "mypclauncher", "mylauncher", "mypreloader", "mypclauncherupdater",
)
DEFAULT_TITLE_KEYWORDS: Tuple[str, ...] = ("梦幻西游", "时空")
DEFAULT_LAUNCHER_NAMES: Tuple[str, ...] = (
    "MyPCLauncher_x64r.exe", "MyLauncher_x64r.exe", "mymain.exe", "MyGame_x64r.exe",
)
# 子窗口面积达到客户区该比例时，认为它才是真正的渲染窗口
CHILD_AREA_RATIO = 0.6


@dataclass
class WindowInfo:
    hwnd: int
    title: str
    class_name: str
    pid: int
    exe: str
    client_width: int
    client_height: int
    visible: bool
    minimized: bool
    foreground: bool
    dpi: int
    resizable: bool
    kind: str  # game / launcher / other

    @property
    def exe_name(self) -> str:
        return exe_basename(self.exe)

    @property
    def client_size(self) -> Tuple[int, int]:
        return self.client_width, self.client_height

    @property
    def device_id(self) -> str:
        return f"win:{self.pid}"

    def to_dict(self) -> Dict[str, Any]:
        return {
            "deviceId": self.device_id,
            "hwnd": self.hwnd,
            "title": self.title,
            "className": self.class_name,
            "pid": self.pid,
            "exe": self.exe,
            "exeName": self.exe_name,
            "clientWidth": self.client_width,
            "clientHeight": self.client_height,
            "visible": self.visible,
            "minimized": self.minimized,
            "foreground": self.foreground,
            "dpi": self.dpi,
            "resizable": self.resizable,
            "kind": self.kind,
        }


@dataclass
class ProcessInfo:
    pid: int
    exe_name: str
    path: str = ""

    @property
    def kind(self) -> str:
        return classify_exe(self.exe_name)


@dataclass
class CaptureTarget:
    """截图/输入目标：窗口句柄 + 坐标偏移 + 逻辑尺寸。

    某些引擎的真实画面在子窗口里，这时 capture_hwnd != top_hwnd，
    坐标需要加上子窗口相对顶层客户区的偏移。
    """

    top_hwnd: int
    capture_hwnd: int
    input_hwnd: int
    offset_x: int
    offset_y: int
    width: int
    height: int
    is_child_capture: bool = False
    children: List[Dict[str, Any]] = field(default_factory=list)

    def to_capture_coords(self, x: int, y: int) -> Tuple[int, int]:
        return int(x) - self.offset_x, int(y) - self.offset_y

    def to_top_coords(self, x: int, y: int) -> Tuple[int, int]:
        return int(x) + self.offset_x, int(y) + self.offset_y


def classify_exe(exe_name: str, game_patterns: Sequence[str] = DEFAULT_GAME_EXE_PATTERNS,
                 launcher_patterns: Sequence[str] = DEFAULT_LAUNCHER_EXE_PATTERNS) -> str:
    name = (exe_name or "").lower()
    if not name:
        return "other"
    if any(p and p in name for p in game_patterns):
        return "game"
    if any(p and p in name for p in launcher_patterns):
        return "launcher"
    return "other"


def _match_title(title: str, keywords: Sequence[str]) -> bool:
    t = (title or "").lower()
    return any(k and k.lower() in t for k in keywords)


def list_windows(api: Any = None, include_hidden: bool = False,
                 game_patterns: Sequence[str] = DEFAULT_GAME_EXE_PATTERNS,
                 launcher_patterns: Sequence[str] = DEFAULT_LAUNCHER_EXE_PATTERNS,
                 title_keywords: Sequence[str] = DEFAULT_TITLE_KEYWORDS,
                 include_other: bool = False) -> List[WindowInfo]:
    """枚举顶层窗口；默认只返回与客户端相关的（game/launcher）。"""
    w = api or default_api()
    foreground = w.foreground_window()
    out: List[WindowInfo] = []
    for hwnd in w.enum_top_windows():
        visible = w.is_visible(hwnd)
        if not visible and not include_hidden:
            continue
        title = w.window_text(hwnd)
        cls = w.class_name(hwnd)
        pid = w.pid_of(hwnd)
        exe = w.process_path(pid)
        kind = classify_exe(exe_basename(exe), game_patterns, launcher_patterns)
        if kind == "other":
            if "messiah" in (cls or "").lower():
                kind = "game"
            elif not _match_title(title, title_keywords):
                if not include_other:
                    continue
                kind = "other"
            else:
                kind = "game"
        cw, ch = w.client_rect(hwnd)
        style, _ = w.get_style(hwnd)
        out.append(WindowInfo(
            hwnd=hwnd, title=title, class_name=cls, pid=pid, exe=exe,
            client_width=cw, client_height=ch, visible=visible,
            minimized=w.is_minimized(hwnd), foreground=(hwnd == foreground),
            dpi=w.dpi_of(hwnd), resizable=bool(style & WS_THICKFRAME), kind=kind,
        ))
    # 游戏窗口优先，其次按 PID 稳定排序，保证多开时设备顺序稳定
    order = {"game": 0, "launcher": 1, "other": 2}
    out.sort(key=lambda item: (order.get(item.kind, 3), item.pid, item.hwnd))
    return out


def client_windows(api: Any = None, prefer: str = "game", **kwargs: Any) -> List[WindowInfo]:
    """客户端窗口清单；prefer='game' 时只要游戏窗口，没有则退回启动器窗口。"""
    windows = list_windows(api=api, **kwargs)
    games = [w for w in windows if w.kind == "game"]
    if prefer == "game" and games:
        return games
    return windows


def list_client_processes(api: Any = None) -> List[ProcessInfo]:
    w = api or default_api()
    out: List[ProcessInfo] = []
    for pid, exe_name in w.list_processes():
        kind = classify_exe(exe_name)
        if kind == "other":
            continue
        out.append(ProcessInfo(pid=pid, exe_name=exe_name, path=w.process_path(pid)))
    out.sort(key=lambda item: (0 if item.kind == "game" else 1, item.pid))
    return out


def child_windows(hwnd: int, api: Any = None) -> List[Dict[str, Any]]:
    w = api or default_api()
    out: List[Dict[str, Any]] = []
    for child in w.enum_child_windows(hwnd):
        cw, ch = w.client_rect(child)
        out.append({
            "hwnd": child,
            "class_name": w.class_name(child),
            "title": w.window_text(child),
            "client_width": cw,
            "client_height": ch,
            "visible": w.is_visible(child),
        })
    return out


def resolve_capture_target(hwnd: int, api: Any = None,
                           capture_hwnd: Optional[int] = None,
                           input_hwnd: Optional[int] = None) -> CaptureTarget:
    """决定"从哪个窗口截图、往哪个窗口发消息、坐标偏移多少"。

    如果顶层窗口客户端区域有占绝对面积的可见子窗口，优先把它当作渲染窗口
    （Messiah 这类引擎常见结构）；否则用顶层窗口本身。
    """
    w = api or default_api()
    top_w, top_h = w.client_rect(hwnd)
    children = child_windows(hwnd, api=w)

    target_child: Optional[Dict[str, Any]] = None
    if capture_hwnd:
        for item in children:
            if item["hwnd"] == capture_hwnd:
                target_child = item
                break
    else:
        best_area = 0
        for item in children:
            if not item["visible"]:
                continue
            area = item["client_width"] * item["client_height"]
            if area > best_area:
                best_area = area
                target_child = item
        if target_child is not None:
            ratio = (target_child["client_width"] * target_child["client_height"]) / max(1, top_w * top_h)
            if ratio < CHILD_AREA_RATIO or target_child["client_width"] <= 0:
                target_child = None

    if target_child is None:
        return CaptureTarget(
            top_hwnd=hwnd, capture_hwnd=hwnd,
            input_hwnd=input_hwnd or hwnd,
            offset_x=0, offset_y=0, width=top_w, height=top_h,
            is_child_capture=False, children=children,
        )

    child_hwnd = target_child["hwnd"]
    offset_x, offset_y = w.client_to_screen(child_hwnd, 0, 0)
    top_x, top_y = w.client_to_screen(hwnd, 0, 0)
    return CaptureTarget(
        top_hwnd=hwnd,
        capture_hwnd=child_hwnd,
        input_hwnd=input_hwnd or hwnd,
        offset_x=offset_x - top_x,
        offset_y=offset_y - top_y,
        width=target_child["client_width"],
        height=target_child["client_height"],
        is_child_capture=True,
        children=children,
    )


def resize_client(hwnd: int, width: int, height: int, api: Any = None) -> bool:
    w = api or default_api()
    return bool(w.resize_client(hwnd, width, height))


def activate(hwnd: int, api: Any = None) -> bool:
    w = api or default_api()
    return bool(w.activate(hwnd))


def is_minimized(hwnd: int, api: Any = None) -> bool:
    w = api or default_api()
    return bool(w.is_minimized(hwnd))


def wait_for_window(timeout: float = 60.0, interval: float = 1.0,
                    game_patterns: Sequence[str] = DEFAULT_GAME_EXE_PATTERNS,
                    api: Any = None, pid: Optional[int] = None) -> Optional[WindowInfo]:
    """等待客户端窗口出现（启动/重启后使用）。"""
    deadline = time.time() + max(0.0, timeout)
    while True:
        for info in list_windows(api=api, game_patterns=game_patterns):
            if pid is not None and info.pid != pid:
                continue
            if not info.minimized and info.client_width > 0:
                return info
        if time.time() >= deadline:
            return None
        time.sleep(interval)


def find_install_dir(api: Any = None) -> Optional[str]:
    """从正在运行的客户端进程推断安装目录。"""
    for proc in list_client_processes(api=api):
        if proc.path:
            return exe_dirname(proc.path)
    return None


def resolve_launcher_path(install_dir: Optional[str] = None,
                          api: Any = None) -> Optional[str]:
    """在安装目录里找启动器；找不到就返回 None（由调用方报错提示配置路径）。"""
    base = install_dir or find_install_dir(api=api)
    if not base or not os.path.isdir(base):
        return None
    candidates: List[str] = []
    for name in DEFAULT_LAUNCHER_NAMES:
        candidates.append(os.path.join(base, name))
        candidates.append(os.path.join(base, "Engine", "Binaries", "Win64", name))
    for path in candidates:
        if os.path.isfile(path):
            return path
    return None


def start_client(launcher_path: Optional[str] = None, install_dir: Optional[str] = None,
                 timeout: float = 120.0, wait: bool = True,
                 api: Any = None) -> Dict[str, Any]:
    """启动时空客户端；返回 {started, path, pid, window}。

    说明：启动器负责登录与更新，稳定做法是拉起 ``MyPCLauncher_x64r.exe``。
    """
    if not IS_WINDOWS:
        return {"started": False, "error": "非 Windows 平台无法启动客户端"}
    path = launcher_path or resolve_launcher_path(install_dir=install_dir, api=api)
    if not path or not os.path.isfile(path):
        return {
            "started": False,
            "error": "找不到客户端启动器，请在配置里指定 launcherPath"
                     "（一般为 <安装目录>\\MyPCLauncher_x64r.exe）",
        }
    workdir = install_dir or os.path.dirname(path)
    creationflags = 0
    if hasattr(subprocess, "DETACHED_PROCESS"):
        creationflags = subprocess.DETACHED_PROCESS | getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
    try:
        proc = subprocess.Popen([path], cwd=workdir, creationflags=creationflags, close_fds=True)
    except Exception as exc:  # noqa: BLE001
        return {"started": False, "error": f"启动失败：{exc!r}", "path": path}
    result: Dict[str, Any] = {"started": True, "path": path, "pid": proc.pid}
    if wait:
        info = wait_for_window(timeout=timeout, api=api)
        result["window"] = info.to_dict() if info else None
    return result


def stop_client(pid: Optional[int] = None, exe_patterns: Sequence[str] = DEFAULT_GAME_EXE_PATTERNS,
                api: Any = None, include_launcher: bool = False) -> Dict[str, Any]:
    """结束客户端进程（含子进程）。优先 taskkill，失败再走 TerminateProcess。"""
    if not IS_WINDOWS:
        return {"stopped": [], "error": "非 Windows 平台"}
    targets: List[int] = []
    if pid:
        targets.append(int(pid))
    else:
        patterns = tuple(exe_patterns) + (DEFAULT_LAUNCHER_EXE_PATTERNS if include_launcher else ())
        for proc in list_client_processes(api=api):
            name = proc.exe_name.lower()
            if any(p and p in name for p in patterns):
                targets.append(proc.pid)
    stopped: List[int] = []
    for target in sorted(set(targets)):
        ok = False
        try:
            completed = subprocess.run(
                ["taskkill", "/PID", str(target), "/T", "/F"],
                capture_output=True, text=True, timeout=15,
            )
            ok = completed.returncode == 0
        except Exception:
            ok = False
        if not ok:
            try:
                ok = bool((api or default_api()).terminate_process(target))
            except Exception:
                ok = False
        if ok:
            stopped.append(target)
    return {"stopped": stopped, "requested": sorted(set(targets))}


def restart_client(pid: Optional[int] = None, launcher_path: Optional[str] = None,
                   install_dir: Optional[str] = None, timeout: float = 120.0,
                   api: Any = None) -> Dict[str, Any]:
    """重启客户端：结束进程 → 等待窗口消失 → 重新拉起 → 等待窗口出现。"""
    killed = stop_client(pid=pid, api=api, include_launcher=True)
    deadline = time.time() + 20
    while time.time() < deadline:
        if not list_windows(api=api):
            break
        time.sleep(0.5)
    started = start_client(launcher_path=launcher_path, install_dir=install_dir,
                           timeout=timeout, api=api)
    return {"stopped": killed, "started": started}


def foreground_device_id(api: Any = None) -> Optional[str]:
    """当前前台窗口对应的设备 id（用于"跟随前台窗口"这类策略）。"""
    for info in list_windows(api=api, include_other=True):
        if info.foreground:
            return info.device_id
    return None


def safe_point(x: int, y: int, size: Tuple[int, int]) -> Tuple[int, int]:
    return clamp_point(x, y, size)
