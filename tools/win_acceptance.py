#!/usr/bin/env python3
# coding=utf-8
"""时空（《梦幻西游：时空》Windows 客户端）控制层「一条命令验收」。

跑三步，最后写出一份**可以直接回传**的报告包：

    1. 探测：python tools/win_probe.py --no-input --no-occlusion   （只读）
    2. 推配置：由探测报告推出 config/win_backend.json              （默认只算不写）
    3. 冒烟：python tools/smoke_win.py                            （只读）

产出：

    <out>/acceptance_report.json   结构化结论（机器读）
    <out>/acceptance_report.md     人读版：环境 / 设备 / 各后端实测 / 推荐配置 /
                                   冒烟结果 / 结论与下一步

默认**不碰游戏**（探测与冒烟都不带点击/键盘测试）；只有加 `--with-input` 才会真的点一下。
加 `--write-config` 才会把推荐配置写进 config/win_backend.json。

用法：

    python tools\\win_acceptance.py
    python tools\\win_acceptance.py --write-config
    python tools\\win_acceptance.py --with-input        （会真的点游戏，需已登录到安全界面）
"""

from __future__ import annotations

import argparse
import contextlib
import io
import json
import os
import platform
import sys
import time
from typing import Any, Callable, Dict, List, Optional, Sequence, Tuple

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS_DIR = os.path.join(ROOT, "tools")
if TOOLS_DIR not in sys.path:
    sys.path.insert(0, TOOLS_DIR)

PROBE_REPORT_NAME = "win_probe_report.json"
SMOKE_REPORT_NAME = "smoke_report.json"
REPORT_JSON_NAME = "acceptance_report.json"
REPORT_MD_NAME = "acceptance_report.md"

DEFAULT_OUT = "acceptance_out"
DEFAULT_TIMEOUT_SECONDS = 900
OUTPUT_TAIL_CHARS = 6000


