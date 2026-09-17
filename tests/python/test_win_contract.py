#!/usr/bin/env python3
# coding=utf-8
"""Flutter ↔ Python 契约测试。

两侧是不同语言、不同进程，最容易出的问题是"界面调了一个常驻服务没实现的命令"
或"运行器需要的配置字段界面不再写"。这两类问题在 macOS 上都测不出来，
所以在源码层面把它们钉住。
"""

from __future__ import annotations

import os
import re
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "scripts", "win"))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.path.insert(0, os.path.join(ROOT, "tests", "python"))

import win_capture  # noqa: E402
import win_helper  # noqa: E402  (导入即注册命令表)
import win_probe  # noqa: E402

MAIN_DART = os.path.join(ROOT, "lib", "main.dart")
DART_CLIENT = os.path.join(ROOT, "lib", "windows_helper_client.dart")

# 常驻服务里给命令行/运行器用、界面暂不调用的命令（反向检查的白名单）
CLI_ONLY_COMMANDS = {
    "config",   # 读写 config/win_backend.json，命令行排查用
    "drag",     # 流程运行器内部走 win_device，不经过常驻服务
    "scroll",   # 同上
    "refresh",  # 设备刷新由 list_devices 覆盖
}


def read_source(path: str) -> str:
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def dart_helper_commands(source: str) -> set:
    """收集 Dart 侧调用过的常驻服务命令（client.send 与内部 send 都算）。"""
    return set(re.findall(r"(?:client\.)?send\(\s*'([a-z_]+)'", source))


