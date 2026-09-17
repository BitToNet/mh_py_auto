#!/usr/bin/env python3
# coding=utf-8
"""把实机探测报告变成 `config/win_backend.json`。

《梦幻西游：时空》客户端上"哪种截图/点击方式真的能用"只能靠实机测出来
（见 `tools/win_probe.py`）。这个脚本读那份报告，按**和运行时完全相同**的
可用性标准挑后端，直接生成可以落地的配置，省掉"人工解读报告"这一步。

用法：
    python tools\\win_probe.py --no-input --no-occlusion
    python tools\\win_recommend.py                       :: 只打印建议（不写文件）
    python tools\\win_recommend.py --write               :: 写入 config/win_backend.json

默认读 `probe_out/win_probe_report.json`，`--smoke` 可选读冒烟报告一起参考。
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any, Dict, List, Optional, Sequence, Tuple

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WIN_DIR = os.path.join(ROOT_DIR, "scripts", "win")
if WIN_DIR not in sys.path:
    sys.path.insert(0, WIN_DIR)

import win_api  # noqa: E402
import win_capture  # noqa: E402
import win_device  # noqa: E402
import win_input  # noqa: E402

DEFAULT_REPORT = os.path.join("probe_out", "win_probe_report.json")
DEFAULT_OUT = os.path.join("config", "win_backend.json")

# 后端名字 -> 一句话解释（写进 notes，方便回看为什么这么选）
METHOD_NOTES = {
    "printwindow_renderfull": "PrintWindow + PW_RENDERFULLCONTENT：窗口被遮挡也能取到画面",
    "printwindow_client": "PrintWindow(CLIENTONLY)：部分引擎可用，遮挡时可能取到黑屏",
    "bitblt_client": "BitBlt 客户区：最快，但被遮挡时通常只能拿到黑屏",
    "printwindow_window": "PrintWindow 整窗（含边框）：客户区截图不可用时的退路",
    "bitblt_window": "BitBlt 整窗：最后的退路，通常需要窗口在前台",
}

# 文字注入方式 -> 探测报告里对应的对比字段（clipboard 只报"能不能用"）
TEXT_DIFF_KEYS = (
    ("wm_char", "wm_char_diff"),
    ("unicode", "unicode_diff"),
)


def target_tag(target: Dict[str, Any]) -> str:
    return "pid%s_hwnd%08X" % (target.get("pid", 0), int(target.get("hwnd", 0)))


def _first_target(report: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    targets = report.get("targets") or []
    if isinstance(targets, list) and targets:
        first = targets[0]
        if isinstance(first, dict):
            return first
    return None


def _methods_of(report: Dict[str, Any], tag: str) -> List[Dict[str, Any]]:
    section = (report.get("capture") or {}).get(tag) or {}
    methods = section.get("methods") or []
    return [item for item in methods if isinstance(item, dict)]


def split_methods(methods: Sequence[Dict[str, Any]],
                  black_ratio_max: float, min_colors: int) -> Tuple[List[str], List[str], List[str]]:
    """按和运行时相同的标准把实测后端分成"可用"、"不可用"和"不认识的"三组。

    "不认识的"是防线：报告可能来自旧版本或别的分支，名字对不上就绝不能写进配置
    —— 否则运行时会以 "未知截图后端" 直接报错。
    """
    working: List[str] = []
    rejected: List[str] = []
    unknown: List[str] = []
    for item in methods:
        name = str(item.get("method") or "")
        if not name:
            continue
        if name not in win_capture.METHODS:
            unknown.append(name)
            continue
        if item.get("ok") and win_capture.usable_metrics(item.get("metrics"),
                                                        black_ratio_max, min_colors):
            working.append(name)
        else:
            rejected.append(name)
    return working, rejected, unknown


def _order_with(working: Sequence[str], preference: Sequence[str]) -> List[str]:
    preferred = [name for name in preference if name in working]
    rest = [name for name in working if name not in preferred]
    return preferred + rest


def _smoke_notes(smoke: Optional[Dict[str, Any]]) -> Tuple[Optional[str], List[str]]:
    """从冒烟报告里取"设备层真正选中的后端"和它的失败信息。"""
    if not isinstance(smoke, dict):
        return None, []
    notes: List[str] = []
    # 先收失败项：设备检查挂了的时候 devices 往往是空的，
    # 那正是最需要把人引到冒烟报告里看细节的时候。
    problems = [item.get("name") for item in (smoke.get("results") or [])
                if isinstance(item, dict) and not item.get("ok")]
    if problems:
        notes.append("冒烟报告里有未通过的检查项：%s（细节见 smoke_report.json）"
                     % "、".join(str(p) for p in problems))
    devices = smoke.get("devices") or []
    if not isinstance(devices, list) or not devices:
        return None, notes
    entry = devices[0] if isinstance(devices[0], dict) else {}
    chosen = ((entry.get("capture") or {}).get("chosen")) or None
    return (str(chosen) if chosen else None), notes


def recommend(report: Dict[str, Any],
              smoke: Optional[Dict[str, Any]] = None,
              black_ratio_max: float = win_capture.DEFAULT_BLACK_RATIO_MAX,
              min_colors: int = win_capture.DEFAULT_MIN_COLORS,
              ) -> Dict[str, Any]:
    """由探测报告推导配置。返回 {config, notes, warnings, measured}。"""
    notes: List[str] = []
    warnings: List[str] = []
    config: Dict[str, Any] = {
        "designWidth": 1600,
        "designHeight": 900,
    }

    target = _first_target(report)
    if target is None:
        warnings.append("报告里没有候选窗口：请先在 Windows 上跑 tools\\win_probe.py，"
                        "确认客户端已启动且不是最小化。")
        return {"config": config, "notes": notes, "warnings": warnings, "measured": False}

    tag = target_tag(target)
    others = [item for item in (report.get("targets") or [])
              if isinstance(item, dict) and target_tag(item) != tag]
    if others:
        # 多开时报告里会有多个候选：这里只按第一个（探测工具选的第一个候选）出配置
        notes.append("报告里有 %d 个候选窗口，这里只按第一个出配置；"
                     "多开时每个窗口是独立设备，后端选择对同一种窗口通常一致。"
                     % (len(others) + 1))
    methods = _methods_of(report, tag)
    working, rejected, unknown = split_methods(methods, black_ratio_max, min_colors)
    if unknown:
        warnings.append("报告里有运行时不认识的后端名：%s（报告可能来自旧版本，已忽略）"
                        % "、".join(unknown))
    smoke_chosen, smoke_notes = _smoke_notes(smoke)
    notes.extend(smoke_notes)

    if not methods:
        warnings.append("报告里没有截图实测结果：请用 tools\\win_probe.py "
                        "（不要加 --no-capture）重跑一次。")
    elif not working:
        warnings.append("五种截图后端全部不可用（全是黑屏或颜色过少）："
                        "先确认游戏画面正常显示、窗口未最小化，再用管理员权限重跑探测。")
    else:
        order = _order_with(working, win_capture.DEFAULT_ORDER)
        if smoke_chosen and smoke_chosen in working:
            order = [smoke_chosen] + [name for name in order if name != smoke_chosen]
            notes.append("截图后端按冒烟结果把 %s 放第一位。" % smoke_chosen)
        config["captureOrder"] = order
        # 子窗口渲染目标没有窗口边框：窗口级后端放在这里没有意义，只保留 CHILD_ORDER 里的
        child_working = [name for name in working if name in win_capture.CHILD_ORDER]
        config["captureOrderChild"] = _order_with(child_working, win_capture.CHILD_ORDER) or \
            list(win_capture.CHILD_ORDER)
        notes.append("可用截图后端（按优先级）：%s" % " > ".join(order))
        for name in working:
            if name in METHOD_NOTES:
                notes.append("%s ← %s" % (name, METHOD_NOTES[name]))
        for name in rejected:
            notes.append("%s 实测不可用（黑屏率过高或颜色过少），已排到后面" % name)
        if order[0] != win_capture.DEFAULT_ORDER[0]:
            notes.append("首选后端不是 printwindow_renderfull："
                         "被别的窗口盖住时可能截到黑屏，运行时请让客户端保持可见。")
        if order[0].startswith("bitblt"):
            warnings.append("只能靠 BitBlt 截图：这种方式被遮挡时通常失效，"
                            "多开或叠窗口时可能截到黑屏。")
    config["blackRatioMax"] = float(black_ratio_max)
    config["minColors"] = int(min_colors)

    # -- 输入 --
    input_section = (report.get("input") or {}).get(tag) or {}
    chosen_input = str(input_section.get("recommendation") or "").strip()
    if not chosen_input:
        for name in win_input.DEFAULT_METHOD_ORDER:
            entry = input_section.get(name)
            if isinstance(entry, dict) and entry.get("likely_effective"):
                chosen_input = name
                break
    effective = [name for name in win_input.DEFAULT_METHOD_ORDER
                 if isinstance(input_section.get(name), dict)
                 and input_section[name].get("likely_effective")]
    if chosen_input:
        config["inputMethod"] = chosen_input
        notes.append("点击方式用 %s（实测画面有变化）。" % chosen_input)
        if len(effective) > 1:
            notes.append("可用的点击方式还有：%s，如遇丢事件可在配置里换。"
                         % "、".join(name for name in effective if name != chosen_input))
    elif input_section:
        warnings.append("三种点击方式都没检测到画面变化：可能这个界面本来就不响应点击，"
                        "也可能需要把 inputTarget 改成 \"capture\"（见下）后重测。")
    else:
        notes.append("报告里没有输入实测结果（--no-input 或未确认）："
                     "点击方式仍是 auto，等实机确认后再定。")

    children = target.get("children") or report.get("children", {}).get(tag) or []
    big_child = None
    client_w = int(target.get("client_size", [0, 0])[0] or 0)
    client_h = int(target.get("client_size", [0, 0])[1] or 0)
    if client_w > 0 and client_h > 0 and isinstance(children, list):
        for child in children:
            if not isinstance(child, dict):
                continue
            size = child.get("client_size") or [0, 0]
            ratio = (int(size[0]) * int(size[1])) / float(client_w * client_h)
            if ratio >= 0.6:
                big_child = (child, ratio)
                break
    if big_child is not None:
        child, ratio = big_child
        notes.append("发现占客户区 %.0f%% 的渲染子窗口 %s（hwnd=0x%08X），"
                     "截图目标是它还是顶层窗口要看实测结果。"
                     % (ratio * 100, child.get("class_name") or "?", int(child.get("hwnd", 0))))
    if input_section and not chosen_input and big_child is not None:
        config["inputTarget"] = "capture"
        notes.append("因为点击实测都没生效、且存在满屏渲染子窗口，"
                     "建议把 inputTarget 设为 \"capture\"（消息直接发给渲染子窗口）后重跑一次探测确认。")
    else:
        config.setdefault("inputTarget", "top")

    # -- 尺寸 --
    resize_section = (report.get("resize") or {}).get(tag) or {}
    if resize_section:
        matched = bool(resize_section.get("matched"))
        config["autoResize"] = matched
        if matched:
            notes.append("客户区可以固定成 1600×900（实测 matched=true），"
                         "流程坐标不需要缩放。")
        else:
            after = resize_section.get("after_client")
            warnings.append("无法把客户区固定成 1600×900（实测 %s）："
                            "运行时按比例缩放坐标，流程仍然可用，"
                            "但极小/极大的窗口可能有偏差。" % (after or "未知"))
    else:
        notes.append("没有做尺寸实测：加 --resize 1600x900 重跑可以判断能否固定分辨率。")

    # -- 文字 --
    keyboard = (report.get("keyboard") or {}).get(tag) or {}
    if keyboard:
        scored = []
        for name, key in TEXT_DIFF_KEYS:
            diff = keyboard.get(key)
            if isinstance(diff, dict):
                scored.append((name, float(diff.get("changed_ratio", 0.0) or 0.0)))
        usable = [name for name, ratio in scored if ratio > 0]
        if usable:
            config["textMethod"] = usable[0]
            notes.append("文字输入用 %s（实测画面有变化）。" % usable[0])
        else:
            config["textMethod"] = "unicode"
            warnings.append("文字注入没有检测到画面变化：请手动点开输入框后重跑 --text 测试；"
                            "默认仍用 unicode。")
        if not keyboard.get("clipboard_fallback_available", True):
            warnings.append("剪贴板方式不可用（可能是权限或占用），不要选 clipboard。")
    else:
        notes.append("没有做文字实测：加 --text 测试内容 重跑可以确定 textMethod。")

    return {"config": config, "notes": notes, "warnings": warnings, "measured": True,
            "target": tag}


def _load_json(path: str) -> Dict[str, Any]:
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError("报告内容不是 JSON 对象：%s" % path)
    return data


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="由实机探测报告生成 config/win_backend.json",
    )
    parser.add_argument("report", nargs="?", default=DEFAULT_REPORT,
                        help="探测报告路径（默认 %s）" % DEFAULT_REPORT)
    parser.add_argument("--smoke", default=None,
                        help="可选：冒烟报告路径（smoke_out/smoke_report.json）")
    parser.add_argument("--out", default=DEFAULT_OUT,
                        help="配置输出路径（默认 %s）" % DEFAULT_OUT)
    parser.add_argument("--write", action="store_true", help="真的写文件（默认只打印）")
    parser.add_argument("--force", action="store_true", help="覆盖已存在的配置")
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_arg_parser().parse_args(argv)
    win_api.ensure_utf8_stdout()

    report_path = os.path.abspath(args.report)
    if not os.path.isfile(report_path):
        print("找不到探测报告：%s" % report_path, file=sys.stderr)
        print("请先在 Windows 上运行：python tools\\win_probe.py --no-input --no-occlusion",
              file=sys.stderr)
        return 2
    try:
        report = _load_json(report_path)
    except Exception as exc:  # noqa: BLE001
        print("读取探测报告失败：%r" % (exc,), file=sys.stderr)
        return 2

    smoke = None
    if args.smoke:
        smoke_path = os.path.abspath(args.smoke)
        if os.path.isfile(smoke_path):
            try:
                smoke = _load_json(smoke_path)
            except Exception as exc:  # noqa: BLE001
                print("读取冒烟报告失败（忽略）：%r" % (exc,), file=sys.stderr)
        else:
            print("提示：找不到冒烟报告 %s，只按探测报告推导。" % smoke_path)

    result = recommend(report, smoke)
    config = result["config"]
    print("=" * 78)
    print("时空客户端后端建议")
    print("=" * 78)
    print("报告：%s" % report_path)
    if result.get("measured"):
        print("目标：%s" % result.get("target"))
    print()
    for line in result["notes"]:
        print("  · %s" % line)
    if result["warnings"]:
        print()
        print("注意：")
        for line in result["warnings"]:
            print("  ! %s" % line)
    print()
    print("-" * 78)
    print("建议写入 %s 的内容：" % os.path.abspath(args.out))
    print("-" * 78)
    print(json.dumps(config, ensure_ascii=False, indent=2))

    if not args.write:
        print()
        print("（当前只是打印；确认无误后加 --write 写入文件）")
        return 0 if result.get("measured") else 1

    if not config.get("captureOrder"):
        print()
        print("报告里没有可用的截图实测结果，拒绝写入配置。", file=sys.stderr)
        return 1

    out_path = os.path.abspath(args.out)
    if os.path.isfile(out_path) and not args.force:
        print()
        print("配置已存在，未覆盖：%s（确认要替换请加 --force）" % out_path, file=sys.stderr)
        return 1

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as handle:
        json.dump(config, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    # 自检：写出来的配置必须能被设备层读进去，且顺序真的生效
    effective = win_device.load_config(out_path)
    print()
    print("已写入：%s" % out_path)
    print("设备层读到的截图顺序：%s" % " > ".join(effective.get("captureOrder", [])))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
