#!/usr/bin/env python3
# coding=utf-8
"""验收工具（tools/win_acceptance.py）的测试。

报告结构直接复用 test_win_recommend 里的 make_report（那份数据是用真实探测工具
的字段形状写的），所以这里同时也在守着"验收工具读得懂真实探测报告"这条契约。
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "scripts", "win"))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import win_acceptance  # noqa: E402
import win_capture  # noqa: E402
from test_win_recommend import TAG, make_method, make_report  # noqa: E402


def all_methods_ok():
    return [make_method(name) for name in win_capture.DEFAULT_ORDER]


def input_section(effective="sendinput"):
    section = {"baseline_ratio": 0.01, "recommendation": effective}
    for name in ("postmessage", "sendmessage", "sendinput"):
        entry = {"diff": {"changed_ratio": 0.2 if name == effective else 0.0},
                 "diff_vs_baseline": 0.2 if name == effective else 0.0,
                 "likely_effective": name == effective}
        section[name] = entry
    return section


def smoke_report(results=None):
    return {
        "checks": [],
        "results": results if results is not None else [
            {"name": "窗口可寻址", "ok": True, "detail": "win:1111"},
            {"name": "截图", "ok": True, "detail": "printwindow_client"},
        ],
        "environment": {"configFound": True},
    }


def probe_step(report=None, exit_code=0, skipped=False, output="probe log"):
    return {
        "exitCode": exit_code,
        "output": output,
        "report": report,
        "reportPath": None,
        "skipped": skipped,
    }


def smoke_step(report=None, exit_code=0, skipped=False, output="smoke log"):
    return {
        "exitCode": exit_code,
        "output": output,
        "report": report,
        "reportPath": None,
        "skipped": skipped,
    }


def good_recommendation(report):
    return win_acceptance.build_recommendation(report, None)


class SummarizeTest(unittest.TestCase):
    def test_devices_and_capture_methods_come_from_real_report_shape(self):
        report = make_report(methods=all_methods_ok())
        devices = win_acceptance.summarize_devices(report)
        self.assertEqual(len(devices), 1)
        self.assertEqual(devices[0]["deviceId"], "win:1111")
        self.assertEqual(devices[0]["tag"], TAG)
        self.assertEqual(devices[0]["clientSize"], "1600x900")
        rows = win_acceptance.summarize_methods(report)
        self.assertEqual(len(rows), len(win_capture.DEFAULT_ORDER))
        self.assertTrue(all(row["ok"] for row in rows))
        self.assertEqual(rows[0]["deviceId"], "win:1111")
        self.assertIsNotNone(rows[0]["blackRatio"])

    def test_input_and_keyboard_sections(self):
        report = make_report(methods=all_methods_ok(),
                             input_section=input_section("sendmessage"),
                             keyboard={"injected": "hello", "ok": True})
        inputs = win_acceptance.summarize_input(report)
        self.assertEqual(len(inputs), 3)
        effective = [row for row in inputs if row.get("effective")]
        self.assertEqual([row["method"] for row in effective], ["sendmessage"])
        self.assertEqual(inputs[0]["recommendation"], "sendmessage")
        keyboard = win_acceptance.summarize_keyboard(report)
        self.assertEqual(len(keyboard), 1)
        self.assertEqual(keyboard[0]["injected"], "hello")

    def test_empty_or_missing_report_is_safe(self):
        for report in (None, {}, {"targets": []}, {"targets": "x"}):
            self.assertEqual(win_acceptance.summarize_devices(report), [])
            self.assertEqual(win_acceptance.summarize_methods(report), [])
            self.assertEqual(win_acceptance.summarize_input(report), [])


class VerdictTest(unittest.TestCase):
    def test_all_green(self):
        report = make_report(methods=all_methods_ok())
        verdict = win_acceptance.evaluate_verdict(
            probe_step(report), good_recommendation(report),
            smoke_step(smoke_report()))
        self.assertTrue(verdict["ok"], verdict["problems"])
        self.assertIn("acceptance_report.md", " ".join(verdict["next"]))

    def test_no_device_is_a_problem(self):
        report = make_report(methods=all_methods_ok(), targets=False)
        verdict = win_acceptance.evaluate_verdict(
            probe_step(report), good_recommendation(report),
            smoke_step(smoke_report()))
        self.assertFalse(verdict["ok"])
        self.assertTrue(any("没有找到候选窗口" in item for item in verdict["problems"]))

    def test_failed_config_write_is_a_problem(self):
        """写配置失败必须算问题：实机上报告说"通过"，但配置根本没写进去。

        最典型的失败原因是 config\\win_backend.json 已存在、没加 --force，
        这时运行时用的还是旧配置（实机上是一份只有两个后端的旧文件）。
        """
        report = make_report(methods=all_methods_ok())
        written = {"exitCode": 1, "output": "配置已存在，未覆盖……"}
        verdict = win_acceptance.evaluate_verdict(
            probe_step(report), good_recommendation(report),
            smoke_step(smoke_report()), config_written=written)
        self.assertFalse(verdict["ok"])
        problems = " ".join(verdict["problems"])
        self.assertIn("没有写进 config", problems)
        self.assertIn("--force", problems)

    def test_successful_or_absent_config_write_is_not_a_problem(self):
        report = make_report(methods=all_methods_ok())
        for written in (None, {"exitCode": 0, "output": "已写入……"}):
            with self.subTest(written=written):
                verdict = win_acceptance.evaluate_verdict(
                    probe_step(report), good_recommendation(report),
                    smoke_step(smoke_report()), config_written=written)
                self.assertTrue(verdict["ok"], verdict["problems"])

    def test_broken_enumeration_is_not_reported_as_missing_client(self):
        """枚举到 0 个窗口时，结论必须是"枚举机制失效"，不能让人去重启游戏。"""
        report = make_report(methods=[], targets=False)
        report["meta"]["windowScan"] = {"totalTopLevel": 0, "candidates": 0,
                                        "enumerationBroken": True}
        verdict = win_acceptance.evaluate_verdict(
            probe_step(report), good_recommendation(report),
            smoke_step(smoke_report()))
        self.assertFalse(verdict["ok"])
        problems = " ".join(verdict["problems"])
        self.assertIn("枚举", problems)
        self.assertIn("不是客户端没启动", problems)
        self.assertNotIn("确认《梦幻西游：时空》客户端已启动", problems)

    def test_all_capture_methods_dead_is_a_problem(self):
        methods = []
        for name in win_capture.DEFAULT_ORDER:
            item = make_method(name, ok=False, black=1.0, colors=1)
            methods.append(item)
        report = make_report(methods=methods)
        verdict = win_acceptance.evaluate_verdict(
            probe_step(report), good_recommendation(report),
            smoke_step(smoke_report()))
        self.assertFalse(verdict["ok"])
        self.assertTrue(any("全部不可用" in item for item in verdict["problems"]))

    def test_no_capture_data_is_a_problem(self):
        report = make_report(methods=[])
        verdict = win_acceptance.evaluate_verdict(
            probe_step(report), good_recommendation(report),
            smoke_step(smoke_report()))
        self.assertFalse(verdict["ok"])
        self.assertTrue(any("没有截图实测结果" in item for item in verdict["problems"]))

    def test_smoke_failures_are_listed(self):
        report = make_report(methods=all_methods_ok())
        results = [{"name": "窗口可寻址", "ok": True, "detail": ""},
                   {"name": "后台点击", "ok": False, "detail": "超时"}]
        verdict = win_acceptance.evaluate_verdict(
            probe_step(report), good_recommendation(report),
            smoke_step(smoke_report(results)))
        self.assertFalse(verdict["ok"])
        self.assertTrue(any("冒烟检查未通过" in item and "后台点击" in item
                            for item in verdict["problems"]))

    def test_input_methods_not_effective_is_a_problem_only_when_measured(self):
        report = make_report(methods=all_methods_ok(), input_section=input_section(""))
        for name in ("postmessage", "sendmessage", "sendinput"):
            report["input"][TAG][name]["likely_effective"] = False
        report["input"][TAG]["recommendation"] = None
        verdict = win_acceptance.evaluate_verdict(
            probe_step(report), good_recommendation(report),
            smoke_step(smoke_report()))
        self.assertTrue(any("没有输入后端被判定为生效" in item
                            for item in verdict["problems"]))

    def test_skipped_steps_are_reported_as_problems(self):
        verdict = win_acceptance.evaluate_verdict(
            probe_step(None, skipped=True),
            {"measured": False, "config": {}, "warnings": []},
            smoke_step(None, skipped=True))
        self.assertFalse(verdict["ok"])
        joined = " ".join(verdict["problems"])
        self.assertIn("探测被跳过", joined)
        self.assertIn("冒烟被跳过", joined)

    def test_missing_report_says_which_tool(self):
        verdict = win_acceptance.evaluate_verdict(
            probe_step(None, exit_code=1), {"measured": False, "config": {},
                                            "warnings": []},
            smoke_step(None, exit_code=1))
        joined = " ".join(verdict["problems"])
        self.assertIn("探测没有产出报告", joined)
        self.assertIn("冒烟没有产出报告", joined)


class ReportRenderTest(unittest.TestCase):
    def build(self, report, out_dir, written=None, smoke=None):
        recommendation = good_recommendation(report)
        probe = probe_step(report)
        smoke = smoke_step(smoke if smoke is not None else smoke_report())
        verdict = win_acceptance.evaluate_verdict(probe, recommendation, smoke)
        return win_acceptance.build_report(
            steps=[{"name": "probe", "skipped": False, "exitCode": 0,
                    "seconds": 1.5, "summary": "候选窗口 1 个", "output": "log"}],
            probe_step=probe, recommendation=recommendation, smoke_step=smoke,
            verdict=verdict, out_dir=out_dir, config_written=written,
            generated_at="2026-01-01 00:00:00",
        )

    def test_json_shape_and_markdown_sections(self):
        with tempfile.TemporaryDirectory() as tmp:
            report = make_report(methods=all_methods_ok(),
                                 input_section=input_section(),
                                 keyboard={"ok": True})
            data = self.build(report, tmp)
            self.assertEqual(data["generatedAt"], "2026-01-01 00:00:00")
            self.assertEqual(data["probe"]["devices"][0]["deviceId"], "win:1111")
            self.assertTrue(data["recommendation"]["measured"])
            self.assertTrue(data["verdict"]["ok"])
            # 必须是能序列化的纯数据（要发给别人）
            json.dumps(data, ensure_ascii=False)

            text = win_acceptance.render_markdown(data)
            for section in ("# 时空客户端控制层验收报告", "## 结论", "## 三步结果",
                            "## 设备（窗口）", "## 后端实测", "## 输入后端实测",
                            "## 文本注入实测", "## 推荐配置", "## 冒烟结果",
                            "## 原始输出"):
                self.assertIn(section, text)
            self.assertIn("win:1111", text)
            self.assertIn("sendinput", text)
            self.assertIn("acceptance_report.md", text)

    def test_markdown_survives_empty_report(self):
        with tempfile.TemporaryDirectory() as tmp:
            data = self.build(None, tmp, smoke={})
            text = win_acceptance.render_markdown(data)
            self.assertIn("没有候选窗口", text)
            self.assertIn("没有后端实测数据", text)
            self.assertIn("没有冒烟结果", text)


class RunAcceptanceTest(unittest.TestCase):
    """用注入的假步骤跑完整流程（本机不是 Windows，不能真跑子进程）。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.out_dir = os.path.join(self.tmp.name, "acceptance_out")
        self.calls = {}

    def fake_probe(self, report, exit_code=0):
        def runner(out_dir, with_input=False, timeout=0):
            self.calls["probe"] = {"out_dir": out_dir, "with_input": with_input}
            probe_dir = os.path.join(out_dir, "probe")
            os.makedirs(probe_dir, exist_ok=True)
            path = os.path.join(probe_dir, "win_probe_report.json")
            if report is not None:
                with open(path, "w", encoding="utf-8") as handle:
                    json.dump(report, handle, ensure_ascii=False)
            return {"exitCode": exit_code, "output": "探测输出", "report": report,
                    "reportPath": path}
        return runner

    def fake_smoke(self, report, exit_code=0):
        def runner(out_dir, with_input=False, timeout=0):
            self.calls["smoke"] = {"out_dir": out_dir, "with_input": with_input}
            smoke_dir = os.path.join(out_dir, "smoke")
            os.makedirs(smoke_dir, exist_ok=True)
            path = os.path.join(smoke_dir, "smoke_report.json")
            if report is not None:
                with open(path, "w", encoding="utf-8") as handle:
                    json.dump(report, handle, ensure_ascii=False)
            return {"exitCode": exit_code, "output": "冒烟输出", "report": report,
                    "reportPath": path}
        return runner

    def run_it(self, **kwargs):
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            report, code = win_acceptance.run_acceptance(
                self.out_dir,
                probe_runner=kwargs.pop("probe_runner", self.fake_probe(
                    make_report(methods=all_methods_ok()))),
                smoke_runner=kwargs.pop("smoke_runner", self.fake_smoke(smoke_report())),
                config_writer=kwargs.pop("config_writer",
                                         win_acceptance.write_backend_config),
                **kwargs,
            )
        return report, code, buffer.getvalue()

    def test_skip_probe_reuses_the_previous_report(self):
        """--skip-probe 的用途是"探测我已经单独跑过（带 --resize/--text），这里只汇总"。

        所以它必须真的把上次那份报告读回来：只把 report 置空的话，推荐会退化成
        "没有实测数据，配置只能靠猜"，等于逼用户重跑一遍探测（会再点一次游戏）。
        """
        probe_report = make_report(methods=all_methods_ok())
        self.fake_probe(probe_report)  # 先跑一次，把报告落到 <out>/probe/
        self.run_it()
        written = {}

        def recorder(probe_report_path, smoke_report_path, force=False):
            written["probe"] = probe_report_path
            written["force"] = force
            return {"exitCode": 0, "output": "已写入"}

        report, code, log = self.run_it(
            skip_probe=True, write_config=True, force=True,
            probe_runner=self.fake_probe(None),
            config_writer=recorder)
        self.assertEqual(code, 0, report["verdict"]["problems"])
        self.assertTrue(report["verdict"]["ok"], report["verdict"]["problems"])
        self.assertFalse(any("探测被跳过" in item for item in report["verdict"]["problems"]))
        # 复用的报告真的进了推荐，而不是空报告
        self.assertEqual(report["recommendation"]["config"]["captureOrder"][0],
                         "printwindow_renderfull")
        # 写配置拿到的也是那份复用报告
        self.assertEqual(os.path.basename(written["probe"]), "win_probe_report.json")
        self.assertTrue(written["force"])
        # 控制台和报告都要说清楚"这趟是复用的旧实测数据"
        self.assertIn("复用 ", log)
        self.assertEqual(report["steps"][0]["summary"], "跳过（复用上次报告）")

    def test_skip_probe_without_a_report_is_still_a_problem(self):
        report, code, log = self.run_it(skip_probe=True, probe_runner=self.fake_probe(None))
        self.assertFalse(report["verdict"]["ok"])
        self.assertTrue(any("探测被跳过" in item for item in report["verdict"]["problems"]))
        self.assertIn("没找到上次的报告", log)
        self.assertEqual(report["steps"][0]["summary"], "跳过（没有可复用的报告）")

    def test_writes_both_report_files_and_exits_zero(self):
        report, code, log = self.run_it()
        self.assertEqual(code, 0, report["verdict"]["problems"])
        self.assertTrue(report["verdict"]["ok"])
        json_path = os.path.join(self.out_dir, "acceptance_report.json")
        md_path = os.path.join(self.out_dir, "acceptance_report.md")
        self.assertTrue(os.path.isfile(json_path))
        self.assertTrue(os.path.isfile(md_path))
        with open(json_path, encoding="utf-8") as handle:
            self.assertEqual(json.load(handle)["verdict"]["ok"], True)
        with open(md_path, encoding="utf-8") as handle:
            self.assertIn("时空客户端控制层验收报告", handle.read())
        self.assertIn("结论：通过", log)
        # 步骤顺序：探测 → 推配置 → 冒烟
        self.assertEqual([step["name"] for step in report["steps"]],
                         ["probe", "recommend", "smoke"])

    def test_problem_run_exits_one_but_still_writes_report(self):
        report, code, log = self.run_it(
            probe_runner=self.fake_probe(make_report(methods=[])),
        )
        self.assertEqual(code, 1)
        self.assertFalse(report["verdict"]["ok"])
        self.assertIn("结论：未通过", log)
        self.assertTrue(os.path.isfile(
            os.path.join(self.out_dir, "acceptance_report.json")))

    def test_probe_failure_without_report(self):
        report, code, _log = self.run_it(probe_runner=self.fake_probe(None, exit_code=2))
        self.assertEqual(code, 1)
        self.assertTrue(any("探测没有产出报告" in item
                            for item in report["verdict"]["problems"]))

    def test_with_input_flag_is_passed_through(self):
        _report, _code, _log = self.run_it(with_input=True)
        self.assertTrue(self.calls["probe"]["with_input"])
        self.assertTrue(self.calls["smoke"]["with_input"])

    def test_skip_flags_mark_steps_skipped(self):
        report, code, _log = self.run_it(skip_probe=True, skip_smoke=True)
        self.assertEqual(code, 1)
        self.assertEqual([step["skipped"] for step in report["steps"]],
                         [True, False, True])
        self.assertEqual(summarize_names(report), ["probe", "recommend", "smoke"])

    def test_write_config_refused_without_capture_data(self):
        def forbidden_writer(*_args, **_kwargs):
            raise AssertionError("没有实测结果时不该写配置")

        report, code, log = self.run_it(
            probe_runner=self.fake_probe(make_report(methods=[])),
            config_writer=forbidden_writer,
            write_config=True,
        )
        self.assertEqual(code, 1)
        self.assertEqual(report["recommendation"]["written"]["exitCode"], 1)
        self.assertIn("不写配置", log)

    def test_write_config_calls_writer_when_measured(self):
        calls = []

        def writer(report_path, smoke_path, force=False):
            calls.append({"report": report_path, "smoke": smoke_path, "force": force})
            return {"exitCode": 0, "output": "written"}

        report, code, _log = self.run_it(write_config=True, force=True,
                                        config_writer=writer)
        self.assertEqual(code, 0)
        self.assertEqual(len(calls), 1)
        self.assertTrue(calls[0]["report"].endswith("win_probe_report.json"))
        self.assertTrue(str(calls[0]["smoke"]).endswith("smoke_report.json"))
        self.assertTrue(calls[0]["force"])
        self.assertEqual(report["recommendation"]["written"]["exitCode"], 0)

    def test_smoke_result_reorders_recommendation(self):
        """冒烟说哪个后端好，推荐就把哪个放第一位。"""
        methods = []
        for name in win_capture.DEFAULT_ORDER:
            item = make_method(name)
            if name != "bitblt_client":
                item["ok"] = False
                item["metrics"] = {"valid": False, "black_ratio": 1.0,
                                   "distinct_colors_sampled": 1}
            methods.append(item)
        report, code, _log = self.run_it(
            probe_runner=self.fake_probe(make_report(methods=methods)),
            smoke_runner=self.fake_smoke(smoke_report([
                {"name": "截图", "ok": True, "detail": "bitblt_client"},
            ])),
        )
        self.assertEqual(code, 0, report["verdict"]["problems"])
        self.assertEqual(report["recommendation"]["config"]["captureOrder"][0],
                         "bitblt_client")


