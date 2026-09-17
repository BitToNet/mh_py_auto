#!/usr/bin/env python3
# coding=utf-8
"""时空客户端设备层冒烟测试（在 Windows 上运行）。

与 tools/win_probe.py 的区别：
* win_probe.py 直接怼 Win32，用来"探测未知"；
* smoke_win.py 走 **设备层真实代码路径**（win_device / win_capture / win_input），
  用来"验收已实现"，也就是 Flutter 与流程引擎将要走的同一条路。

用法：
    python tools\\smoke_win.py                 # 只读检查：枚举 + 截图（不碰游戏）
    python tools\\smoke_win.py --input         # 追加点击生效性测试（会真的点游戏）
    python tools\\smoke_win.py --input --resize --yes
    python tools\\smoke_win.py --text abc --yes

产物：smoke_out/smoke_report.json + smoke_out/*.bmp
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from typing import Any, Dict, List, Optional, Sequence, Tuple

TOOLS_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.path.dirname(TOOLS_DIR)
WIN_DIR = os.path.join(ROOT_DIR, "scripts", "win")
if WIN_DIR not in sys.path:
    sys.path.insert(0, WIN_DIR)

import win_api  # noqa: E402
import win_capture  # noqa: E402
import win_device  # noqa: E402
import win_input  # noqa: E402

RESULTS: List[Tuple[str, bool, str]] = []


def record(name: str, ok: bool, detail: str = "") -> bool:
    RESULTS.append((name, bool(ok), detail))
    flag = "PASS" if ok else "FAIL"
    print(f"  [{flag}] {name}" + (f" — {detail}" if detail else ""))
    return bool(ok)


def _grab(backend: win_device.WindowsBackend, device, method: Optional[str] = None
          ) -> Optional[win_capture.CaptureResult]:
    return backend.capture.capture(device.capture_hwnd, method=method,
                                   is_child=device.is_child_capture)


def _save(out_dir: str, name: str, result: Optional[win_capture.CaptureResult]) -> Optional[str]:
    if result is None:
        return None
    path = os.path.join(out_dir, f"{name}.bmp")
    win_api.save_bgra_bmp(path, result.buf, result.width, result.height)
    return path


def check_health(backend: win_device.WindowsBackend, out_dir: str) -> Dict[str, Any]:
    print("\n== 1. 运行环境 ==")
    w = backend.api or win_api.api()
    info: Dict[str, Any] = {
        "isWindows": win_api.IS_WINDOWS,
        "admin": bool(w.is_admin()),
        "dpiAware": w.set_dpi_aware(),
        "screen": list(w.screen_size()),
        "python": sys.version.split()[0],
        "designSize": list(backend.design_size),
        "cwd": os.getcwd(),
    }
    record("运行在 Windows", info["isWindows"])
    record("管理员权限", info["admin"], "建议用管理员运行，否则可能控制不了游戏窗口" if not info["admin"] else "")
    print(f"      屏幕={info['screen']} DPI感知={info['dpiAware']} Python={info['python']}")
    try:
        import numpy
        info["numpy"] = numpy.__version__
        record("numpy 可用", True, info["numpy"])
    except Exception as exc:  # noqa: BLE001
        record("numpy 可用", False, repr(exc))
    try:
        import cv2
        info["opencv"] = cv2.__version__
        record("OpenCV 可用", True, info["opencv"])
    except Exception as exc:  # noqa: BLE001
        record("OpenCV 可用", False, repr(exc))
    info["backendConfig"] = backend.config
    # 环境画像：报告里有了这些，排障就不用再问一轮"你的配置生效了吗"
    environment = win_device.environment_info(backend.config)
    info["environment"] = environment
    config_state = environment["configPath"] if environment["configFound"] else "（未找到，使用内置默认值）"
    print(f"      脚本位置={environment['scriptsDir']}"
          f"{'（发布版解包运行时）' if environment['fromExtractedRuntime'] else ''}")
    print(f"      配置文件={config_state}")
    print(f"      生效截图顺序={' > '.join(environment['captureOrder'])}")
    print(f"      生效输入顺序={' > '.join(environment['inputOrder'])}"
          f"  输入目标={environment['inputTarget']}")
    return info


def check_devices(backend: win_device.WindowsBackend) -> List[win_device.WinDevice]:
    print("\n== 2. 客户端实例枚举 ==")
    devices = backend.refresh()
    record("找到时空客户端窗口", bool(devices), f"{len(devices)} 个实例")
    for device in devices:
        print(f"      {device.device_id} hwnd=0x{device.hwnd:X} 标题={device.title!r}")
        print(f"        进程={os.path.basename(device.exe)} 客户区={device.client_width}x{device.client_height}"
              f" 截图窗口={'子窗口' if device.is_child_capture else '顶层窗口'}"
              f" 偏移=({device.offset_x},{device.offset_y}) 最小化={device.minimized}")
    return devices


def check_capture(backend: win_device.WindowsBackend, device: win_device.WinDevice,
                  out_dir: str) -> Dict[str, Any]:
    print(f"\n== 3. 截图（{device.device_id}） ==")
    order = win_capture.CHILD_ORDER if device.is_child_capture else win_capture.DEFAULT_ORDER
    methods = win_capture.probe_methods(device.capture_hwnd, order=order, api=backend.api)
    result: Dict[str, Any] = {"methods": methods}
    for item in methods:
        if item.get("ok"):
            metrics = item.get("metrics", {})
            print(f"      {item['method']:<24} {item['width']}x{item['height']} "
                  f"黑屏率={metrics.get('black_ratio')} 颜色={metrics.get('distinct_colors_sampled')} "
                  f"{item.get('elapsedMs')}ms → {item.get('file', '')}")
        else:
            print(f"      {item['method']:<24} 失败")
    usable = [item for item in methods
              if item.get("ok") and item.get("metrics", {}).get("black_ratio", 1) < 0.9]
    record("至少一个截图后端可用", bool(usable),
           f"可用后端：{[item['method'] for item in usable]}")

    cached = backend.capture.capture(device.capture_hwnd, is_child=device.is_child_capture)
    result["chosen"] = cached.method if cached else None
    if cached:
        result["chosenMetrics"] = cached.metrics
        result["file"] = _save(out_dir, f"{device.device_id.replace(':','_')}_chosen", cached)
        print(f"      自动选中：{cached.method}（{cached.metrics.get('black_ratio')} 黑屏率）")
    # 归一化后的设计分辨率截图
    image = backend.screenshot(device.device_id)
    if image is not None:
        result["normalizedShape"] = list(image.shape)
        path = os.path.join(out_dir, f"{device.device_id.replace(':','_')}_design.bmp")
        win_api.save_bgr_image(path, image)
        record("截图可归一化到设计分辨率", tuple(image.shape[:2]) == (backend.design_size[1],
                                                              backend.design_size[0]),
               f"{image.shape[1]}x{image.shape[0]}")
    return result


def check_resize(backend: win_device.WindowsBackend, device: win_device.WinDevice) -> Dict[str, Any]:
    print(f"\n== 4. 窗口尺寸归一化（{device.device_id}） ==")
    result = backend.ensure_design_size(device.device_id, force=True)
    target_w, target_h = backend.design_size
    record(f"客户区可改为 {target_w}x{target_h}", bool(result.get("matched")),
           json.dumps(result, ensure_ascii=False))
    return result


def check_input(backend: win_device.WindowsBackend, device: win_device.WinDevice,
                click_point: Tuple[int, int], out_dir: str, delay: float) -> Dict[str, Any]:
    print(f"\n== 5. 点击生效性（{device.device_id}） ==")
    point = click_point if click_point != (-1, -1) else (backend.design_size[0] // 2,
                                                         backend.design_size[1] // 2)
    print(f"      设计坐标 {point}（真实坐标 {backend.to_real_point(device, *point)}）")

    def shot(name: str) -> Optional[win_capture.CaptureResult]:
        got = _grab(backend, device)
        _save(out_dir, name, got)
        return got

    base_a = shot("input_00_before")
    time.sleep(delay)
    base_b = shot("input_01_baseline")
    baseline = 0.0
    if base_a and base_b:
        diff = win_api.diff_bgra(base_a.buf, base_b.buf, base_a.width, base_a.height)
        baseline = float(diff.get("changed_ratio", 0.0))
    print(f"      画面自然变化基线 = {baseline}")

    result: Dict[str, Any] = {"clickPoint": list(point), "baselineRatio": baseline, "methods": {}}
    for method in win_input.MOUSE_BACKENDS:
        before = shot(f"input_{method}_before")
        try:
            outcome = backend.tap(device.device_id, point[0], point[1], method=method,
                                  random_radius=0)
        except Exception as exc:  # noqa: BLE001
            outcome = {"ok": False, "error": repr(exc)}
        time.sleep(delay)
        after = shot(f"input_{method}_after")
        entry: Dict[str, Any] = {"tap": outcome}
        if before and after:
            diff = win_api.diff_bgra(before.buf, after.buf, before.width, before.height)
            ratio = float(diff.get("changed_ratio", 0.0))
            entry["changedRatio"] = ratio
            entry["likelyEffective"] = ratio > max(0.002, baseline * 2.5)
            print(f"      {method:<14} 变化={ratio:<8} 相对基线={round(ratio - baseline, 4):<8} "
                  f"自动判定={'生效' if entry['likelyEffective'] else '未生效'}")
        else:
            print(f"      {method:<14} 截图失败，无法判定")
        result["methods"][method] = entry
    viable = [name for name, entry in result["methods"].items() if entry.get("likelyEffective")]
    record("至少一种点击方式生效", bool(viable), f"疑似生效：{viable}")
    return result


def check_text(backend: win_device.WindowsBackend, device: win_device.WinDevice,
               text: str) -> Dict[str, Any]:
    print(f"\n== 6. 文本输入（{device.device_id}） ==")
    result = backend.input_text(device.device_id, text)
    record("文本输入调用成功", bool(result.get("ok")), json.dumps(result, ensure_ascii=False))
    return result


def main(argv: Optional[Sequence[str]] = None,
         backend: Optional[win_device.WindowsBackend] = None) -> int:
    parser = argparse.ArgumentParser(description="时空客户端设备层冒烟测试")
    parser.add_argument("--out", default="smoke_out", help="输出目录")
    parser.add_argument("--device", default=None, help="只测指定设备（win:<pid>）")
    parser.add_argument("--input", action="store_true", help="执行点击生效性测试（会真的点游戏）")
    parser.add_argument("--text", default="", help="文本输入测试内容（需先手动点开输入框）")
    parser.add_argument("--resize", action="store_true", help="尝试把客户区改成设计分辨率")
    parser.add_argument("--click-x", type=int, default=-1)
    parser.add_argument("--click-y", type=int, default=-1)
    parser.add_argument("--delay", type=float, default=1.2, help="点击前后等待秒数")
    parser.add_argument("--json", default=None, help="报告路径（默认 <out>/smoke_report.json）")
    parser.add_argument("--yes", action="store_true", help="跳过输入测试的风险确认")
    args = parser.parse_args(argv)

    win_api.ensure_utf8_stdout()
    out_dir = os.path.abspath(args.out)
    os.makedirs(out_dir, exist_ok=True)

    print("=" * 78)
    print("时空客户端设备层冒烟测试")
    print("=" * 78)

    if not win_api.IS_WINDOWS:
        print("本脚本需要在 Windows 上运行（当前平台 %s）。" % os.name)
        return 2

    backend = backend or win_device.WindowsBackend()
    report: Dict[str, Any] = {"time": time.strftime("%Y-%m-%d %H:%M:%S")}
    try:
        report["health"] = check_health(backend, out_dir)
        devices = check_devices(backend)
        if args.device:
            devices = [d for d in devices if d.device_id == args.device]
            if not devices:
                print(f"指定的设备不存在：{args.device}")
                return 1
        if not devices:
            print("\n没有找到时空客户端窗口，请确认客户端已启动且不是最小化。")
            record("存在可测设备", False)
        else:
            if args.input and not args.yes:
                print("\n注意：输入测试会真实点击游戏窗口。请先切到「点了也没关系」的界面。")
                try:
                    answer = input("  继续？(yes/no): ").strip().lower()
                except EOFError:
                    answer = "no"
                if answer != "yes":
                    args.input = False
                    print("  已跳过输入测试。")

            report["devices"] = []
            for device in devices:
                entry: Dict[str, Any] = {"device": device.to_dict()}
                entry["capture"] = check_capture(backend, device, out_dir)
                if args.resize:
                    entry["resize"] = check_resize(backend, device)
                if args.input:
                    entry["input"] = check_input(backend, device,
                                                 (args.click_x, args.click_y), out_dir, args.delay)
                if args.text:
                    entry["text"] = check_text(backend, device, args.text)
                report["devices"].append(entry)
    except Exception as exc:  # noqa: BLE001
        import traceback
        traceback.print_exc()
        record("整体流程无异常", False, repr(exc))

    report["results"] = [{"name": name, "ok": ok, "detail": detail} for name, ok, detail in RESULTS]
    report["passed"] = sum(1 for _, ok, _ in RESULTS if ok)
    report["failed"] = sum(1 for _, ok, _ in RESULTS if not ok)

    print("\n" + "=" * 78)
    print(f"结论：{report['passed']} 项通过 / {report['failed']} 项失败")
    print("=" * 78)
    for name, ok, detail in RESULTS:
        print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f" — {detail}" if detail else ""))
    if report["failed"]:
        print("\n失败项需要在 Windows 上进一步排查；请把本报告与 smoke_out 目录一起发回。")

    report_path = os.path.abspath(args.json or os.path.join(out_dir, "smoke_report.json"))
    os.makedirs(os.path.dirname(report_path), exist_ok=True)
    with open(report_path, "w", encoding="utf-8") as fh:
        json.dump(report, fh, ensure_ascii=False, indent=2)
    print(f"\n报告：{report_path}")
    return 0 if report["failed"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