class HelperCommandContractTest(unittest.TestCase):
    def setUp(self):
        self.source = read_source(DART_CLIENT)
        self.commands = dart_helper_commands(self.source)
        self.registered = set(win_helper.COMMANDS)

    def test_dart_sends_at_least_the_expected_commands(self):
        self.assertGreaterEqual(len(self.commands), 20, self.commands)
        for command in ("ping", "capture", "click", "text", "record_stop", "shutdown"):
            self.assertTrue(command in self.commands, f"界面没有调用 {command}")

    def test_every_dart_command_is_implemented(self):
        missing = sorted(self.commands - self.registered)
        self.assertEqual(missing, [], f"界面调用了常驻服务没实现的命令: {missing}")

    def test_unused_helper_commands_are_known(self):
        """反向检查：新增了命令却没接线，或接线被删掉时报警。"""
        unused = sorted(self.registered - self.commands)
        self.assertEqual(unused, sorted(CLI_ONLY_COMMANDS),
                         "常驻服务里出现了既没被界面调用、也不在白名单里的命令")

    def test_cli_lists_every_command(self):
        """--list 是用户排查时第一个会用的命令，必须列出全部命令。"""
        import subprocess

        result = subprocess.run(
            [sys.executable, os.path.join(ROOT, "tools", "win_helper.py"), "--list"],
            capture_output=True, text=True, timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        for command in self.registered:
            self.assertTrue(command in result.stdout, f"--list 里缺少 {command}")


class FlowRunnerConfigContractTest(unittest.TestCase):
    """运行器读取的配置字段必须由界面写入（运行器按 sys.argv[1] 读配置文件）。"""

    def setUp(self):
        self.source = read_source(MAIN_DART)

    def assert_writes_field(self, field: str) -> None:
        self.assertTrue(f"'{field}':" in self.source, f"界面写配置时缺字段 {field}")

    def test_custom_flow_config_fields(self):
        for field in (
            "deviceIds", "loopCount", "parallelDevices", "steps", "imagePaths",
            "recordedFlows", "mainModeScriptPath", "shutdownPidFilePath",
            "pythonExecutable",
        ):
            self.assert_writes_field(field)

    def test_recorded_flow_playback_fields(self):
        # 界面写的是 deviceId / loopCount / flows；skipDeviceCheck 由运行器默认 false
        for field in ("deviceId", "loopCount", "flows"):
            self.assert_writes_field(field)

    def test_config_path_is_passed_positionally(self):
        self.assertTrue(
            "runnerFile.path, configFile.path" in self.source,
            "运行器按 sys.argv[1] 读配置，界面必须传位置参数",
        )

    def test_windows_mode_prefers_repo_runner_files(self):
        self.assertTrue("workspace.flowRunnerScript" in self.source)
        self.assertTrue("workspace.recordRunnerScript" in self.source)


if __name__ == "__main__":
    unittest.main()


CUSTOM_FLOW_DART = os.path.join(ROOT, "lib", "custom_flow.dart")
FLOW_RUNNER = os.path.join(ROOT, "scripts", "win", "flow_runner_win.py")


def dart_step_types() -> set:
    """从 Dart 枚举里取出全部步骤类型。"""
    match = re.search(r"enum CustomFlowStepType \{(.*?)\}", read_source(CUSTOM_FLOW_DART), re.S)
    if match is None:
        raise AssertionError("在 custom_flow.dart 里找不到 CustomFlowStepType 枚举")
    return {
        line.strip().rstrip(",")
        for line in match.group(1).split("\n")
        if line.strip()
    }


def runner_step_types() -> set:
    """从生成的运行器里取出全部被分派的步骤类型。"""
    return set(re.findall(r"step_type == '([A-Za-z]+)'", read_source(FLOW_RUNNER)))


class CustomFlowStepSchemaContractTest(unittest.TestCase):
    """步骤词表/字段名是界面与运行器之间最容易悄悄漂移的地方。"""

    def test_step_type_vocabulary_matches_dart_enum(self):
        dart = dart_step_types()
        runner = runner_step_types()
        self.assertEqual(dart - runner, set(), "界面有、运行器没实现的步骤类型")
        self.assertEqual(runner - dart, set(), "运行器有、界面发不出来的步骤类型")

    def test_nested_steps_use_children_on_both_sides(self):
        self.assertIn("'children': children.map", read_source(CUSTOM_FLOW_DART))
        self.assertIn("step.get('children', [])", read_source(FLOW_RUNNER))

    def test_device_scope_values_match_enum(self):
        dart_enum = re.search(r"enum CustomFlowDeviceScope \{([^}]*)\}",
                              read_source(CUSTOM_FLOW_DART), re.S)
        self.assertIsNotNone(dart_enum)
        names = {
            item.strip()
            for item in re.split(r"[,\n]", dart_enum.group(1))
            if item.strip()
        }
        self.assertEqual(names, {"all", "first", "others"})
        runner = read_source(FLOW_RUNNER)
        for name in ("first", "others"):
            self.assertTrue(f"scope == '{name}'" in runner,
                            f"运行器没实现 deviceScope={name}")

    def test_text_step_fields_match(self):
        dart = read_source(CUSTOM_FLOW_DART)
        runner = read_source(FLOW_RUNNER)
        for field in ("textContent", "useParentLoopText"):
            self.assertTrue(field in dart, f"Dart 侧缺少字段 {field}")
            self.assertTrue(f"step.get('{field}'" in runner, f"运行器没读取字段 {field}")

    def test_runner_only_text_options_have_safe_defaults(self):
        """textInputMethod / clearTextFirst 界面暂时不写，运行器必须能缺省。"""
        runner = read_source(FLOW_RUNNER)
        self.assertIn("step.get('textInputMethod', '')", runner)
        self.assertIn("step.get('clearTextFirst', True)", runner)


PROTOCOL_DOC = os.path.join(ROOT, "docs", "WIN_HELPER_PROTOCOL.md")


def documented_helper_commands() -> set:
    """从协议文档的"命令表"里取出命令名（第一列的 `name`）。"""
    names: set = set()
    for line in read_source(PROTOCOL_DOC).split("\n"):
        if not line.startswith("|"):
            continue
        first_cell = line.split("|")[1]
        names |= set(re.findall(r"`([a-z_]+)`", first_cell))
    return names


class ProbeCaptureBackendContractTest(unittest.TestCase):
    """探测工具实测的后端，必须就是运行时能选的那几个（名字+集合都要一致）。

    这里真的错过一次：探测叫 `printwindow_clientonly`、运行时叫
    `printwindow_client`。后果有两层 —— 实测结果没法映射回运行时顺序，
    而且自动生成的配置会让运行时抛"未知截图后端"。
    """

    def test_probe_measures_exactly_the_runtime_backends(self):
        probe_names = [name for name, _ in win_probe.CAPTURE_METHODS]
        self.assertEqual(sorted(set(probe_names)), sorted(set(win_capture.DEFAULT_ORDER)),
                         "探测工具与运行时（win_capture.DEFAULT_ORDER）的截图后端对不上")
        self.assertEqual(len(probe_names), len(set(probe_names)), "探测后端列表有重复")
        for name in probe_names:
            self.assertIn(name, win_capture.METHODS,
                          f"运行时没有这个截图后端：{name}")
        for name in win_capture.CHILD_ORDER:
            self.assertIn(name, win_capture.METHODS)


class HelperProtocolDocContractTest(unittest.TestCase):
    """文档是会过期的东西：命令表和协议版本必须和实现逐字对上。"""

    def test_protocol_doc_lists_every_command(self):
        implemented = set(win_helper.COMMANDS)
        documented = documented_helper_commands()
        self.assertEqual(sorted(implemented - documented), [],
                         "实现了但协议文档漏写的命令")
        self.assertEqual(sorted(documented - implemented), [],
                         "协议文档写了但没实现的命令")

    def test_protocol_doc_matches_version(self):
        """文档里写的协议版本必须等于 ping 真正返回的版本。"""
        doc = read_source(PROTOCOL_DOC)
        self.assertTrue(
            f"当前协议版本：**{win_helper.PROTOCOL_VERSION}**" in doc,
            f"协议文档没写版本或版本对不上（实现为 {win_helper.PROTOCOL_VERSION}）",
        )
