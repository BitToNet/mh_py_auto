#!/usr/bin/env python3
# coding=utf-8
"""时空客户端常驻控制服务（给 Flutter 用的 JSON-Lines 服务）。

协议
----
stdin 每行一个 JSON 请求，stdout 每行一个 JSON 响应：

    请求：{"id": 1, "cmd": "list_devices", "args": {"includeOther": false}}
    响应：{"id": 1, "ok": true, "data": {...}, "error": null}

约定：
* **只有响应写 stdout**，日志一律写 stderr，避免污染协议流。
* 任何异常都不会让服务退出，只会返回 ok=false。
* 设备类操作自身的 ``data.ok=false`` 会被提升为 ``ok=false``，
  具体原因放在 ``error``（细节保留在 ``data`` 里）。
* 截图默认写文件（Flutter 直接读文件），需要时可用 ``encode="png_base64"``。

启动：
    python tools/win_helper.py            # 交互式 JSON-Lines
    python tools/win_helper.py --health   # 跑一次自检后退出
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import tempfile
import time
import traceback
from typing import Any, Callable, Dict, List, Optional

TOOLS_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.path.dirname(TOOLS_DIR)
WIN_DIR = os.path.join(ROOT_DIR, "scripts", "win")
if WIN_DIR not in sys.path:
    sys.path.insert(0, WIN_DIR)

import win_api
import win_record  # noqa: E402
import win_capture  # noqa: E402
import win_device  # noqa: E402

PROTOCOL_VERSION = 1
DEFAULT_SHOT_DIR = os.path.join(tempfile.gettempdir(), "shikong_win_shots")


def log(message: str) -> None:
    sys.stderr.write(f"[win_helper] {message}\n")
    sys.stderr.flush()


# 录制器工厂（测试可替换成假实现）
RECORDER_FACTORY = win_record.MouseHookRecorder


class Helper:
    def __init__(self) -> None:
        self.backend = win_device.backend()
        win_device.set_backend(self.backend)
        self.shot_dir = DEFAULT_SHOT_DIR
        os.makedirs(self.shot_dir, exist_ok=True)
        self.shot_seq = 0
        self.started_at = time.time()
        self.recorder: Optional[win_record.MouseHookRecorder] = None
        self.recordings: Dict[str, Any] = {}

    # -- 工具 --
    def _shot_path(self, device_id: str, fmt: str = "png") -> str:
        self.shot_seq += 1
        safe = str(device_id or "device").replace(":", "_").replace("\\", "_")
        return os.path.join(self.shot_dir, f"{safe}_{int(time.time()*1000)}_{self.shot_seq}.{fmt}")

    # -- 命令实现 --
    def cmd_ping(self, args: Dict[str, Any]) -> Dict[str, Any]:
        return {
            "protocol": PROTOCOL_VERSION,
            "pid": os.getpid(),
            "isWindows": win_api.IS_WINDOWS,
            "python": sys.version.split()[0],
            "uptimeSeconds": round(time.time() - self.started_at, 1),
            "shotDir": self.shot_dir,
        }

    def cmd_health(self, args: Dict[str, Any]) -> Dict[str, Any]:
        return self.backend.health()

    def cmd_list_devices(self, args: Dict[str, Any]) -> Dict[str, Any]:
        devices = self.backend.list_devices(include_other=bool(args.get("includeOther", False)))
        return {"count": len(devices), "devices": devices}

    def cmd_refresh(self, args: Dict[str, Any]) -> Dict[str, Any]:
        devices = self.backend.refresh(include_other=bool(args.get("includeOther", False)))
        return {"count": len(devices), "devices": [d.to_dict() for d in devices]}

    def cmd_capture(self, args: Dict[str, Any]) -> Dict[str, Any]:
        device_id = args.get("deviceId")
        normalize = bool(args.get("normalize", True))
        method = args.get("method")
        image = self.backend.screenshot(device_id, method=method, normalize=normalize)
        if image is None:
            raise RuntimeError("截图失败（可能窗口已关闭或全部后端不可用）")
        height, width = int(image.shape[0]), int(image.shape[1])
        info = self.backend.capture_info(device_id)
        payload: Dict[str, Any] = {
            "width": width, "height": height,
            "method": info.get("method"), "metrics": info.get("metrics"),
        }
        if args.get("encode") == "png_base64":
            import cv2
            ok, buf = cv2.imencode(".png", image)
            if not ok:
                raise RuntimeError("PNG 编码失败")
            payload["pngBase64"] = base64.b64encode(buf.tobytes()).decode("ascii")
        save_path = args.get("savePath") or self._shot_path(str(device_id), "png")
        os.makedirs(os.path.dirname(os.path.abspath(save_path)), exist_ok=True)
        if not win_api.save_bgr_image(save_path, image):
            raise RuntimeError(f"截图保存失败：{save_path}")
        payload["path"] = save_path
        return payload

    def cmd_click(self, args: Dict[str, Any]) -> Dict[str, Any]:
        return self.backend.tap(
            args.get("deviceId"), int(args.get("x", 0)), int(args.get("y", 0)),
            design_coords=bool(args.get("designCoords", True)),
            random_radius=args.get("randomRadius"),
            method=args.get("method"),
            button=args.get("button", "left"),
        )

    def cmd_double_click(self, args: Dict[str, Any]) -> Dict[str, Any]:
        return self.backend.double_tap(args.get("deviceId"), int(args.get("x", 0)),
                                       int(args.get("y", 0)), method=args.get("method"))

    def cmd_swipe(self, args: Dict[str, Any]) -> Dict[str, Any]:
        return self.backend.swipe(
            args.get("deviceId"), int(args.get("x1", 0)), int(args.get("y1", 0)),
            int(args.get("x2", 0)), int(args.get("y2", 0)),
            duration_ms=float(args.get("durationMs", 300)), method=args.get("method"),
        )

    def cmd_drag(self, args: Dict[str, Any]) -> Dict[str, Any]:
        return self.backend.drag(
            args.get("deviceId"), int(args.get("x1", 0)), int(args.get("y1", 0)),
            int(args.get("x2", 0)), int(args.get("y2", 0)),
            duration_ms=float(args.get("durationMs", 400)), method=args.get("method"),
        )

    def cmd_scroll(self, args: Dict[str, Any]) -> Dict[str, Any]:
        return self.backend.scroll(args.get("deviceId"), int(args.get("x", 0)),
                                   int(args.get("y", 0)), int(args.get("delta", -120)),
                                   method=args.get("method"))

    def cmd_text(self, args: Dict[str, Any]) -> Dict[str, Any]:
        return self.backend.input_text(args.get("deviceId"), str(args.get("text", "")),
                                       method=args.get("method"))

    def cmd_key(self, args: Dict[str, Any]) -> Dict[str, Any]:
        return self.backend.press_key(args.get("deviceId"), int(args.get("vk", 0x1B)),
                                      method=args.get("method"))

    def cmd_activate(self, args: Dict[str, Any]) -> Dict[str, Any]:
        return self.backend.activate(args.get("deviceId"))

    def cmd_resize(self, args: Dict[str, Any]) -> Dict[str, Any]:
        width = args.get("width")
        height = args.get("height")
        target = (int(width), int(height)) if width and height else None
        return self.backend.ensure_design_size(args.get("deviceId"), target=target,
                                               force=bool(args.get("force", True)))

    def cmd_ensure_running(self, args: Dict[str, Any]) -> Dict[str, Any]:
        return self.backend.ensure_running(args.get("deviceId"),
                                          timeout=float(args.get("timeout", 120)))

    def cmd_start(self, args: Dict[str, Any]) -> Dict[str, Any]:
        return self.backend.start(wait=bool(args.get("wait", True)),
                                  timeout=float(args.get("timeout", 120)))

    def cmd_stop(self, args: Dict[str, Any]) -> Dict[str, Any]:
        return self.backend.stop(args.get("deviceId"),
                                 include_launcher=bool(args.get("includeLauncher", False)))

    def cmd_restart(self, args: Dict[str, Any]) -> Dict[str, Any]:
        return self.backend.restart(args.get("deviceId"), timeout=float(args.get("timeout", 120)))

    def cmd_probe_capture(self, args: Dict[str, Any]) -> Dict[str, Any]:
        device = self.backend.resolve(args.get("deviceId"))
        if device is None:
            raise RuntimeError("设备不存在")
        order = args.get("order")
        report = win_capture.probe_methods(device.capture_hwnd,
                                           order=order or win_capture.DEFAULT_ORDER,
                                           api=self.backend.api)
        return {"device": device.to_dict(), "methods": report}

    def cmd_stats(self, args: Dict[str, Any]) -> Dict[str, Any]:
        return self.backend.stats()

    def cmd_config(self, args: Dict[str, Any]) -> Dict[str, Any]:
        if args.get("set"):
            self.backend.set_config(**args["set"])
        return self.backend.config

    # -- 手势录制（P5） --
    def cmd_record_start(self, args: Dict[str, Any]) -> Dict[str, Any]:
        if self.recorder is not None:
            raise RuntimeError("已有录制在进行中，请先停止录制")
        device = self.backend.resolve(args.get("deviceId"))
        if device is None:
            raise RuntimeError("设备不存在")
        recorder = RECORDER_FACTORY(
            input_hwnd=device.input_hwnd,
            top_hwnd=device.hwnd,
            offset=(device.offset_x, device.offset_y),
            capture_size=(device.capture_width, device.capture_height),
            design_size=self.backend.design_size,
            sample_interval_ms=int(args.get("sampleIntervalMs", 16)),
            target_pid=device.pid,
            api=self.backend.api,
        )
        recorder.start()
        self.recorder = recorder
        self.recordings = {
            "deviceId": device.device_id,
            "screenWidth": self.backend.design_size[0],
            "screenHeight": self.backend.design_size[1],
            "startedAt": time.time(),
        }
        return {"ok": True, "device": device.to_dict(), "status": recorder.status()}

    def cmd_record_poll(self, args: Dict[str, Any]) -> Dict[str, Any]:
        recorder = self.recorder
        if recorder is None:
            return {"running": False, "actionCount": 0, "actions": []}
        status = recorder.status()
        status["actions"] = recorder.snapshot_actions()
        return status

    def cmd_record_stop(self, args: Dict[str, Any]) -> Dict[str, Any]:
        recorder = self.recorder
        if recorder is None:
            raise RuntimeError("当前没有录制在进行中")
        actions = recorder.stop()
        self.recorder = None
        payload = {
            "ok": True,
            "actions": actions,
            "actionCount": len(actions),
            "screenWidth": self.recordings.get("screenWidth", self.backend.design_size[0]),
            "screenHeight": self.recordings.get("screenHeight", self.backend.design_size[1]),
            "deviceId": self.recordings.get("deviceId", ""),
            "durationSeconds": round(time.time() - float(self.recordings.get("startedAt", time.time())), 1),
        }
        self.recordings = {}
        return payload

    def cmd_shutdown(self, args: Dict[str, Any]) -> Dict[str, Any]:
        raise _Shutdown()


class _Shutdown(Exception):
    pass


COMMANDS: Dict[str, Callable[[Helper, Dict[str, Any]], Any]] = {
    "ping": Helper.cmd_ping,
    "health": Helper.cmd_health,
    "list_devices": Helper.cmd_list_devices,
    "refresh": Helper.cmd_refresh,
    "config": Helper.cmd_config,
    "capture": Helper.cmd_capture,
    "probe_capture": Helper.cmd_probe_capture,
    "click": Helper.cmd_click,
    "double_click": Helper.cmd_double_click,
    "swipe": Helper.cmd_swipe,
    "drag": Helper.cmd_drag,
    "scroll": Helper.cmd_scroll,
    "text": Helper.cmd_text,
    "key": Helper.cmd_key,
    "activate": Helper.cmd_activate,
    "resize": Helper.cmd_resize,
    "ensure_running": Helper.cmd_ensure_running,
    "start": Helper.cmd_start,
    "stop": Helper.cmd_stop,
    "restart": Helper.cmd_restart,
    "stats": Helper.cmd_stats,
    "record_start": Helper.cmd_record_start,
    "record_poll": Helper.cmd_record_poll,
    "record_stop": Helper.cmd_record_stop,
    "shutdown": Helper.cmd_shutdown,
}


def handle_line(helper: Helper, line: str) -> Optional[Dict[str, Any]]:
    line = line.strip()
    if not line:
        return None
    request_id = None
    try:
        request = json.loads(line)
    except Exception as exc:  # noqa: BLE001
        return {"id": None, "ok": False, "error": f"请求不是合法 JSON：{exc}"}
    if not isinstance(request, dict):
        return {"id": None, "ok": False, "error": "请求必须是 JSON 对象"}
    request_id = request.get("id")
    cmd = request.get("cmd")
    args = request.get("args") or {}
    if not isinstance(args, dict):
        return {"id": request_id, "ok": False, "error": "args 必须是 JSON 对象"}
    handler = COMMANDS.get(str(cmd))
    if handler is None:
        return {"id": request_id, "ok": False,
                "error": f"未知命令：{cmd}", "commands": sorted(COMMANDS)}
    try:
        data = handler(helper, args)
        # 设备操作自己有 ok 字段：失败时把它提升为协议级失败，细节仍放在 data 里
        if isinstance(data, dict) and data.get("ok") is False:
            return {
                "id": request_id, "ok": False,
                "error": str(data.get("error") or data.get("reason") or "操作失败"),
                "data": data,
            }
        return {"id": request_id, "ok": True, "data": data, "error": None}
    except _Shutdown:
        raise
    except Exception as exc:  # noqa: BLE001
        log(f"命令 {cmd} 失败：{traceback.format_exc()}")
        return {"id": request_id, "ok": False, "error": f"{type(exc).__name__}: {exc}"}


def serve(helper: Helper) -> int:
    win_api.ensure_utf8_stdout()
    try:
        sys.stdin.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[attr-defined]
    except Exception:
        pass
    log(f"服务就绪 pid={os.getpid()} 平台={'windows' if win_api.IS_WINDOWS else os.name}")
    for line in sys.stdin:
        try:
            response = handle_line(helper, line)
        except _Shutdown:
            log("收到 shutdown，退出")
            return 0
        if response is None:
            continue
        sys.stdout.write(json.dumps(response, ensure_ascii=False) + "\n")
        sys.stdout.flush()
    return 0


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="时空客户端常驻控制服务")
    parser.add_argument("--health", action="store_true", help="跑一次自检后退出")
    parser.add_argument("--list", action="store_true", help="列出已注册命令")
    parser.add_argument("--shot-dir", default=DEFAULT_SHOT_DIR, help="截图输出目录")
    args = parser.parse_args(argv)

    if args.list:
        for name in sorted(COMMANDS):
            print(name)
        return 0

    if not win_api.IS_WINDOWS:
        # 这个常驻服务只能控制 Windows 上的客户端；在别的平台上给出明确指引，
        # 而不是抛一堆 ctypes 的栈（macOS 上开发界面时很容易踩到）。
        print(
            f"常驻控制服务只能在 Windows 上运行（当前平台：{sys.platform}）。\n"
            "请在装有《梦幻西游：时空》客户端的 Windows 机器上运行本脚本；\n"
            "非 Windows 平台想验证逻辑，请跑单元测试：\n"
            "  python -m unittest discover -s tests/python -t tests/python",
            file=sys.stderr,
        )
        return 2

    helper = Helper()
    helper.shot_dir = os.path.abspath(args.shot_dir)
    os.makedirs(helper.shot_dir, exist_ok=True)

    if args.health:
        win_api.ensure_utf8_stdout()
        print(json.dumps(helper.cmd_health({}), ensure_ascii=False, indent=2))
        return 0
    return serve(helper)


if __name__ == "__main__":
    raise SystemExit(main())