def _load_json(path: str) -> Optional[Dict[str, Any]]:
    if not os.path.isfile(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except Exception:  # noqa: BLE001
        return None
    return data if isinstance(data, dict) else None


def _tail(text: str, limit: int = OUTPUT_TAIL_CHARS) -> str:
    text = text or ""
    if len(text) <= limit:
        return text
    return "…（前面省略）\n" + text[-limit:]


def run_child_process(argv: Sequence[str], timeout: int) -> Tuple[int, str]:
    """跑一个子进程，把标准输出/错误按 **UTF-8** 一起收下来。

    子脚本（win_probe / smoke_win / win_recommend）启动时都会调
    ``ensure_utf8_stdout()`` 把 stdout/stderr 切成 UTF-8，所以父进程必须同样按
    UTF-8 解码。``text=True`` 不加 encoding 时走系统区域编码（中文 Windows 是 GBK），
    子进程一输出中文就抛 UnicodeDecodeError —— 而异常发生在 subprocess 的读取线程里，
    表现是控制台一串看不懂的 traceback，并且**那一整段输出会丢失**
    （报告"原始输出"里只剩 ASCII 的 stderr）。
    """
    import subprocess

    env = dict(os.environ)
    env["PYTHONIOENCODING"] = "utf-8"
    completed = subprocess.run(
        list(argv),
        cwd=ROOT,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        env=env,
        timeout=timeout,
    )
    return completed.returncode, (completed.stdout or "") + (completed.stderr or "")


def _run_child(script: str, arguments: Sequence[str], timeout: int) -> Dict[str, Any]:
    """跑一个子进程脚本，把标准输出/错误一起收下来（不接管终端）。"""
    started = time.time()
    try:
        exit_code, output = run_child_process(
            [sys.executable, os.path.join(TOOLS_DIR, script)] + list(arguments), timeout)
        return {"exitCode": exit_code, "output": output}
    except Exception as exc:  # noqa: BLE001
        return {"exitCode": -1, "output": "执行 %s 失败：%r" % (script, exc),
                "seconds": time.time() - started}


def run_probe(out_dir: str, with_input: bool = False,
              timeout: int = DEFAULT_TIMEOUT_SECONDS) -> Dict[str, Any]:
    """第 1 步：只读探测。返回 {exitCode, output, report, reportPath, seconds}。"""
    probe_dir = os.path.join(out_dir, "probe")
    arguments = ["--out", probe_dir]
    if with_input:
        arguments += ["--yes"]
    else:
        arguments += ["--no-input", "--no-occlusion"]
    result = _run_child("win_probe.py", arguments, timeout)
    report_path = os.path.join(probe_dir, PROBE_REPORT_NAME)
    return {
        "exitCode": result.get("exitCode", -1),
        "output": result.get("output", ""),
        "report": _load_json(report_path),
        "reportPath": report_path,
    }


def run_smoke(out_dir: str, with_input: bool = False,
              timeout: int = DEFAULT_TIMEOUT_SECONDS) -> Dict[str, Any]:
    """第 3 步：只读冒烟（--with-input 时才会真的点）。"""
    smoke_dir = os.path.join(out_dir, "smoke")
    arguments = ["--out", smoke_dir]
    if with_input:
        arguments += ["--input", "--yes"]
    result = _run_child("smoke_win.py", arguments, timeout)
    report_path = os.path.join(smoke_dir, SMOKE_REPORT_NAME)
    return {
        "exitCode": result.get("exitCode", -1),
        "output": result.get("output", ""),
        "report": _load_json(report_path),
        "reportPath": report_path,
    }


def build_recommendation(probe_report: Optional[Dict[str, Any]],
                         smoke_report: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    """第 2 步：用探测报告（+ 冒烟报告）推配置。不写文件。"""
    if not probe_report:
        return {"config": {}, "notes": [], "warnings": ["没有探测报告，无法推导配置。"],
                "measured": False}
    try:
        import win_recommend  # noqa: PLC0415
    except Exception as exc:  # noqa: BLE001
        return {"config": {}, "notes": [],
                "warnings": ["导入推荐工具失败：%r" % (exc,)], "measured": False}
    return win_recommend.recommend(probe_report, smoke_report)


def write_backend_config(probe_report_path: str, smoke_report_path: Optional[str],
                         force: bool = False) -> Dict[str, Any]:
    """真的写 config/win_backend.json（复用 win_recommend 的守卫）。"""
    import win_recommend  # noqa: PLC0415

    arguments = [probe_report_path]
    if smoke_report_path and os.path.isfile(smoke_report_path):
        arguments += ["--smoke", smoke_report_path]
    arguments += ["--write"]
    if force:
        arguments += ["--force"]
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
        code = win_recommend.main(arguments)
    return {"exitCode": code, "output": buffer.getvalue()}


def target_tag(target: Dict[str, Any]) -> str:
    """探测报告里的窗口标识（和 win_probe / win_recommend 保持一致）。"""
    try:
        import win_recommend  # noqa: PLC0415

        return str(win_recommend.target_tag(target))
    except Exception:  # noqa: BLE001
        return "pid%s_hwnd%08x" % (target.get("pid") or 0, int(target.get("hwnd") or 0))


def summarize_devices(probe_report: Optional[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """探测报告里的候选窗口（每个窗口一个设备）。"""
    if not probe_report:
        return []
    targets = probe_report.get("targets")
    if not isinstance(targets, list):
        return []
    devices: List[Dict[str, Any]] = []
    for target in targets:
        if not isinstance(target, dict):
            continue
        pid = target.get("pid")
        client = target.get("client_size")
        devices.append({
            "deviceId": "win:%s" % pid if pid else "",
            "tag": target_tag(target),
            "pid": pid,
            "hwnd": target.get("hwnd"),
            "title": target.get("title", ""),
            "className": target.get("class_name", ""),
            "clientSize": "x".join(str(value) for value in client)
                          if isinstance(client, (list, tuple)) and len(client) == 2 else None,
        })
    return devices


def summarize_methods(probe_report: Optional[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """每个窗口的**截图**后端实测结果（报告里是 capture[tag].methods）。"""
    rows: List[Dict[str, Any]] = []
    capture = (probe_report or {}).get("capture")
    if not isinstance(capture, dict):
        return rows
    for device in summarize_devices(probe_report):
        suite = capture.get(device["tag"])
        if not isinstance(suite, dict):
            continue
        for method in suite.get("methods") or []:
            if not isinstance(method, dict):
                continue
            metrics = method.get("metrics") or {}
            rows.append({
                "deviceId": device["deviceId"],
                "method": method.get("method", ""),
                "ok": bool(method.get("ok")),
                "blackRatio": metrics.get("black_ratio"),
                "distinctColors": metrics.get("distinct_colors_sampled"),
                "error": method.get("error"),
            })
    return rows


# 输入分节里除实测方法外的元数据键
_INPUT_META_KEYS = ("baseline_ratio", "recommendation", "best")


def summarize_input(probe_report: Optional[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """每个窗口的**输入**后端实测结果（报告里是 input[tag][方法名]）。"""
    rows: List[Dict[str, Any]] = []
    inputs = (probe_report or {}).get("input")
    if not isinstance(inputs, dict):
        return rows
    for device in summarize_devices(probe_report):
        data = inputs.get(device["tag"])
        if not isinstance(data, dict):
            continue
        for name, entry in data.items():
            if name in _INPUT_META_KEYS or not isinstance(entry, dict):
                continue
            diff = entry.get("diff") if isinstance(entry.get("diff"), dict) else {}
            rows.append({
                "deviceId": device["deviceId"],
                "method": name,
                "effective": entry.get("likely_effective"),
                "userConfirmed": entry.get("user_confirmed"),
                "changedRatio": diff.get("changed_ratio"),
                "changedVsBaseline": entry.get("diff_vs_baseline"),
                "error": entry.get("error"),
                "recommendation": data.get("recommendation"),
            })
    return rows


def summarize_keyboard(probe_report: Optional[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """文本注入实测（报告里是 keyboard[tag]）。"""
    rows: List[Dict[str, Any]] = []
    keyboard = (probe_report or {}).get("keyboard")
    if not isinstance(keyboard, dict):
        return rows
    for device in summarize_devices(probe_report):
        entry = keyboard.get(device["tag"])
        if not isinstance(entry, dict):
            continue
        row = {"deviceId": device["deviceId"]}
        row.update(entry)
        rows.append(row)
    return rows


def _enumeration_broken(probe_report: Optional[Dict[str, Any]]) -> bool:
    """探测报告是否表明"窗口枚举本身失效"（与"没找到游戏窗口"不同）。"""
    try:
        import win_recommend  # noqa: PLC0415

        return bool(win_recommend.enumeration_broken(probe_report or {}))
    except Exception:  # noqa: BLE001
        meta = (probe_report or {}).get("meta") or {}
        scan = meta.get("windowScan") or {}
        return bool(scan.get("enumerationBroken") or meta.get("enumerationBroken"))


def evaluate_verdict(probe_step: Dict[str, Any],
                     recommendation: Dict[str, Any],
                     smoke_step: Dict[str, Any],
                     with_input: bool = False) -> Dict[str, Any]:
    """把三步的结果翻译成"能不能用 + 下一步做什么"。"""
    problems: List[str] = []
    probe_report = probe_step.get("report")
    smoke_report = smoke_step.get("report")

    if probe_step.get("skipped"):
        problems.append("探测被跳过（--skip-probe）：没有实测数据，配置只能靠猜。")
    elif not probe_report:
        problems.append(
            "探测没有产出报告（退出码 %s）：%s"
            % (probe_step.get("exitCode"),
               "本工具只能在 Windows 上跑" if os.name != "nt" else "请看探测工具的完整输出")
        )
    else:
        devices = summarize_devices(probe_report)
        if not devices:
            if _enumeration_broken(probe_report):
                problems.append(
                    "窗口枚举返回 0 个窗口：枚举机制本身失效（枚举回调/ctypes 报错，"
                    "或进程不在交互式桌面会话），**不是客户端没启动**；"
                    "请看探测那一段的完整输出。"
                )
            else:
                problems.append("没有找到候选窗口：确认《梦幻西游：时空》客户端已启动且没最小化。")
        elif len(devices) > 1:
            # 多开不是问题，只是需要知道后端选择按第一个窗口定
            pass

    if probe_report:
        input_rows = summarize_input(probe_report)
        if input_rows:
            effective = [row for row in input_rows
                         if row.get("effective") or row.get("userConfirmed")]
            if not effective:
                problems.append(
                    "没有输入后端被判定为生效：检查窗口是否最小化/被遮挡，"
                    "或改用管理员权限重跑（会真的点一下游戏）。"
                )
        elif with_input:
            problems.append("输入测试没有产出结果：看探测工具里「输入」那一段的输出。")

    # 注意：recommend 的 measured 只表示"报告里有候选窗口"，不代表有截图实测数据，
    # 所以这里按实测结果自己判。
    capture_rows = summarize_methods(probe_report) if probe_report else []
    if probe_report and not capture_rows:
        problems.append("报告里没有截图实测结果：请用 tools\\win_probe.py"
                        "（不要加 --no-capture）重跑一次。")
    elif capture_rows and not any(row.get("ok") for row in capture_rows):
        problems.append("五种截图后端全部不可用（黑屏或颜色过少）：确认游戏画面正常显示、"
                        "窗口没最小化，并用管理员权限重跑探测。")

    if smoke_step.get("skipped"):
        problems.append("冒烟被跳过（--skip-smoke）：窗口控制层没有被真正跑过一遍。")
    elif not smoke_report:
        problems.append("冒烟没有产出报告（退出码 %s）。" % smoke_step.get("exitCode"))
    else:
        failed = [item for item in (smoke_report.get("results") or [])
                  if isinstance(item, dict) and not item.get("ok")]
        if failed:
            names = "、".join(str(item.get("name")) for item in failed[:6])
            problems.append("冒烟检查未通过：%s" % names)

    next_steps: List[str] = []
    if problems:
        next_steps.append("先按上面的问题逐条处理，再重跑 python tools\\win_acceptance.py。")
    else:
        next_steps.append("控制层本机验收通过；接着按 docs/WIN_SMOKE_TEST.md 走一遍流程/录制验收。")
    next_steps.append(
        "把 %s 与 %s 一起发回来（两份都在输出目录里）。" % (REPORT_MD_NAME, REPORT_JSON_NAME)
    )
    return {"ok": not problems, "problems": problems, "next": next_steps}


def build_report(*,
                 steps: List[Dict[str, Any]],
                 probe_step: Dict[str, Any],
                 recommendation: Dict[str, Any],
                 smoke_step: Dict[str, Any],
                 verdict: Dict[str, Any],
                 out_dir: str,
                 with_input: bool = False,
                 config_written: Optional[Dict[str, Any]] = None,
                 generated_at: Optional[str] = None) -> Dict[str, Any]:
    """组装报告（纯函数，测试直接喂假数据）。"""
    probe_report = probe_step.get("report")
    smoke_report = smoke_step.get("report")
    meta = (probe_report or {}).get("meta") or {}
    return {
        "generatedAt": generated_at or time.strftime("%Y-%m-%d %H:%M:%S"),
        "tool": "tools/win_acceptance.py",
        "outDir": os.path.abspath(out_dir),
        "withInput": with_input,
        "platform": {
            "system": platform.platform(),
            "python": sys.version.split()[0],
            "isWindows": os.name == "nt",
        },
        "steps": steps,
        "probe": {
            "exitCode": probe_step.get("exitCode"),
            "skipped": bool(probe_step.get("skipped")),
            "reportPath": probe_step.get("reportPath"),
            "meta": meta,
            "devices": summarize_devices(probe_report),
            "methods": summarize_methods(probe_report),
            "inputs": summarize_input(probe_report),
            "keyboard": summarize_keyboard(probe_report),
            "next": (probe_report or {}).get("next"),
        },
        "recommendation": {
            "config": recommendation.get("config") or {},
            "measured": bool(recommendation.get("measured")),
            "target": recommendation.get("target"),
            "notes": recommendation.get("notes") or [],
            "warnings": recommendation.get("warnings") or [],
            "written": config_written,
        },
        "smoke": {
            "exitCode": smoke_step.get("exitCode"),
            "skipped": bool(smoke_step.get("skipped")),
            "reportPath": smoke_step.get("reportPath"),
            "results": (smoke_report or {}).get("results") or [],
            "environment": (smoke_report or {}).get("environment"),
        },
        "verdict": verdict,
    }


def _markdown_table(headers: Sequence[str], rows: Sequence[Sequence[Any]]) -> List[str]:
    lines = ["| " + " | ".join(headers) + " |",
             "| " + " | ".join("---" for _ in headers) + " |"]
    for row in rows:
        cells = ["—" if value is None or value == "" else str(value) for value in row]
        lines.append("| " + " | ".join(cells) + " |")
    return lines


def render_markdown(report: Dict[str, Any]) -> str:
    """人读版报告（纯函数）。"""
    lines: List[str] = []
    lines.append("# 时空客户端控制层验收报告")
    lines.append("")
    lines.append("生成时间：%s" % report.get("generatedAt"))
    lines.append("")
    platform_info = report.get("platform") or {}
    lines.append("- 系统：%s" % platform_info.get("system"))
    lines.append("- Python：%s" % platform_info.get("python"))
    lines.append("- 是否 Windows：%s" % ("是" if platform_info.get("isWindows") else "否"))
    lines.append("- 是否包含输入测试（会真的点游戏）：%s"
                 % ("是" if report.get("withInput") else "否"))
    lines.append("")

    verdict = report.get("verdict") or {}
    lines.append("## 结论")
    lines.append("")
    lines.append("**%s**" % ("通过" if verdict.get("ok") else "未通过"))
    lines.append("")
    for problem in verdict.get("problems") or []:
        lines.append("- 问题：%s" % problem)
    for step in verdict.get("next") or []:
        lines.append("- 下一步：%s" % step)
    lines.append("")

    lines.append("## 三步结果")
    lines.append("")
    step_rows = []
    for step in report.get("steps") or []:
        step_rows.append([
            step.get("name"),
            "跳过" if step.get("skipped") else step.get("exitCode"),
            step.get("seconds"),
            step.get("summary", ""),
        ])
    lines.extend(_markdown_table(["步骤", "退出码", "耗时(秒)", "摘要"], step_rows))
    lines.append("")

    probe = report.get("probe") or {}
    meta = probe.get("meta") or {}
    lines.append("## 环境与依赖")
    lines.append("")
    for key in ("deps", "admin", "dpiAware", "screen", "python", "platform"):
        if key in meta:
            lines.append("- %s：%s" % (key, meta.get(key)))
    if not meta:
        lines.append("- 探测报告里没有环境信息（探测可能没跑成功）")
    lines.append("")

    lines.append("## 设备（窗口）")
    lines.append("")
    devices = probe.get("devices") or []
    if devices:
        lines.extend(_markdown_table(
            ["设备", "PID", "HWND", "标题", "客户区"],
            [[item.get("deviceId"), item.get("pid"), item.get("hwnd"),
              item.get("title"), item.get("clientSize")] for item in devices],
        ))
    else:
        lines.append("没有候选窗口。")
    lines.append("")

    lines.append("## 后端实测")
    lines.append("")
    methods = probe.get("methods") or []
    if methods:
        lines.extend(_markdown_table(
            ["设备", "后端", "可用", "黑屏比例", "采样颜色数", "错误"],
            [[item.get("deviceId"), item.get("method"),
              "是" if item.get("ok") else "否",
              item.get("blackRatio"), item.get("distinctColors"),
              item.get("error")] for item in methods],
        ))
    else:
        lines.append("没有后端实测数据。")
    lines.append("")

    lines.append("## 输入后端实测")
    lines.append("")
    inputs = probe.get("inputs") or []
    if inputs:
        lines.extend(_markdown_table(
            ["设备", "后端", "自动判定", "人工确认", "变化比例", "错误"],
            [[item.get("deviceId"), item.get("method"),
              "生效" if item.get("effective") else "未生效",
              item.get("userConfirmed"), item.get("changedRatio"),
              item.get("error")] for item in inputs],
        ))
        recommendation = inputs[0].get("recommendation")
        if recommendation:
            lines.append("")
            lines.append("- 探测工具建议的输入后端：%s" % recommendation)
    else:
        lines.append("没有输入实测数据（默认不点游戏；要测请加 `--with-input`）。")
    lines.append("")

    keyboard = probe.get("keyboard") or []
    if keyboard:
        lines.append("## 文本注入实测")
        lines.append("")
        for entry in keyboard:
            lines.append("- %s：%s" % (entry.get("deviceId"), json.dumps(
                {key: value for key, value in entry.items() if key != "deviceId"},
                ensure_ascii=False)))
        lines.append("")

    lines.append("## 推荐配置")
    lines.append("")
    recommendation = report.get("recommendation") or {}
    if recommendation.get("measured"):
        lines.append("- 实测目标：%s" % recommendation.get("target"))
    else:
        lines.append("- 没有实测数据，下面的配置不可信。")
    lines.append("")
    lines.append("```json")
    lines.append(json.dumps(recommendation.get("config") or {}, ensure_ascii=False, indent=2))
    lines.append("```")
    lines.append("")
    for note in recommendation.get("notes") or []:
        lines.append("- %s" % note)
    for warning in recommendation.get("warnings") or []:
        lines.append("- 注意：%s" % warning)
    written = recommendation.get("written")
    if written:
        lines.append("- 写配置退出码：%s" % written.get("exitCode"))
    lines.append("")

    lines.append("## 冒烟结果")
    lines.append("")
    smoke = report.get("smoke") or {}
    results = smoke.get("results") or []
    if results:
        lines.extend(_markdown_table(
            ["检查项", "结果", "说明"],
            [[item.get("name"), "通过" if item.get("ok") else "未通过",
              item.get("detail")] for item in results],
        ))
    else:
        lines.append("没有冒烟结果。")
    lines.append("")

    lines.append("## 原始输出（每步最后一段）")
    lines.append("")
    for step in report.get("steps") or []:
        lines.append("### %s" % step.get("name"))
        lines.append("")
        lines.append("```text")
        lines.append(_tail(step.get("output") or "", 2000))
        lines.append("```")
        lines.append("")
    return "\n".join(lines)


def run_acceptance(out_dir: str, *,
                   with_input: bool = False,
                   write_config: bool = False,
                   force: bool = False,
                   skip_probe: bool = False,
                   skip_smoke: bool = False,
                   timeout: int = DEFAULT_TIMEOUT_SECONDS,
                   probe_runner: Callable[..., Dict[str, Any]] = run_probe,
                   smoke_runner: Callable[..., Dict[str, Any]] = run_smoke,
                   config_writer: Callable[..., Dict[str, Any]] = write_backend_config,
                   log: Callable[[str], None] = print) -> Tuple[Dict[str, Any], int]:
    """跑完整流程，返回 (报告, 退出码)。退出码 0=通过，1=有问题，2=参数/环境问题。"""
    os.makedirs(out_dir, exist_ok=True)
    steps: List[Dict[str, Any]] = []

    def step(name: str, skipped: bool, exit_code: Any, seconds: Any, summary: str,
             output: str = "") -> Dict[str, Any]:
        return {
            "name": name,
            "skipped": skipped,
            "exitCode": exit_code,
            "seconds": round(float(seconds or 0), 1),
            "summary": summary,
            "output": output,
        }

    log("=" * 78)
    log("时空客户端控制层验收（探测 → 推配置 → 冒烟）")
    log("=" * 78)

    if skip_probe:
        log("[1/3] 探测：跳过（--skip-probe）")
        probe_step: Dict[str, Any] = {"skipped": True, "exitCode": None,
                                     "report": None, "reportPath": None, "output": ""}
        steps.append(step("probe", True, None, 0, "跳过"))
    else:
        log("[1/3] 探测（只读%s）…" % ("，含输入测试" if with_input else "，不点游戏"))
        started = time.time()
        probe_step = dict(probe_runner(out_dir, with_input=with_input, timeout=timeout))
        seconds = time.time() - started
        found = len(summarize_devices(probe_step.get("report")))
        summary = "候选窗口 %d 个" % found if probe_step.get("report") else "没有产出报告"
        steps.append(step("probe", False, probe_step.get("exitCode"), seconds, summary,
                          probe_step.get("output", "")))
        log("      退出码 %s，%s" % (probe_step.get("exitCode"), summary))

    log("[2/3] 推配置…")
    recommendation = build_recommendation(probe_step.get("report"),
                                          None)  # 冒烟还没跑，先只用探测报告
    steps.append(step("recommend", False, 0, 0,
                      "实测 %s" % ("可用" if recommendation.get("measured") else "不可用")))

    smoke_step: Dict[str, Any] = {"skipped": True, "exitCode": None, "report": None,
                                  "reportPath": None, "output": ""}
    if skip_smoke:
        log("[3/3] 冒烟：跳过（--skip-smoke）")
        steps.append(step("smoke", True, None, 0, "跳过"))
    else:
        log("[3/3] 冒烟（只读%s）…" % ("，含输入测试" if with_input else "，不点游戏"))
        started = time.time()
        smoke_step = dict(smoke_runner(out_dir, with_input=with_input, timeout=timeout))
        seconds = time.time() - started
        results = (smoke_step.get("report") or {}).get("results") or []
        passed = len([item for item in results
                      if isinstance(item, dict) and item.get("ok")])
        summary = "%d/%d 项通过" % (passed, len(results)) if results else "没有产出报告"
        steps.append(step("smoke", False, smoke_step.get("exitCode"), seconds, summary,
                          smoke_step.get("output", "")))
        log("      退出码 %s，%s" % (smoke_step.get("exitCode"), summary))
        # 拿到冒烟结果后重新推一次（冒烟能提供更可靠的后端优先级）
        if smoke_step.get("report") and probe_step.get("report"):
            recommendation = build_recommendation(probe_step.get("report"),
                                                  smoke_step.get("report"))

    config_written = None
    if write_config:
        if not recommendation.get("config", {}).get("captureOrder"):
            log("      没有可用的截图实测结果，不写配置。")
            config_written = {"exitCode": 1, "output": "没有可用的截图实测结果，拒绝写入。"}
        else:
            log("      写入 config/win_backend.json …")
            config_written = config_writer(
                probe_step.get("reportPath") or "", smoke_step.get("reportPath"),
                force=force,
            )
            log("      退出码 %s" % config_written.get("exitCode"))

    verdict = evaluate_verdict(probe_step, recommendation, smoke_step,
                               with_input=with_input)
    report = build_report(
        steps=steps,
        probe_step=probe_step,
        recommendation=recommendation,
        smoke_step=smoke_step,
        verdict=verdict,
        out_dir=out_dir,
        with_input=with_input,
        config_written=config_written,
    )

    json_path = os.path.join(out_dir, REPORT_JSON_NAME)
    md_path = os.path.join(out_dir, REPORT_MD_NAME)
    with open(json_path, "w", encoding="utf-8") as handle:
        json.dump(report, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    with open(md_path, "w", encoding="utf-8") as handle:
        handle.write(render_markdown(report))
        handle.write("\n")

    log("")
    log("=" * 78)
    log("结论：%s" % ("通过" if verdict.get("ok") else "未通过"))
    for problem in verdict.get("problems"):
        log("  ! %s" % problem)
    for item in verdict.get("next"):
        log("  → %s" % item)
    log("")
    log("报告：%s" % md_path)
    log("      %s" % json_path)
    log("=" * 78)
    return report, (0 if verdict.get("ok") else 1)


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="时空客户端控制层一条命令验收（探测 → 推配置 → 冒烟）",
    )
    parser.add_argument("--out", default=DEFAULT_OUT,
                        help="输出目录（默认 %s）" % DEFAULT_OUT)
    parser.add_argument("--with-input", action="store_true",
                        help="包含点击/键盘测试（会真的操作游戏，需已登录到安全界面）")
    parser.add_argument("--write-config", action="store_true",
                        help="把推荐配置写进 config/win_backend.json")
    parser.add_argument("--force", action="store_true",
                        help="配合 --write-config：覆盖已存在的配置")
    parser.add_argument("--skip-probe", action="store_true", help="跳过探测（复用上次报告）")
    parser.add_argument("--skip-smoke", action="store_true", help="跳过冒烟")
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT_SECONDS,
                        help="单步超时秒数（默认 %d）" % DEFAULT_TIMEOUT_SECONDS)
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[attr-defined]
    except Exception:
        pass
    args = build_arg_parser().parse_args(argv)

    if os.name != "nt":
        print("本工具只能在 Windows 上运行（当前平台：%s）。" % platform.platform())
        print("请在装有《梦幻西游：时空》客户端的 Windows 机器上执行："
              "python tools\\win_acceptance.py")
        return 2

    _report, code = run_acceptance(
        os.path.abspath(args.out),
        with_input=args.with_input,
        write_config=args.write_config,
        force=args.force,
        skip_probe=args.skip_probe,
        skip_smoke=args.skip_smoke,
        timeout=args.timeout,
    )
    return code


if __name__ == "__main__":
    raise SystemExit(main())
