#!/usr/bin/env python3
# coding=utf-8
"""录制手势的 Windows 回放（把 Android sendevent 触屏回放换成鼠标消息回放）。

录制的动作结构与旧版一致，因此录制数据（RecordedFlow JSON）可以直接复用：

    {"type": "tap"|"longPress"|"longPressSwipe"|其它(视为滑动),
     "delayMs": 距上一个动作的等待,
     "durationMs": 动作总时长,
     "holdBeforeMoveMs": 长按后开始移动前的保持时间,
     "startX"/"startY"/"endX"/"endY": 录制分辨率下的坐标,
     "dragPath": [{"x":..,"y":..,"delayMs":..}, ...]}   # 可选，拖动轨迹采样点

坐标链：录制分辨率 →（缩放）→ 设计分辨率(1600x900) →（设备层）→ 真实窗口客户区。
"""

from __future__ import annotations

from typing import Any, Callable, Dict, List, Optional, Sequence, Tuple

MIN_HOLD_MS = 350
MIN_MOVE_MS = 60
DEFAULT_STEPS = 12
MIN_STEP_DELAY_MS = 8


def clamp_point(x: int, y: int, size: Optional[Tuple[int, int]],
                margin: int = 4) -> Tuple[int, int]:
    """把点限制在可用区域内（保留边距，避免点到窗口边框）。"""
    raw_x, raw_y = int(x), int(y)
    if size and size[0] > 0 and size[1] > 0:
        max_x = max(int(size[0]) - 2, 0)
        max_y = max(int(size[1]) - 2, 0)
    else:
        max_x, max_y = 1598, 898
    min_x = margin if max_x >= margin else 0
    min_y = margin if max_y >= margin else 0
    return min(max(raw_x, min_x), max_x), min(max(raw_y, min_y), max_y)


def scale_recorded_point(x: int, y: int, source_size: Optional[Tuple[int, int]],
                         target_size: Optional[Tuple[int, int]],
                         margin: int = 4) -> Tuple[int, int]:
    raw_x, raw_y = int(x), int(y)
    if (source_size and target_size and source_size[0] > 0 and source_size[1] > 0
            and target_size[0] > 0 and target_size[1] > 0):
        raw_x = round(raw_x / source_size[0] * target_size[0])
        raw_y = round(raw_y / source_size[1] * target_size[1])
    return clamp_point(raw_x, raw_y, target_size, margin=margin)


def recorded_flow_screen_size(flow: Dict[str, Any]) -> Optional[Tuple[int, int]]:
    width = int(flow.get("screenWidth", 0) or 0)
    height = int(flow.get("screenHeight", 0) or 0)
    if width > 0 and height > 0:
        return width, height
    return None


def action_timing(action: Dict[str, Any]) -> Dict[str, int]:
    """把动作换算成"按住多久 / 移动多久 / 是否单点"。"""
    action_type = str(action.get("type", "tap") or "tap")
    duration_ms = max(int(action.get("durationMs", 120) or 0), 0)
    hold_before_move_ms = max(int(action.get("holdBeforeMoveMs", 0) or 0), 0)
    hold_ms = 0
    if action_type == "longPress":
        hold_ms = max(duration_ms, MIN_HOLD_MS)
    elif action_type == "longPressSwipe":
        hold_ms = max(hold_before_move_ms, MIN_HOLD_MS)
    if action_type in ("tap", "longPress"):
        move_duration_ms = 0
    elif action_type == "longPressSwipe":
        move_duration_ms = max(duration_ms - hold_before_move_ms, MIN_MOVE_MS)
    else:
        move_duration_ms = max(duration_ms, MIN_MOVE_MS)
    return {
        "type": action_type,
        "durationMs": duration_ms,
        "holdMs": hold_ms,
        "moveDurationMs": move_duration_ms,
    }


