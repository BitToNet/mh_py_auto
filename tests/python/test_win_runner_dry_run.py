#!/usr/bin/env python3
# coding=utf-8
"""运行器 `--dry-run` 自检的测试。

`--dry-run` 是给用户"不碰游戏先验一遍流程文件"用的，也是
"Dart 写出来的配置 Python 真的能读懂"这条链路的验证入口，
所以它自己的行为必须有测试盯着：
  - 通过时返回 0，失败时返回 1 并把人话写在 stdout；
  - **不连接窗口**（没有设备、设备 id 不存在都能跑）；
  - 校验的字段名必须和运行器真正读取的一致（模板 id / recordedFlowName …）。
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FLOW_RUNNER = os.path.join(ROOT, "scripts", "win", "flow_runner_win.py")
RECORD_RUNNER = os.path.join(ROOT, "scripts", "win", "record_runner_win.py")
PYTHON = sys.executable

PNG_BYTES = bytes.fromhex(
    "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4"
    "890000000d4944415478da63f8cfc0f01f0005fe01ffabce3689000000004945"
    "4e44ae426082"
)


def run_cli(script, config_path, *extra):
    process = subprocess.run(
        [PYTHON, script, config_path, *extra],
        cwd=ROOT, capture_output=True, text=True, timeout=120,
    )
    return process.returncode, process.stdout, process.stderr


def run_raw(script, *args):
    process = subprocess.run(
        [PYTHON, script, *args],
        cwd=ROOT, capture_output=True, text=True, timeout=120,
    )
    return process.returncode, process.stdout, process.stderr


class DryRunTestBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.template = os.path.join(self.tmp.name, "template.png")
        with open(self.template, "wb") as handle:
            handle.write(PNG_BYTES)

    def write_config(self, data, name="config.json"):
        path = os.path.join(self.tmp.name, name)
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(data, handle, ensure_ascii=False)
        return path

    def flow_config(self):
        return {
            "deviceIds": ["win:1111"],
            "loopCount": 2,
            "parallelDevices": False,
            "steps": [
                {"type": "wait", "waitMinMs": 100, "waitMaxMs": 200},
                {"type": "imageTap", "id": "tpl-1", "templateName": "开始按钮",
                 "imageSource": "localFile", "templatePath": self.template,
                 "confidence": 0.8},
                {"type": "loopBlock", "loopMode": "fixedCount", "loopCount": 3,
                 "children": [
                     {"type": "coordinateTap", "x": 800, "y": 450},
                     {"type": "recordedFlow", "recordedFlowName": "出招"},
                 ]},
                {"type": "imageBranch", "branchCases": [
                    {"id": "tpl-2", "templateName": "战斗图标",
                     "imageSource": "localFile", "templatePath": self.template,
                     "children": [{"type": "wait", "waitMinMs": 1}]},
                ]},
            ],
            "imagePaths": {"tpl-1": self.template, "tpl-2": self.template},
            "recordedFlows": {"出招": {"actions": [{"type": "tap", "x": 1, "y": 2}]}},
        }

    def record_config(self):
        return {
            "deviceId": "win:1111",
            "loopCount": 1,
            "flows": [{
                "name": "排队",
                "deviceId": "win:1111",
                "screenWidth": 1600,
                "screenHeight": 900,
                "actions": [
                    {"type": "tap", "startX": 10, "startY": 20, "endX": 10,
                     "endY": 20, "delayMs": 100},
                    {"type": "swipe", "startX": 1, "startY": 2, "endX": 3, "endY": 4,
                     "dragPath": [{"x": 1, "y": 2, "delayMs": 0}]},
                    {"type": "longPress", "startX": 5, "startY": 6, "durationMs": 600},
                    {"type": "longPressSwipe", "startX": 7, "startY": 8, "endX": 9,
                     "endY": 10, "holdBeforeMoveMs": 400},
                ],
            }],
        }


class FlowDryRunTest(DryRunTestBase):
    def test_valid_config_passes(self):
        path = self.write_config(self.flow_config())
        code, out, _err = run_cli(FLOW_RUNNER, path, "--dry-run")
        self.assertEqual(code, 0, out)
        self.assertIn("自检通过", out)
        # 嵌套步骤（循环块子步骤 + 分支子步骤）都要算进去
        self.assertIn("步骤: 共 7 个，最大嵌套 2 层", out)
        self.assertIn("coordinateTap", out)
        self.assertIn("出招（1 个动作）", out)
        self.assertIn("模板图片: 引用 2 个", out)

    def test_missing_template_file_fails(self):
        config = self.flow_config()
        config["imagePaths"]["tpl-1"] = os.path.join(self.tmp.name, "nope.png")
        path = self.write_config(config)
        code, out, _err = run_cli(FLOW_RUNNER, path, "--dry-run")
        self.assertEqual(code, 1)
        self.assertIn("模板图片文件不存在", out)
        self.assertIn("自检未通过", out)

    def test_template_without_path_entry_fails(self):
        config = self.flow_config()
        config["imagePaths"] = {}
        path = self.write_config(config)
        code, out, _err = run_cli(FLOW_RUNNER, path, "--dry-run")
        self.assertEqual(code, 1)
        self.assertIn("没有对应图片", out)

    def test_local_template_without_file_is_reported(self):
        """本地文件模板没选路径：界面根本不会导出，运行到这一步必失败。"""
        config = self.flow_config()
        config["steps"] = [{
            "type": "imageTap", "id": "tpl-x", "templateName": "没选文件",
            "imageSource": "localFile", "templatePath": "",
        }]
        config["imagePaths"] = {}
        path = self.write_config(config)
        code, out, _err = run_cli(FLOW_RUNNER, path, "--dry-run")
        self.assertEqual(code, 1)
        self.assertIn("没有选择本地模板文件", out)

    def test_asset_template_needs_only_a_name(self):
        """内置资源模板只要有名字就是可用的（界面会从 assets 里导出）。"""
        config = self.flow_config()
        config["steps"] = [{
            "type": "imageTap", "id": "tpl-a", "templateName": "开始按钮",
            "imageSource": "asset", "templatePath": "",
        }]
        config["imagePaths"] = {"tpl-a": self.template}
        path = self.write_config(config)
        code, out, _err = run_cli(FLOW_RUNNER, path, "--dry-run")
        self.assertEqual(code, 0, out)

    def test_text_recognition_step_does_not_need_template(self):
        """文字识别模式的识图步骤没有模板图，不能要求 imagePaths 里有它。"""
        config = self.flow_config()
        config["steps"] = [{
            "type": "imageTap", "id": "text-step", "recognitionMode": "text",
            "ocrTargetText": "确定",
        }]
        config["imagePaths"] = {}
        path = self.write_config(config)
        code, out, _err = run_cli(FLOW_RUNNER, path, "--dry-run")
        self.assertEqual(code, 0, out)
        self.assertIn("自检通过", out)

    def test_image_condition_loop_needs_its_template(self):
        config = self.flow_config()
        config["steps"] = [{
            "type": "loopBlock", "id": "loop-tpl", "loopMode": "imageCondition",
            "templateName": "循环条件", "imageSource": "localFile",
            "templatePath": self.template, "children": [],
        }]
        config["imagePaths"] = {}
        path = self.write_config(config)
        code, out, _err = run_cli(FLOW_RUNNER, path, "--dry-run")
        self.assertEqual(code, 1)
        self.assertIn("循环条件", out)

    def test_image_condition_loop_passes_with_template(self):
        config = self.flow_config()
        config["steps"] = [{
            "type": "loopBlock", "id": "loop-tpl", "loopMode": "imageCondition",
            "templateName": "循环条件", "imageSource": "localFile",
            "templatePath": self.template, "children": [],
        }]
        config["imagePaths"] = {"loop-tpl": self.template}
        path = self.write_config(config)
        code, out, _err = run_cli(FLOW_RUNNER, path, "--dry-run")
        self.assertEqual(code, 0, out)

    def test_unused_template_is_only_a_warning(self):
        config = self.flow_config()
        config["imagePaths"]["tpl-9"] = self.template
        path = self.write_config(config)
        code, out, _err = run_cli(FLOW_RUNNER, path, "--dry-run")
        self.assertEqual(code, 0, out)
        self.assertIn("没有被任何步骤引用", out)

    def test_game_mode_step_is_rejected(self):
        config = self.flow_config()
        config["steps"].append({"type": "gameMode"})
        path = self.write_config(config)
        code, out, _err = run_cli(FLOW_RUNNER, path, "--dry-run")
        self.assertEqual(code, 1)
        self.assertIn("痒痒鼠模式", out)
        self.assertIn("不支持", out)

    def test_unknown_step_type_is_rejected(self):
        config = self.flow_config()
        config["steps"].append({"type": "screenshot"})
        path = self.write_config(config)
        code, out, _err = run_cli(FLOW_RUNNER, path, "--dry-run")
        self.assertEqual(code, 1)
        self.assertIn("不支持的步骤类型: screenshot", out)

    def test_recorded_flow_reference_must_exist(self):
        config = self.flow_config()
        config["recordedFlows"] = {}
        path = self.write_config(config)
        code, out, _err = run_cli(FLOW_RUNNER, path, "--dry-run")
        self.assertEqual(code, 1)
        self.assertIn("不在 recordedFlows 里: 出招", out)

    def test_dry_run_does_not_need_a_real_device(self):
        """自检只读配置文件：设备列表为空也不该去连窗口。"""
        config = self.flow_config()
        config["deviceIds"] = []
        path = self.write_config(config)
        code, out, _err = run_cli(FLOW_RUNNER, path, "--dry-run")
        self.assertEqual(code, 0, out)
        self.assertIn("设备: 0 个", out)

    def test_empty_steps_pass(self):
        config = self.flow_config()
        config["steps"] = []
        config["imagePaths"] = {}
        config["recordedFlows"] = {}
        path = self.write_config(config)
        code, out, _err = run_cli(FLOW_RUNNER, path, "--dry-run")
        self.assertEqual(code, 0, out)
        self.assertIn("步骤: 共 0 个", out)

    def test_dry_run_without_config_exits_2(self):
        # 只给了 --dry-run、没给配置文件：报"未知选项"，而不是去 open 它
        code, _out, err = run_raw(FLOW_RUNNER, "--dry-run")
        self.assertEqual(code, 2)
        self.assertIn("未知选项", err)
        self.assertNotIn("Traceback", err)

    def test_extra_argument_still_rejected(self):
        path = self.write_config(self.flow_config())
        code, _out, err = run_cli(FLOW_RUNNER, path, "--dry-run", "--bogus")
        self.assertEqual(code, 2)
        self.assertIn("多余的参数", err)

    def test_help_lists_dry_run(self):
        code, out, err = run_raw(FLOW_RUNNER, "--help")
        self.assertEqual(code, 0)
        self.assertIn("--dry-run", out + err)


class RecordDryRunTest(DryRunTestBase):
    def test_valid_config_passes(self):
        path = self.write_config(self.record_config())
        code, out, _err = run_cli(RECORD_RUNNER, path, "--dry-run")
        self.assertEqual(code, 0, out)
        self.assertIn("自检通过", out)
        self.assertIn("排队", out)
        self.assertIn("动作合计 4 个", out)
        self.assertIn("录制分辨率 1600x900", out)

    def test_dry_run_does_not_need_a_device(self):
        config = self.record_config()
        config["deviceId"] = "win:999999"
        path = self.write_config(config)
        code, out, _err = run_cli(RECORD_RUNNER, path, "--dry-run")
        self.assertEqual(code, 0, out)

    def test_missing_action_field_fails(self):
        config = self.record_config()
        del config["flows"][0]["actions"][0]["startY"]
        path = self.write_config(config)
        code, out, _err = run_cli(RECORD_RUNNER, path, "--dry-run")
        self.assertEqual(code, 1)
        self.assertIn("缺少 startY", out)

    def test_x_y_only_action_is_rejected(self):
        """回放器读的是 startX/startY：只写 x/y 的动作会被判为缺字段。"""
        config = self.record_config()
        config["flows"][0]["actions"] = [{"type": "tap", "x": 1, "y": 2}]
        path = self.write_config(config)
        code, out, _err = run_cli(RECORD_RUNNER, path, "--dry-run")
        self.assertEqual(code, 1)
        self.assertIn("缺少 startX", out)

    def test_branch_without_template_is_reported_clearly(self):
        """分支没配模板图 → 运行器一定失败，自检要直接说清原因。"""
        config = self.flow_config()
        config["steps"] = [{
            "type": "imageBranch",
            "branchCases": [{"id": "case-x", "label": "空分支", "children": []}],
        }]
        config["imagePaths"] = {}
        path = self.write_config(config)
        code, out, _err = run_cli(FLOW_RUNNER, path, "--dry-run")
        self.assertEqual(code, 1)
        self.assertIn("没有可用的模板图片", out)
        self.assertIn("分支没有配模板图片", out)
        self.assertIn("case-x", out)

    def test_legacy_single_template_branch_uses_branch_id(self):
        """旧格式单模板分支的模板 id 就是分支 id（界面导出与运行器一致）。"""
        config = self.flow_config()
        config["steps"] = [{
            "type": "imageBranch",
            "branchCases": [{
                "id": "case-1", "label": "战斗", "templateName": "战斗图标",
                "imageSource": "localFile", "templatePath": self.template,
                "children": [],
            }],
        }]
        config["imagePaths"] = {"case-1": self.template}
        path = self.write_config(config)
        code, out, _err = run_cli(FLOW_RUNNER, path, "--dry-run")
        self.assertEqual(code, 0, out)

    def test_out_of_range_coordinates_are_warned(self):
        """坐标超出录制分辨率时回放会被贴到窗口边缘（运行器不会报错，只提醒）。"""
        config = self.record_config()
        config["flows"][0]["actions"] = [
            {"type": "tap", "startX": 1700, "startY": 450},
            {"type": "swipe", "startX": 10, "startY": 10, "endX": 2000,
             "endY": 20, "dragPath": [{"x": 500, "y": 900}]},
        ]
        path = self.write_config(config)
        code, out, _err = run_cli(RECORD_RUNNER, path, "--dry-run")
        self.assertEqual(code, 0, out)
        self.assertIn("超出录制分辨率", out)
        self.assertIn("(1700, 450)", out)
        self.assertIn("终点坐标 (2000, 20)", out)
        self.assertIn("拖拽轨迹第 1 个点坐标 (500, 900)", out)

    def test_in_range_coordinates_are_not_warned(self):
        config = self.record_config()
        config["flows"][0]["actions"] = [
            {"type": "tap", "startX": 1599, "startY": 899},
            {"type": "tap", "startX": 0, "startY": 0},
        ]
        path = self.write_config(config)
        code, out, _err = run_cli(RECORD_RUNNER, path, "--dry-run")
        self.assertEqual(code, 0, out)
        self.assertNotIn("超出录制分辨率", out)

    def test_missing_screen_size_skips_range_check(self):
        config = self.record_config()
        config["flows"][0]["screenWidth"] = 0
        config["flows"][0]["screenHeight"] = 0
        config["flows"][0]["actions"] = [
            {"type": "tap", "startX": 9999, "startY": 9999},
        ]
        path = self.write_config(config)
        code, out, _err = run_cli(RECORD_RUNNER, path, "--dry-run")
        self.assertEqual(code, 0, out)
        self.assertNotIn("超出录制分辨率", out)

    def test_broken_drag_path_point_is_rejected(self):
        config = self.record_config()
        config["flows"][0]["actions"] = [{
            "type": "swipe", "startX": 1, "startY": 2, "endX": 3, "endY": 4,
            "dragPath": [{"x": 5}],
        }]
        path = self.write_config(config)
        code, out, _err = run_cli(RECORD_RUNNER, path, "--dry-run")
        self.assertEqual(code, 1)
        self.assertIn("拖拽轨迹第 1 个点缺少 y", out)

    def test_raw_pointer_events_are_rejected_with_hint(self):
        config = self.record_config()
        config["flows"][0]["actions"] = [
            {"type": "down", "startX": 1, "startY": 2}]
        path = self.write_config(config)
        code, out, _err = run_cli(RECORD_RUNNER, path, "--dry-run")
        self.assertEqual(code, 1)
        self.assertIn("原始指针事件", out)

    def test_unknown_action_type_is_rejected(self):
        config = self.record_config()
        config["flows"][0]["actions"] = [{"type": "teleport"}]
        path = self.write_config(config)
        code, out, _err = run_cli(RECORD_RUNNER, path, "--dry-run")
        self.assertEqual(code, 1)
        self.assertIn("动作类型不认识: teleport", out)

    def test_empty_flow_is_a_warning(self):
        config = self.record_config()
        config["flows"][0]["actions"] = []
        path = self.write_config(config)
        code, out, _err = run_cli(RECORD_RUNNER, path, "--dry-run")
        self.assertEqual(code, 0, out)
        self.assertIn("没有动作", out)

    def test_help_lists_dry_run(self):
        code, out, err = run_raw(RECORD_RUNNER, "--help")
        self.assertEqual(code, 0)
        self.assertIn("--dry-run", out + err)


class DryRunNeverTouchesDevicesTest(DryRunTestBase):
    """--dry-run 必须在设备层之前返回：没有窗口也不能影响自检。"""

    def test_flow_runner_exits_before_device_layer(self):
        config = self.flow_config()
        config["deviceIds"] = ["win:1111"]
        path = self.write_config(config)
        code, out, err = run_cli(FLOW_RUNNER, path, "--dry-run")
        self.assertEqual(code, 0, out + err)
        for leaked in ("找不到时空客户端窗口", "设备不存在", "截图失败"):
            self.assertNotIn(leaked, out + err)

    def test_recorded_runner_exits_before_device_layer(self):
        path = self.write_config(self.record_config())
        code, out, err = run_cli(RECORD_RUNNER, path, "--dry-run")
        self.assertEqual(code, 0, out + err)
        self.assertNotIn("找不到时空客户端窗口", out + err)


if __name__ == "__main__":
    unittest.main()