def summarize_names(report):
    return [step["name"] for step in report["steps"]]


class MainCliTest(unittest.TestCase):
    def test_help_exits_zero(self):
        with contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(SystemExit) as caught:
                win_acceptance.main(["--help"])
        self.assertEqual(caught.exception.code, 0)

    def test_unknown_option_exits_two(self):
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as caught:
                win_acceptance.main(["--bogus"])
        self.assertEqual(caught.exception.code, 2)

    @unittest.skipIf(os.name == "nt", "这条只在非 Windows 上有意义")
    def test_non_windows_refuses_with_message(self):
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = win_acceptance.main(["--out", "acceptance_out_test"])
        self.assertEqual(code, 2)
        self.assertIn("只能在 Windows 上运行", buffer.getvalue())


class ChildProcessEncodingTest(unittest.TestCase):
    """父进程必须按 UTF-8 读子进程输出。

    子脚本（win_probe / smoke_win）启动时会 ``sys.stdout.reconfigure(encoding='utf-8')``，
    所以父进程用 ``text=True``（= 系统区域编码）去读就必然错位：中文 Windows 的区域
    编码是 GBK，子进程一输出中文就抛 UnicodeDecodeError。实机上的表现是控制台一串
    "Exception in thread Thread-1 (_readerthread)"，**并且那一段输出整段丢失**，
    报告里"原始输出"只剩 ASCII 的 stderr。
    """

    CHILD = (
        "import sys\n"
        "sys.stdout.reconfigure(encoding='utf-8')\n"
        "sys.stderr.reconfigure(encoding='utf-8')\n"
        "print('候选窗口 0 个 · 中文输出')\n"
        "sys.stderr.write('错误：没有找到候选窗口\\n')\n"
    )

    def run_child(self):
        return win_acceptance.run_child_process(
            [sys.executable, "-c", self.CHILD], timeout=60)

    def test_non_ascii_output_round_trips(self):
        exit_code, output = self.run_child()
        self.assertEqual(exit_code, 0)
        self.assertIn("候选窗口 0 个", output)
        self.assertIn("中文输出", output)
        self.assertIn("错误：没有找到候选窗口", output)

    def test_survives_a_gbk_locale_like_chinese_windows(self):
        """把区域编码伪造成 GBK（中文 Windows 的真实情况），输出仍然完整可读。"""
        import locale

        original = locale.getencoding
        locale.getencoding = lambda: "gbk"
        try:
            exit_code, output = self.run_child()
        finally:
            locale.getencoding = original
        self.assertEqual(exit_code, 0)
        self.assertIn("候选窗口 0 个", output)
        self.assertIn("错误：没有找到候选窗口", output)


if __name__ == "__main__":
    unittest.main()
