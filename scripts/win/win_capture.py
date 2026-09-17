#!/usr/bin/env python3
# coding=utf-8
"""截图层：多后端实测 + 自动择优 + 按设计分辨率归一化。

后端优先级可以在配置里覆盖；运行时还会自动探测：按顺序尝试，取第一个
"不是黑屏且颜色足够丰富"的后端并缓存结果（同一窗口后续直接复用）。
实机探测报告（tools/win_probe.py 的 win_probe_report.json）只用来调这里的默认顺序。
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional, Sequence, Tuple

from win_api import (PW_CLIENTONLY, PW_RENDERFULLCONTENT, analyze_bgra, api as default_api,
                     bgra_to_bgr_numpy, save_bgr_image)

# 后端名称 -> 调用方式。顺序即默认优先级。
# printwindow_renderfull 支持被遮挡时取图（DWM 重绘），优先；其余依次降级。
DEFAULT_ORDER: Tuple[str, ...] = (
    "printwindow_renderfull",
    "printwindow_client",
    "bitblt_client",
    "printwindow_window",
    "bitblt_window",
)
# 子窗口渲染目标没有窗口边框，窗口级后端意义不大
CHILD_ORDER: Tuple[str, ...] = (
    "printwindow_renderfull",
    "printwindow_client",
    "bitblt_client",
)
DEFAULT_BLACK_RATIO_MAX = 0.995
DEFAULT_MIN_COLORS = 6
DEFAULT_TARGET_SIZE: Tuple[int, int] = (1600, 900)


def usable_metrics(metrics: Optional[Dict[str, Any]],
                   black_ratio_max: float = DEFAULT_BLACK_RATIO_MAX,
                   min_colors: int = DEFAULT_MIN_COLORS) -> bool:
    """后端可用性判定：不是黑屏且颜色够丰富。

    设备层的 CaptureStrategy 与"探测报告 → 配置"的推荐工具共用这一条规则，
    保证推荐出来的后端和运行时真正会选的是同一套标准。
    """
    data = metrics or {}
    if not data.get("valid"):
        return False
    if float(data.get("black_ratio", 1.0)) > float(black_ratio_max):
        return False
    return int(data.get("distinct_colors_sampled", 0)) >= int(min_colors)


@dataclass
class CaptureResult:
    hwnd: int
    method: str
    width: int
    height: int
    buf: bytes
    elapsed_ms: float = 0.0
    metrics: Dict[str, Any] = field(default_factory=dict)
    probe_fallbacks: List[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return bool(self.buf) and self.width > 0 and self.height > 0

    @property
    def size(self) -> Tuple[int, int]:
        return self.width, self.height

    def to_dict(self) -> Dict[str, Any]:
        return {
            "hwnd": self.hwnd, "method": self.method, "width": self.width,
            "height": self.height, "elapsedMs": round(self.elapsed_ms, 1),
            "metrics": self.metrics, "fallbacks": self.probe_fallbacks,
        }


def _pw_flags_method(flags: int) -> Callable[[Any, int], Optional[bytes]]:
    return lambda w, hwnd: w.print_window(hwnd, flags)


METHODS: Dict[str, Callable[[Any, int], Optional[bytes]]] = {
    "printwindow_renderfull": _pw_flags_method(PW_CLIENTONLY | PW_RENDERFULLCONTENT),
    "printwindow_client": _pw_flags_method(PW_CLIENTONLY),
    "printwindow_window": _pw_flags_method(0),
    "bitblt_client": lambda w, hwnd: w.bit_blt_window(hwnd, use_window_dc=False),
    "bitblt_window": lambda w, hwnd: w.bit_blt_window(hwnd, use_window_dc=True),
}


def capture_bgra(hwnd: int, method: str = "printwindow_renderfull", api: Any = None) -> Optional[CaptureResult]:
    """用指定后端截一帧；失败返回 None。"""
    w = api or default_api()
    fn = METHODS.get(method)
    if fn is None:
        raise ValueError(f"未知截图后端：{method}")
    if method.startswith("printwindow") and method != "printwindow_window":
        width, height = w.client_rect(hwnd)
    elif method == "printwindow_window":
        _, _, width, height = w.window_rect(hwnd)
    else:
        width, height = w.client_rect(hwnd)
    t0 = time.perf_counter()
    try:
        buf = fn(w, hwnd)
    except Exception:
        return None
    elapsed = (time.perf_counter() - t0) * 1000.0
    if not buf:
        return None
    return CaptureResult(
        hwnd=hwnd, method=method, width=width, height=height, buf=buf,
        elapsed_ms=elapsed, metrics=analyze_bgra(buf, width, height),
    )


def probe_methods(hwnd: int, order: Sequence[str] = DEFAULT_ORDER,
                  api: Any = None) -> List[Dict[str, Any]]:
    """逐个后端实测，返回每个后端的指标（供冒烟脚本/报告使用）。"""
    out: List[Dict[str, Any]] = []
    for name in order:
        result = capture_bgra(hwnd, name, api=api)
        if result is None:
            out.append({"method": name, "ok": False})
        else:
            out.append({"method": name, "ok": True, **result.to_dict()})
    return out


class CaptureStrategy:
    """带缓存的自动择优截图策略。"""

    def __init__(self, order: Sequence[str] = DEFAULT_ORDER,
                 child_order: Sequence[str] = CHILD_ORDER,
                 black_ratio_max: float = DEFAULT_BLACK_RATIO_MAX,
                 min_colors: int = DEFAULT_MIN_COLORS,
                 api: Any = None) -> None:
        self.order = tuple(order) or DEFAULT_ORDER
        self.child_order = tuple(child_order) or CHILD_ORDER
        self.black_ratio_max = float(black_ratio_max)
        self.min_colors = int(min_colors)
        self._api = api
        self._chosen: Dict[int, str] = {}
        self._stats: Dict[str, int] = {}

    # -- 可用性判定 --
    def _usable(self, result: Optional[CaptureResult]) -> bool:
        if result is None or not result.ok:
            return False
        return usable_metrics(result.metrics, self.black_ratio_max, self.min_colors)

    def order_for(self, hwnd: int, is_child: bool = False) -> Tuple[str, ...]:
        return self.child_order if is_child else self.order

    def capture(self, hwnd: int, method: Optional[str] = None, is_child: bool = False,
                verify_cached: bool = True) -> Optional[CaptureResult]:
        """截图。method 指定则只用该后端；否则用缓存/自动择优。"""
        w = self._api or default_api()
        if method:
            result = capture_bgra(hwnd, method, api=w)
            self._stats[method] = self._stats.get(method, 0) + (1 if self._usable(result) else 0)
            return result
        cached = self._chosen.get(hwnd)
        if cached and verify_cached:
            result = capture_bgra(hwnd, cached, api=w)
            if self._usable(result):
                return result
            self._chosen.pop(hwnd, None)
        fallbacks: List[str] = []
        for name in self.order_for(hwnd, is_child=is_child):
            if name == cached:
                continue
            result = capture_bgra(hwnd, name, api=w)
            if self._usable(result):
                result.probe_fallbacks = fallbacks
                self._chosen[hwnd] = name
                self._stats[name] = self._stats.get(name, 0) + 1
                for bad in fallbacks:
                    self._stats[bad] = self._stats.get(bad, 0)
                return result
            fallbacks.append(name)
        # 全部不合格：返回最后一个能拿到的结果，交给上层决定（至少不崩）
        last = capture_bgra(hwnd, self.order_for(hwnd, is_child=is_child)[-1], api=w)
        if last is not None:
            last.probe_fallbacks = fallbacks
        return last

    # -- 观察接口 --
    def chosen_method(self, hwnd: int) -> Optional[str]:
        return self._chosen.get(hwnd)

    def invalidate(self, hwnd: Optional[int] = None) -> None:
        if hwnd is None:
            self._chosen.clear()
        else:
            self._chosen.pop(hwnd, None)

    def stats(self) -> Dict[str, Any]:
        return {"chosen": dict(self._chosen), "counters": dict(self._stats)}


def to_numpy(result: Optional[CaptureResult]):
    if result is None or not result.ok:
        return None
    return bgra_to_bgr_numpy(result.buf, result.width, result.height)


def normalize_size(image, target: Tuple[int, int]):
    """把图像缩放到设计分辨率（模板匹配前调用），缺 cv2 时用 numpy 最近邻。"""
    if image is None:
        return None
    tw, th = int(target[0]), int(target[1])
    if tw <= 0 or th <= 0:
        return image
    try:
        height, width = image.shape[0], image.shape[1]
    except Exception:
        return image
    if (width, height) == (tw, th):
        return image
    try:
        import cv2
        interpolation = cv2.INTER_AREA if (width > tw or height > th) else cv2.INTER_LINEAR
        return cv2.resize(image, (tw, th), interpolation=interpolation)
    except Exception:
        pass
    try:
        import numpy as np
        ys = (np.arange(th) * height // th).clip(0, height - 1)
        xs = (np.arange(tw) * width // tw).clip(0, width - 1)
        return image[ys][:, xs]
    except Exception:
        return image


def capture_image(hwnd: int, strategy: Optional[CaptureStrategy] = None,
                  method: Optional[str] = None, is_child: bool = False,
                  target_size: Optional[Tuple[int, int]] = None, api: Any = None):
    """一步到位：截图 → ndarray(BGR) →（可选）缩放到设计分辨率。"""
    strategy = strategy or CaptureStrategy(api=api)
    result = strategy.capture(hwnd, method=method, is_child=is_child)
    image = to_numpy(result)
    if image is not None and target_size:
        image = normalize_size(image, target_size)
    return image, result


def capture_to_file(path: str, hwnd: int, strategy: Optional[CaptureStrategy] = None,
                    method: Optional[str] = None, target_size: Optional[Tuple[int, int]] = None,
                    api: Any = None) -> Optional[CaptureResult]:
    strategy = strategy or CaptureStrategy(api=api)
    result = strategy.capture(hwnd, method=method)
    if result is None:
        return None
    image = to_numpy(result)
    if image is not None and target_size:
        image = normalize_size(image, target_size)
    if image is not None:
        save_bgr_image(path, image)
    else:
        save_bgr_image(path, None, buf=result.buf, width=result.width, height=result.height)
    return result


def usable_image(image) -> bool:
    """给流程引擎用：判断截到的图是否"有内容"（避免黑屏当正常图送去做模板匹配）。"""
    if image is None:
        return False
    try:
        import numpy as np
        arr = np.asarray(image)
        if arr.size == 0:
            return False
        return float(arr.mean()) > 3.0
    except Exception:
        return True