def build_replay_plan(action: Dict[str, Any], source_size: Optional[Tuple[int, int]],
                      target_size: Optional[Tuple[int, int]]) -> Dict[str, Any]:
    """把单个录制动作翻译成"点序列 + 每步等待"的回放计划。"""
    timing = action_timing(action)
    start = scale_recorded_point(int(action.get("startX", 0) or 0),
                                 int(action.get("startY", 0) or 0), source_size, target_size)
    end = scale_recorded_point(int(action.get("endX", 0) or 0),
                               int(action.get("endY", 0) or 0), source_size, target_size)
    if timing["type"] in ("tap", "longPress"):
        # 录制数据里这两种动作没有终点（老版本会写 0,0），一律视为原地按点
        end = start
    drag_path = action.get("dragPath", [])
    if not isinstance(drag_path, list):
        drag_path = []

    points: List[Tuple[int, int]] = [start]
    delays: List[float] = []
    if timing["type"] == "tap":
        return {"kind": "tap", "start": start, "end": start, "points": [start],
                "delaysMs": [], "timing": timing}

    if timing["holdMs"] > 0:
        # 长按：原地点按按住指定时长
        points.append(start)
        delays.append(float(timing["holdMs"]))
    if start != end or drag_path:
        if drag_path:
            for point in drag_path:
                raw_x = int(point.get("x", start[0]) or start[0])
                raw_y = int(point.get("y", start[1]) or start[1])
                move = scale_recorded_point(raw_x, raw_y, source_size, target_size)
                points.append(move)
                delays.append(max(int(point.get("delayMs", 0) or 0), 0))
        else:
            steps = DEFAULT_STEPS
            step_delay = max(int(round(timing["moveDurationMs"] / steps)), MIN_STEP_DELAY_MS)
            for index in range(1, steps + 1):
                progress = index / steps
                move_x = start[0] + round((end[0] - start[0]) * progress)
                move_y = start[1] + round((end[1] - start[1]) * progress)
                points.append((move_x, move_y))
                delays.append(step_delay)
        if points[-1] != end:
            points.append(end)
            delays.append(0)
    if len(points) == 1:
        return {"kind": "tap", "start": start, "end": end, "points": points,
                "delaysMs": delays, "timing": timing}
    return {"kind": "drag", "start": start, "end": end, "points": points,
            "delaysMs": delays, "timing": timing}


def replay_action(backend: Any, device_id: str, action: Dict[str, Any],
                  source_size: Optional[Tuple[int, int]],
                  target_size: Optional[Tuple[int, int]],
                  log: Callable[[str], None] = print,
                  describe: bool = False) -> Dict[str, Any]:
    """把一个录制动作回放到时空客户端窗口上。"""
    plan = build_replay_plan(action, source_size, target_size)
    timing = plan["timing"]
    if describe:
        log(f"  action type={timing['type']}, delay={int(action.get('delayMs', 0) or 0)}ms, "
            f"from={plan['start']}, to={plan['end']}, duration={timing['durationMs']}ms, "
            f"dragPoints={max(0, len(plan['points']) - 1)}")
    if plan["kind"] == "tap":
        result = backend.tap(device_id, plan["start"][0], plan["start"][1])
    else:
        result = backend.drag_path(device_id, plan["points"], delays_ms=plan["delaysMs"])
    if not result.get("ok"):
        raise RuntimeError(f"录制动作回放失败: {result.get('error') or result}")
    return result


def replay_actions(backend: Any, device_id: str, actions: Sequence[Dict[str, Any]],
                   source_size: Optional[Tuple[int, int]],
                   target_size: Optional[Tuple[int, int]],
                   log: Callable[[str], None] = print,
                   sleep: Optional[Callable[[float], None]] = None) -> int:
    """按顺序回放一串动作（含动作间 delayMs 等待），返回回放的动作数。"""
    import time as _time

    sleeper = sleep or _time.sleep
    count = 0
    total = len(actions)
    for index, action in enumerate(actions, start=1):
        if not isinstance(action, dict):
            continue
        delay_ms = max(int(action.get("delayMs", 0) or 0), 0)
        if delay_ms > 0:
            sleeper(delay_ms / 1000.0)
        replay_action(backend, device_id, action, source_size, target_size, log=log,
                      describe=True)
        count += 1
        if index % 20 == 0 or index == total:
            log(f"  已回放 {index}/{total} 个动作")
    return count
