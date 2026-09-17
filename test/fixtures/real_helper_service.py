#!/usr/bin/env python3
# coding=utf-8
"""给 Dart 集成测试用的"真协议"常驻服务进程。

和 `test/windows_helper_client_test.dart` 里那个手写协议桩不同，这个进程跑的是
**真实的** `tools/win_helper.py`：真的 `serve()` 循环、真的 `handle_line()` 错误映射、
真的 `Helper.cmd_*` 实现，只把最底层的 Win32 换成假实现（macOS 上没有真窗口）。

用法：由 Dart 测试在临时工作区里生成一个 3 行的 `tools/win_helper.py` 启动器，
再用 `WindowsHelperClient` 指向它。这样"跨进程 JSON-Lines 协议"这一段就是真跑过的：
粘包/拆包、大 payload（base64 PNG）、Unicode、错误传播、shutdown 退出。

它复用了 Python 单测的假 Win32（`tests/python/fake_win_api.py`），
所以只能在仓库里跑（Dart 测试会按包根目录相对路径找到本文件）。
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
for extra in (REPO_ROOT / "scripts" / "win", REPO_ROOT / "tools", REPO_ROOT / "tests" / "python"):
    if str(extra) not in sys.path:
        sys.path.insert(0, str(extra))

import win_api  # noqa: E402
import win_capture  # noqa: E402
import win_device  # noqa: E402
import win_helper  # noqa: E402
import win_input  # noqa: E402
import win_window  # noqa: E402
from fake_win_api import FakeWin32Api  # noqa: E402

REQUEST_LOG_NAME = "helper_received_requests.jsonl"


class RecordingStdin:
    """把真实收到的请求行落盘，供 Dart 侧断言"线上到底传了什么"。

    serve() 只用到迭代与 reconfigure，这里原样透传。
    """

    def __init__(self, inner, log_path):
        self._inner = inner
        self._log_path = log_path

    def reconfigure(self, *args, **kwargs):
        return self._inner.reconfigure(*args, **kwargs)

    def __iter__(self):
        for line in self._inner:
            with open(self._log_path, "a", encoding="utf-8") as handle:
                handle.write(line if line.endswith("\n") else line + "\n")
            yield line


def build() -> win_helper.Helper:
    fake = FakeWin32Api()
    fake.add_game_window(0x1000, 1111, client_width=1600, client_height=900)
    # 走 Windows 分支，但底层是假 Win32（接口与真机一致）。
    # 注意：各模块 import 时各拿了一份 IS_WINDOWS 副本，这里要逐个置位，
    # 否则假环境的 health.isWindows 会是 False（真机上不存在这个问题）。
    win_api.IS_WINDOWS = True
    win_capture.IS_WINDOWS = True
    win_device.IS_WINDOWS = True
    win_input.IS_WINDOWS = True
    win_window.IS_WINDOWS = True
    win_api.set_api(fake)
    win_device.set_backend(
        win_device.WindowsBackend(
            config={"jitterRadius": 0, "pressGapMs": 0, "inputMethod": "postmessage"},
            api=fake,
        )
    )
    helper = win_helper.Helper()
    # 默认落在当前工作目录（Dart 侧给的是临时工作区），别污染仓库
    helper.shot_dir = os.environ.get("FAKE_HELPER_SHOT_DIR") or os.path.join(
        os.getcwd(), "shots"
    )
    os.makedirs(helper.shot_dir, exist_ok=True)
    return helper


if __name__ == "__main__":
    sys.stdin = RecordingStdin(sys.stdin, os.path.join(os.getcwd(), REQUEST_LOG_NAME))
    raise SystemExit(win_helper.serve(build()))
