#!/usr/bin/env python3
# coding=utf-8
"""把 lib/main.dart 内嵌的两个 Python 运行器转换成时空客户端 Windows 版。

用法：
    python scripts/win/build_win_runners.py            # 重新生成两个运行器
    python scripts/win/build_win_runners.py --check    # 校验磁盘上的文件是否最新

只做"整块替换"：把 Android/adb 专有的实现换成 Windows 设备层调用，
流程语义（步骤、分支、循环、OCR、模板匹配）保持原样，确保行为不退化。
每个锚点都要求命中一次，避免上游 main.dart 改动后静默产出错误的运行器。
"""

from __future__ import annotations

import os
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(os.path.dirname(ROOT))
MAIN_DART = os.path.join(REPO_ROOT, "lib", "main.dart")
OUT_FLOW = os.path.join(ROOT, "flow_runner_win.py")
OUT_RECORD = os.path.join(ROOT, "record_runner_win.py")

FLOW_FUNCTION = "_buildCustomFlowRunnerScript"
RECORD_FUNCTION = "_buildRecordedFlowPlaybackRunnerScript"


def extract_embedded_script(source_lines, function_name):
    """从 lib/main.dart 中取出内嵌的 Python 字符串（自动还原 Dart 转义）。"""
    try:
        start = next(
            index for index, line in enumerate(source_lines)
            if f"String {function_name}()" in line
        )
    except StopIteration:
        raise SystemExit(f"lib/main.dart 里找不到 {function_name}()") from None
    cursor = start
    while "return '''" not in source_lines[cursor] and "return r'''" not in source_lines[cursor]:
        cursor += 1
        if cursor >= len(source_lines):
            raise SystemExit(f"{function_name}() 里找不到 return '''")
    is_raw = "return r'''" in source_lines[cursor]
    end = cursor + 1
    while not source_lines[end].rstrip().endswith("''';"):
        end += 1
        if end >= len(source_lines):
            raise SystemExit(f"{function_name}() 的内嵌字符串没有结束标记")
    body = source_lines[cursor + 1:end]
    if is_raw:
        return "\n".join(body) + "\n"
    # 非 raw 字符串：按 Dart 转义规则逐字符还原（顺序扫描，避免 \\n 被二次处理）
    text = "\n".join(body)
    mapping = {"n": "\n", "r": "\r", "t": "\t", "'": "'", '"': '"', "\\": "\\", "$": "$"}
    out = []
    index = 0
    while index < len(text):
        char = text[index]
        if char == "\\" and index + 1 < len(text) and text[index + 1] in mapping:
            out.append(mapping[text[index + 1]])
            index += 2
            continue
        out.append(char)
        index += 1
    return "".join(out) + "\n"


def read_embedded_scripts():
    if not os.path.exists(MAIN_DART):
        raise SystemExit(f"找不到 {MAIN_DART}")
    with open(MAIN_DART, encoding="utf-8") as file:
        lines = file.read().split("\n")
    return (extract_embedded_script(lines, FLOW_FUNCTION),
            extract_embedded_script(lines, RECORD_FUNCTION))

# ---------------------------------------------------------------------------
# 公共片段
# ---------------------------------------------------------------------------
HEADER_FLOW = '''"""时空客户端（Windows）自定义流程执行器。

由 Flutter 侧写出配置文件（deviceIds/steps/imagePaths/recordedFlows/loopCount…）后
以 `python flow_runner_win.py <config.json>` 方式启动。流程语义与旧模拟器版完全一致，
区别只在于底层由 adb 换成了 Windows 窗口设备层（scripts/win/win_device.py）。

本文件由 scripts/win/build_win_runners.py 依据 lib/main.dart 内嵌的旧版运行器生成，
请勿手改：改动请落在生成器里，然后重新执行生成脚本。
"""

'''

HEADER_RECORD = '''"""时空客户端（Windows）录制手势回放器。

由 Flutter 侧写出配置文件（deviceId/flows/loopCount）后
以 `python record_runner_win.py <config.json>` 方式启动。

本文件由 scripts/win/build_win_runners.py 依据 lib/main.dart 内嵌的旧版运行器生成，
请勿手改：改动请落在生成器里，然后重新执行生成脚本。
"""

'''

BOOTSTRAP = '''
# ---------------------------------------------------------------------------
# 时空客户端 Windows 设备层接入
# ---------------------------------------------------------------------------
_WIN_DIR = os.path.dirname(os.path.abspath(__file__))
if _WIN_DIR not in sys.path:
    sys.path.insert(0, _WIN_DIR)

import win_api       # noqa: E402
import win_capture   # noqa: E402
import win_device    # noqa: E402
import win_replay    # noqa: E402

_BACKEND = None
_BACKEND_LOCK = threading.Lock()
# 重启客户端后 PID 会变，这里保存「逻辑设备 id -> 当前设备 token」的别名
_DEVICE_ALIASES = {}
_DEVICE_ALIAS_LOCK = threading.Lock()


def get_backend():
    """惰性初始化设备后端（首次使用时读取 config/win_backend.json）。"""
    global _BACKEND
    with _BACKEND_LOCK:
        if _BACKEND is None:
            _BACKEND = win_device.backend()
        return _BACKEND


def set_backend(instance):
    """测试/嵌入用：注入自定义后端。"""
    global _BACKEND
    with _BACKEND_LOCK:
        _BACKEND = instance
        win_device.set_backend(instance)
    return _BACKEND


def normalize_device_id(device_id):
    """把 win:<pid> / pid:<pid> / 12345 统一成内部数字 id（同时保证文件名合法）。"""
    token = str(device_id or '').strip()
    if not token:
        return ''
    body = token.split(':', 1)[1] if ':' in token else token
    try:
        return str(int(body, 0))
    except ValueError:
        return token


def device_token(device_id):
    """逻辑设备 id -> 当前实际设备 token（重启后自动跟随新 PID）。"""
    key = str(device_id)
    with _DEVICE_ALIAS_LOCK:
        return _DEVICE_ALIASES.get(key, key)


def bind_device_alias(device_id, new_token):
    key = str(device_id)
    with _DEVICE_ALIAS_LOCK:
        _DEVICE_ALIASES[key] = str(new_token)
    print(f'[{key}] 设备已重新绑定到 {new_token}')


def device_alias_table():
    with _DEVICE_ALIAS_LOCK:
        return dict(_DEVICE_ALIASES)


def require_device(device_id):
    """确认设备对应的客户端窗口还在，返回设备对象。"""
    device = get_backend().resolve(device_token(device_id))
    if device is None:
        raise RuntimeError(
            f'找不到时空客户端窗口（设备 {device_id}）。请确认客户端已启动、未最小化，'
            '且设备列表是最新的。'
        )
    return device
'''

# adb_screenshot -> Windows 截图
FLOW_SCREENSHOT = '''def adb_screenshot(device_id, output_path):
    """截取时空客户端画面并保存到 output_path，返回 BGR ndarray。

    函数名沿用旧版运行器，流程引擎其余部分无需改动。
    截图已归一化到设计分辨率（默认 1600x900），所以模板图片不用重做。
    """
    print(f'[{device_id}] 截图开始: {output_path}')
    backend = get_backend()
    image = backend.screenshot(device_token(device_id), save_path=output_path)
    if image is None:
        raise RuntimeError(
            f'截图失败（窗口可能已关闭、最小化或全部截图后端不可用）: {device_id}'
        )
    screen_size = get_device_screen_size(device_id)
    if image.shape[1] != screen_size[0] or image.shape[0] != screen_size[1]:
        image = win_capture.normalize_size(image, screen_size)
    print(f'[{device_id}] 截图完成: {output_path} ({image.shape[1]}x{image.shape[0]})')
    return image
'''

# 屏幕尺寸（含 parse_screen_size 一起替换）
FLOW_SCREEN_SIZE = '''def get_device_screen_size(device_id):
    """Windows 版：返回设计分辨率（截图与坐标都统一在这个空间里）。"""
    cached = _device_screen_size_cache.get(device_id)
    if cached:
        return cached
    device = require_device(device_id)
    backend = get_backend()
    screen_size = (int(device.capture_width), int(device.capture_height)) \\
        if device.is_child_capture else backend.design_size
    screen_size = backend.design_size
    _device_screen_size_cache[device_id] = screen_size
    return screen_size
'''

# 点击
FLOW_TAP = '''def tap(device_id, x, y):
    raw_x, raw_y, clamped_x, clamped_y = clamp_tap_point(x, y)
    if raw_x != clamped_x or raw_y != clamped_y:
        print(
            f'[{device_id}] 点击坐标超出边界，已从 ({raw_x}, {raw_y}) '
            f'修正为 ({clamped_x}, {clamped_y})，范围 X=0-{_tap_max_x}, Y=0-{_tap_max_y}'
        )
    result = get_backend().tap(device_token(device_id), clamped_x, clamped_y)
    if not result.get('ok'):
        raise RuntimeError(
            f'点击失败 ({clamped_x}, {clamped_y}): {result.get("error") or result}'
        )
    return result
'''

# adb shell / IME 段落 -> 空
FLOW_ADB_SHELL_BLOCK = '''# Windows 版没有 adb shell / ADB Keyboard：文本输入由设备层直接完成，
# 相关函数（adb_shell / adb_command_error / 各种 ime 检测）已整体移除。
'''

# ADB Keyboard 准备与粘贴文字 -> Windows 文本输入
FLOW_TEXT_BLOCK = '''def prepare_text_input(device_id):
    """Windows 下无需切换输入法，只确认窗口还在。"""
    device = require_device(device_id)
    return {'deviceId': device.device_id, 'method': None}


def restore_text_input(device_id, state):
    """Windows 下无需恢复输入法，保留占位以保持流程结构一致。"""
    return None


def run_paste_text_step(device_id, step, runtime_context=None):
    runtime_context = dict(runtime_context or {})
    label = step_label(step, '粘贴文字')
    if bool(step.get('useParentLoopText', False)):
        if 'currentLoopText' not in runtime_context:
            raise RuntimeError(
                '粘贴文字步骤设置为使用上层文本，但当前没有可用的文本循环内容'
            )
        text = str(runtime_context.get('currentLoopText', ''))
        source_text = '上层文本循环'
    else:
        text = str(step.get('textContent', '') or '')
        source_text = '固定文字'

    backend = get_backend()
    token = device_token(device_id)
    method = (step.get('textInputMethod', '') or '').strip() or None
    clear_first = bool(step.get('clearTextFirst', True))
    if clear_first:
        cleared = backend.clear_text(token)
        if not cleared.get('ok'):
            print(f'[{device_id}] [{label}] 清空输入框失败（忽略并继续输入）')
    result = backend.input_text(token, text, method=method)
    if not result.get('ok'):
        raise RuntimeError(f'文字输入失败: {result.get("error") or result}')
    print(
        f'[{device_id}] [{label}] 已输入{source_text}，字符数: {len(text)}，'
        f'输入方式: {result.get("method")}'
    )
    return result
'''

# Activity 语义 -> 客户端启停
FLOW_ACTIVITY_BLOCK = '''def detect_current_activity(device_id):
    """Windows 版：返回客户端窗口的伪组件名（win:<pid>/ShiKong）。"""
    device = require_device(device_id)
    component = f'{device.device_id}/ShiKong'
    print(f'[{device_id}] 当前窗口: {component}')
    return component


def package_name_from_component(component):
    return (component or '').split('/', 1)[0].strip()


def cold_start_package(device_id, package_name):
    """Windows 版：确保客户端在运行（没有就拉起启动器并等待窗口）。"""
    result = get_backend().ensure_running(device_token(device_id))
    if not result.get('ok'):
        raise RuntimeError(
            f'启动时空客户端失败: {result.get("error") or result}'
        )
    print(f'[{device_id}] 客户端已在运行: {package_name}')


def restart_activity(device_id, component):
    """Windows 版：重启时空客户端，并把逻辑设备重新绑定到新的 PID。"""
    backend = get_backend()
    token = device_token(device_id)
    device = backend.resolve(token)
    old_pid = device.pid if device else None
    print(f'[{device_id}] 正在重启时空客户端…（当前 PID {old_pid}）')
    result = backend.restart(token)
    started = result.get('started') or {}
    if not started.get('started'):
        raise RuntimeError(f'重启客户端失败: {started.get("error") or result}')

    exclude = {int(old_pid)} if old_pid else set()
    new_device = backend.wait_for_new_device(exclude_pids=exclude, timeout=180.0)
    if new_device is None:
        raise RuntimeError('重启后未等到新的客户端窗口，请检查启动器是否需要人工登录')
    bind_device_alias(device_id, new_device.device_id)
    _device_screen_size_cache.pop(device_id, None)
    backend.capture.invalidate()
    backend.input.invalidate()
    print(f'[{device_id}] 客户端已重启，新设备 {new_device.device_id}，'
          f'客户区 {new_device.client_width}x{new_device.client_height}')
'''

# gameMode 步骤（阴阳师内置脚本）-> 明确报错
FLOW_GAME_MODE_BLOCK = '''def run_game_mode_step(device_id, step, work_dir, runtime_context=None):
    """时空客户端版本不内置任何游戏任务脚本，此步骤不再支持。"""
    raise RuntimeError(
        '时空客户端版本不支持「痒痒鼠模式」步骤（该步骤对应内置的阴阳师任务脚本）。'
        '请改用「识图点击 / 坐标点击 / 录制流程」等步骤。'
    )
'''

# 录制回放（含 sendevent 段落）
FLOW_REPLAY_BLOCK = '''def ensure_replay_ready(device_id, flow):
    """Windows 版：确认窗口可用、必要时把客户区对齐到设计分辨率。"""
    backend = get_backend()
    device = require_device(device_id)
    if device.minimized:
        print(f'[{device_id}] [录制流程] 窗口最小化，正在恢复')
        backend.activate(device_token(device_id))
    return device
'''

FLOW_RECORDED_STEP = '''def run_recorded_flow_step(device_id, step, runtime_context=None):
    runtime_context = dict(runtime_context or {})
    label = step_label(step, '执行录制手势流程')
    flow_name = (step.get('recordedFlowName', '') or '').strip()
    if not flow_name:
        raise RuntimeError('录制手势步骤未选择任何录制流程')
    recorded_flows = runtime_context.get('recordedFlows', {})
    if not isinstance(recorded_flows, dict):
        recorded_flows = {}
    flow = recorded_flows.get(flow_name)
    if not isinstance(flow, dict):
        raise RuntimeError(f'未找到录制流程数据: {flow_name}')

    actions = flow.get('actions', [])
    if not isinstance(actions, list):
        actions = []
    loop_count = int(step.get('recordedFlowLoopCount', 1) or 0)
    backend = get_backend()
    token = device_token(device_id)
    ensure_replay_ready(device_id, flow)
    source_size = win_replay.recorded_flow_screen_size(flow)
    target_size = get_device_screen_size(device_id)
    if source_size and source_size != target_size:
        print(
            f'[{device_id}] [{label}] 录制分辨率 {source_size[0]}x{source_size[1]}，'
            f'当前设计分辨率 {target_size[0]}x{target_size[1]}，回放坐标将按比例缩放'
        )
    speed = float(step.get('recordedFlowSpeed', 1.0) or 1.0)
    speed = speed if speed > 0 else 1.0

    def sleep_scaled(seconds):
        time.sleep(max(seconds / speed, 0.0))

    current_loop = 0
    total_actions = 0
    while loop_count <= 0 or current_loop < loop_count:
        current_loop += 1
        print(
            f'[{device_id}] [{label}] 开始回放第 {current_loop} 轮，'
            f'流程 {flow_name}，动作数 {len(actions)}'
        )
        total_actions += win_replay.replay_actions(
            backend,
            token,
            actions,
            source_size,
            target_size,
            log=print,
            sleep=sleep_scaled,
        )
        print(f'[{device_id}] [{label}] 第 {current_loop} 轮录制流程回放完成')
    print(f'[{device_id}] [{label}] 录制流程 {flow_name} 回放结束，共 {total_actions} 个动作')
'''

# run_device：去掉 ADB Keyboard 准备
FLOW_RUN_DEVICE_HEAD = '''def run_device(device_id, steps, image_paths, loop_count, work_dir, runtime_context=None):
    runtime_context = dict(runtime_context or {})
    coordinator = runtime_context.get('serialCoordinator')
    device = require_device(device_id)
    print(
        f'[{device_id}] 设备就绪: {device.title!r} '
        f'{device.client_width}x{device.client_height} '
        f'({"子窗口截图" if device.is_child_capture else "顶层窗口截图"})'
    )
    if device.minimized:
        print(f'[{device_id}] 窗口最小化，正在恢复')
        get_backend().activate(device_token(device_id))
    try:
        current_loop = 0
        while loop_count <= 0 or current_loop < loop_count:
            current_loop += 1
            print(f'[{device_id}] 开始执行第 {current_loop} 轮')
            execute_steps(device_id, steps, image_paths, work_dir, runtime_context)
            print(f'[{device_id}] 第 {current_loop} 轮执行完成')
    finally:
        if coordinator is not None:
            coordinator.finish(device_id)
'''

FLOW_MAIN_DEVICES = '''    device_ids = [
        normalize_device_id(item) for item in (config.get('deviceIds', []) or [])
    ]
    device_ids = [item for item in device_ids if item]
    if not device_ids:
        raise RuntimeError('缺少执行设备')
    if device_ids and not config.get('skipDeviceCheck', False):
        for device_id in device_ids:
            require_device(device_id)
'''

# 单机回放运行器（录制流程直接回放）的对应片段
RECORD_BOOTSTRAP = '''
# ---------------------------------------------------------------------------
# 时空客户端 Windows 设备层接入
# ---------------------------------------------------------------------------
_WIN_DIR = os.path.dirname(os.path.abspath(__file__))
if _WIN_DIR not in sys.path:
    sys.path.insert(0, _WIN_DIR)

import win_api      # noqa: E402
import win_device   # noqa: E402
import win_replay   # noqa: E402

_BACKEND = None


def get_backend():
    global _BACKEND
    if _BACKEND is None:
        _BACKEND = win_device.backend()
    return _BACKEND


def set_backend(instance):
    global _BACKEND
    _BACKEND = instance
    win_device.set_backend(instance)
    return _BACKEND


def normalize_device_id(device_id):
    token = str(device_id or '').strip()
    if not token:
        return ''
    body = token.split(':', 1)[1] if ':' in token else token
    try:
        return str(int(body, 0))
    except ValueError:
        return token
'''

RECORD_SCREEN_SIZE = '''def get_device_screen_size(device_id):
    """Windows 版：返回设计分辨率（截图与坐标统一在这个空间）。"""
    cached = _device_screen_size_cache.get(device_id)
    if cached:
        return cached
    backend = get_backend()
    device = backend.resolve(device_id)
    if device is None:
        raise RuntimeError(f'找不到时空客户端窗口: {device_id}')
    screen_size = backend.design_size
    _device_screen_size_cache[device_id] = screen_size
    return screen_size
'''

RECORD_READY = '''def ensure_replay_ready(device_id, flow):
    """Windows 版：确认窗口可用。"""
    backend = get_backend()
    device = backend.resolve(device_id)
    if device is None:
        raise RuntimeError(f'找不到时空客户端窗口: {device_id}')
    if device.minimized:
        log(f'[{device_id}] window is minimized, restoring')
        backend.activate(device_id)
    return device
'''

RECORD_PLAY_FLOW = '''def play_flow(device_id, flow, flow_index, flow_count):
    flow_name = (flow.get('name', '') or f'flow_{flow_index}').strip()
    actions = flow.get('actions', [])
    if not isinstance(actions, list):
        actions = []
    log(f'[{device_id}] flow {flow_index}/{flow_count}: {flow_name}, actions={len(actions)}')
    backend = get_backend()
    ensure_replay_ready(device_id, flow)
    source_size = win_replay.recorded_flow_screen_size(flow)
    target_size = get_device_screen_size(device_id)
    if source_size and source_size != target_size:
        log(
            f'[{device_id}] recorded resolution {source_size[0]}x{source_size[1]}, '
            f'target resolution {target_size[0]}x{target_size[1]}; scaling replay coordinates'
        )
    count = win_replay.replay_actions(
        backend,
        device_id,
        actions,
        source_size,
        target_size,
        log=log,
    )
    log(f'[{device_id}] flow completed: {flow_name} ({count} actions)')
'''

RECORD_MAIN = '''    device_id = normalize_device_id(config.get('deviceId', ''))
    if not device_id:
        raise RuntimeError('Missing target device.')
    if not config.get('skipDeviceCheck', False):
        if get_backend().resolve(device_id) is None:
            raise RuntimeError(f'找不到时空客户端窗口: {device_id}')
'''


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'锚点 {label} 命中 {count} 次（期望 1 次），转换中止')
    return text.replace(old, new, 1)


def cut_block(text: str, start_marker: str, end_marker: str, new: str, label: str) -> str:
    start = text.find(start_marker)
    if start < 0:
        raise SystemExit(f'找不到起点：{label}')
    end = text.find(end_marker, start)
    if end < 0:
        raise SystemExit(f'找不到终点：{label}')
    return text[:start] + new + text[end:]


# 两个运行器共用的参数校验：-h/--help 走用法，缺参数/多余参数/未知选项都返回 2。
# 只认识 --dry-run 这一个开关；其余以 - 开头的一律当未知选项，
# 别把 --dry-run 当成配置文件路径去 open。
ARG_VALIDATION = (
    "    args = sys.argv[1:]\n"
    "    if not args or args[0] in ('-h', '--help'):\n"
    "        _print_usage()\n"
    "        raise SystemExit(0 if args else 2)\n"
    "    if args[0].startswith('-'):\n"
    "        print(f'未知选项: {args[0]}', file=sys.stderr)\n"
    "        _print_usage()\n"
    "        raise SystemExit(2)\n"
    "    extra_args = [item for item in args[1:] if item != '--dry-run']\n"
    "    if extra_args:\n"
    "        print(f'多余的参数: {extra_args}', file=sys.stderr)\n"
    "        _print_usage()\n"
    "        raise SystemExit(2)\n"
)


FLOW_USAGE = """def _print_usage() -> None:
    print(
        '时空客户端（Windows）自定义流程运行器',
        '',
        '用法: python flow_runner_win.py <配置文件.json> [--dry-run]',
        '  --dry-run  只校验配置文件（不连窗口、不点击游戏），通过返回 0',
        '',
        '配置文件由 Flutter 界面生成，字段：',
        "  deviceIds          ['win:<pid>', ...]  执行设备",
        '  loopCount          轮数（<=0 表示无限循环）',
        '  parallelDevices    true=多设备并行，false=串行',
        '  steps              自定义流程步骤数组',
        '  imagePaths         步骤模板图路径表',
        '  recordedFlows      录制流程名 -> 录制流程 JSON',
        '  mainModeScriptPath 内置脚本路径（痒痒鼠模式，Windows 不支持）',
        '  pythonExecutable   OCR 等子进程用的解释器',
        '  skipDeviceCheck    true=启动时不校验设备',
        '',
        '本文件由 scripts/win/build_win_runners.py 生成，请勿手改。',
        file=sys.stderr,
        sep='\\n',
    )


"""


RECORD_USAGE = """def _print_usage() -> None:
    print(
        '时空客户端（Windows）录制流程回放',
        '',
        '用法: python record_runner_win.py <配置文件.json> [--dry-run]',
        '  --dry-run  只校验配置文件（不连窗口、不回放），通过返回 0',
        '',
        '配置字段：',
        '  deviceId        win:<pid>',
        '  flows           录制流程数组',
        '  loopCount       轮数（<=0 表示无限循环）',
        '  skipDeviceCheck true=启动时不校验设备',
        '',
        '本文件由 scripts/win/build_win_runners.py 生成，请勿手改。',
        file=sys.stderr,
        sep='\\n',
    )


"""


FLOW_DRY_RUN = r'''
KNOWN_STEP_TYPES = (
    'wait', 'imageTap', 'ocrTap', 'coordinateTap', 'pasteText',
    'waitImageState', 'imageBranch', 'imagePositionBranch', 'loopBlock',
    'flowGroup', 'gameMode', 'recordedFlow', 'restartActivity',
    'shutdownComputer',
)
# 会引用模板图的步骤类型（loopBlock 只在 imageCondition 模式下引用）
IMAGE_STEP_TYPES = ('imageTap', 'waitImageState', 'imageBranch', 'imagePositionBranch',
                    'loopBlock')
UNSUPPORTED_STEP_TYPES = {
    'gameMode': '痒痒鼠模式（内置任务脚本）在时空客户端版本不支持',
}


def iter_flow_steps(steps, depth=1):
    """深度优先遍历所有步骤：children 是通用嵌套键，分支还要看 branchCases。"""
    for step in steps or []:
        if not isinstance(step, dict):
            continue
        yield step, depth
        for child, child_depth in iter_flow_steps(step.get('children', []), depth + 1):
            yield child, child_depth
        for case in step.get('branchCases', []) or []:
            if not isinstance(case, dict):
                continue
            for child, child_depth in iter_flow_steps(case.get('children', []), depth + 1):
                yield child, child_depth


def template_source_of(item):
    """模板图能不能用 —— 判定必须和界面侧 _exportStepTemplates/exportOne 一致。

    界面只导出两种情况：本地文件（要有路径）或内置资源（要有名字）。
    返回 (可用, 模板id, 模板名, 不能用时的原因)。
    """
    template_id = str(item.get('id', '') or '')
    name = str(item.get('templateName', '') or '')
    path = str(item.get('templatePath', '') or '').strip()
    source = str(item.get('imageSource', 'localFile') or 'localFile')
    if source == 'localFile':
        if not path:
            return False, template_id, name, '没有选择本地模板文件'
        return True, template_id, name, ''
    if not name.strip() and not path:
        return False, template_id, name, '内置模板没有选名字'
    return True, template_id, name, ''


def step_templates(step, step_type, no_template=None):
    """这一步引用到的模板图。返回可用的 [(模板id, 模板名)]，并把配不出来的收进 no_template。"""
    items = []
    if no_template is None:
        no_template = []
    if step.get('recognitionMode', 'image') == 'image':
        if step_type in ('imageTap', 'waitImageState', 'imagePositionBranch'):
            usable, template_id, name, reason = template_source_of(step)
            if usable:
                items.append((template_id, name))
            else:
                no_template.append('%s（%s）' % (name or template_id or step_type, reason))
        elif step_type == 'loopBlock' and step.get('loopMode') == 'imageCondition':
            usable, template_id, name, reason = template_source_of(step)
            if usable:
                items.append((template_id, name))
            else:
                no_template.append('循环条件（%s）' % reason)
    for case in step.get('branchCases', []) or []:
        if not isinstance(case, dict):
            continue
        if case.get('recognitionMode', 'image') == 'text':
            continue
        template_images = case.get('templateImages')
        if not isinstance(template_images, list) or not template_images:
            # 旧格式：分支自己带一张模板，模板 id 就是分支 id（界面侧 effectiveTemplateImages 同理）
            if not str(case.get('templateName', '') or '').strip() and \
                    not str(case.get('templatePath', '') or '').strip():
                no_template.append('%s（分支没有配模板图片）' % (case.get('id', '') or '(未命名分支)'))
                continue
            template_images = [case]
        for item in template_images:
            if not isinstance(item, dict):
                continue
            usable, template_id, name, reason = template_source_of(item)
            if usable:
                items.append((template_id, name))
            else:
                no_template.append('%s（%s）' % (name or template_id or '分支模板', reason))
    return items


def describe_flow_config(config):
    """--dry-run：只校验配置文件本身，不连窗口、不点游戏。返回退出码。"""
    print('==== 流程文件自检（--dry-run：不会连接窗口，也不会点击游戏）====')
    steps = config.get('steps', [])
    if not isinstance(steps, list):
        print('！steps 必须是数组')
        return 1
    device_ids = config.get('deviceIds', []) or []
    problems = []
    warnings = []
    counts = {}
    depth_max = 0
    templates = []
    recorded_steps = []
    for index, (step, depth) in enumerate(iter_flow_steps(steps), start=1):
        step_type = str(step.get('type', '') or '')
        counts[step_type] = counts.get(step_type, 0) + 1
        depth_max = max(depth_max, depth)
        if step_type not in KNOWN_STEP_TYPES:
            problems.append('第 %d 个步骤：不支持的步骤类型: %s' % (index, step_type))
            continue
        if step_type in UNSUPPORTED_STEP_TYPES:
            problems.append('第 %d 个步骤：%s' % (index, UNSUPPORTED_STEP_TYPES[step_type]))
        no_template = []
        for template_id, name in step_templates(step, step_type, no_template):
            templates.append((template_id, name, index))
        for detail in no_template:
            problems.append('第 %d 个步骤没有可用的模板图片（运行到这一步一定失败）: %s'
                            % (index, detail))
        if step_type == 'recordedFlow':
            recorded_steps.append((index, str(step.get('recordedFlowName', '') or '').strip()))
    print('设备: %d 个 %s' % (len(device_ids), device_ids or '（空）'))
    print('轮数: %s   并行: %s' % (
        config.get('loopCount', 1),
        '是' if config.get('parallelDevices', False) else '否',
    ))
    print('步骤: 共 %d 个，最大嵌套 %d 层' % (len(list(iter_flow_steps(steps))), depth_max))
    for step_type in sorted(counts):
        print('  %-18s %d' % (step_type, counts[step_type]))

    image_paths = config.get('imagePaths', {})
    if not isinstance(image_paths, dict):
        problems.append('imagePaths 必须是 {模板id: 文件路径} 字典')
        image_paths = {}
    used = set()
    for template_id, name, index in templates:
        used.add(template_id)
        path = image_paths.get(template_id)
        label = name or template_id or '(未命名模板)'
        if not path:
            problems.append('第 %d 个步骤引用的模板没有对应图片: %s (%s)'
                            % (index, label, template_id))
        elif not os.path.isfile(path):
            problems.append('模板图片文件不存在: %s -> %s' % (label, path))
    if templates:
        print('模板图片: 引用 %d 个，imagePaths 提供 %d 个' % (len(templates), len(image_paths)))
    unused = sorted(set(image_paths) - used)
    if unused:
        warnings.append('有 %d 张模板图没有被任何步骤引用（不影响执行）' % len(unused))

    recorded_flows = config.get('recordedFlows', {})
    if not isinstance(recorded_flows, dict):
        problems.append('recordedFlows 必须是 {名称: 录制流程} 字典')
        recorded_flows = {}
    for index, flow_name in recorded_steps:
        if not flow_name:
            problems.append('第 %d 个步骤是录制手势但没有选择录制流程' % index)
            continue
        flow = recorded_flows.get(flow_name)
        if not isinstance(flow, dict):
            problems.append('第 %d 个步骤引用的录制流程不在 recordedFlows 里: %s'
                            % (index, flow_name))
            continue
        actions = flow.get('actions')
        action_count = len(actions) if isinstance(actions, list) else 0
        print('录制流程: %s（%d 个动作）' % (flow_name, action_count))
        if action_count == 0:
            warnings.append('录制流程 %s 里没有动作' % flow_name)

    if warnings:
        print()
        print('提醒:')
        for line in warnings:
            print('  · %s' % line)
    if problems:
        print()
        print('问题:')
        for line in problems:
            print('  ！%s' % line)
        print()
        print('自检未通过：请先在「自定义流程」里修掉上面的问题，再去掉 --dry-run 运行。')
        return 1
    print()
    print('自检通过：配置本身没问题，去掉 --dry-run 即可按这份配置执行。')
    return 0


'''


RECORD_DRY_RUN = r'''
RECORDED_ACTION_TYPES = ('tap', 'longPress', 'swipe', 'longPressSwipe')
# Android 侧录制的原始指针事件；时空客户端的手势录制不会产生这些
RAW_POINTER_ACTION_TYPES = ('down', 'move', 'up', 'cancel')


def describe_recorded_flows(config):
    """--dry-run：只校验录制流程配置，不连窗口、不回放。返回退出码。"""
    print('==== 录制流程自检（--dry-run：不会连接窗口，也不会回放）====')
    flows = config.get('flows', [])
    if not isinstance(flows, list):
        print('！flows 必须是数组')
        return 1
    problems = []
    warnings = []
    total_actions = 0
    for index, flow in enumerate(flows, start=1):
        if not isinstance(flow, dict):
            problems.append('第 %d 个录制流程不是对象' % index)
            continue
        name = str(flow.get('name', '') or '').strip() or ('流程%d' % index)
        actions = flow.get('actions', [])
        if not isinstance(actions, list):
            problems.append('录制流程 %s 的 actions 必须是数组' % name)
            continue
        size = '%sx%s' % (flow.get('screenWidth', '?'), flow.get('screenHeight', '?'))
        try:
            screen_width = int(flow.get('screenWidth', 0) or 0)
            screen_height = int(flow.get('screenHeight', 0) or 0)
        except (TypeError, ValueError):
            screen_width = screen_height = 0
        print('  %-20s %5d 个动作   录制分辨率 %s' % (name, len(actions), size))
        total_actions += len(actions)
        if not actions:
            warnings.append('录制流程 %s 里没有动作' % name)
        for action_index, action in enumerate(actions, start=1):
            if not isinstance(action, dict):
                problems.append('录制流程 %s 第 %d 个动作不是对象' % (name, action_index))
                continue
            action_type = str(action.get('type', '') or '')
            if action_type in RAW_POINTER_ACTION_TYPES:
                problems.append('录制流程 %s 第 %d 个动作是原始指针事件(%s)，不能直接回放，'
                                '请在时空客户端上重新录一遍' % (name, action_index, action_type))
                continue
            if action_type not in RECORDED_ACTION_TYPES:
                problems.append('录制流程 %s 第 %d 个动作类型不认识: %s'
                                % (name, action_index, action_type))
                continue
            # 回放器（win_replay.build_replay_plan）一律读 startX/startY，
            # 拖拽再看 endX/endY；没有 x/y 这种字段。
            required = ['startX', 'startY']
            if action_type in ('swipe', 'longPressSwipe'):
                required += ['endX', 'endY']
            for key in required:
                if not isinstance(action.get(key), (int, float)):
                    problems.append('录制流程 %s 第 %d 个 %s 动作缺少 %s'
                                    % (name, action_index, action_type, key))
            drag_path = action.get('dragPath')
            if isinstance(drag_path, list):
                for point_index, point in enumerate(drag_path, start=1):
                    if not isinstance(point, dict):
                        problems.append('录制流程 %s 第 %d 个动作的拖拽轨迹第 %d 个点不是对象'
                                        % (name, action_index, point_index))
                        continue
                    for key in ('x', 'y'):
                        if not isinstance(point.get(key), (int, float)):
                            problems.append(
                                '录制流程 %s 第 %d 个动作的拖拽轨迹第 %d 个点缺少 %s'
                                % (name, action_index, point_index, key))
            # 坐标超出录制分辨率时回放会被贴到窗口边缘（win_replay 最后会 clamp），
            # 点不到想点的地方但不会报错，所以这里给出提醒。
            if screen_width > 0 and screen_height > 0:
                points = [('起点', action.get('startX'), action.get('startY'))]
                if action_type in ('swipe', 'longPressSwipe'):
                    points.append(('终点', action.get('endX'), action.get('endY')))
                for point_index, point in enumerate(drag_path or [], start=1):
                    if isinstance(point, dict):
                        points.append(('拖拽轨迹第 %d 个点' % point_index,
                                       point.get('x'), point.get('y')))
                for subject, point_x, point_y in points:
                    if not isinstance(point_x, (int, float)) or not isinstance(point_y, (int, float)):
                        continue
                    if (point_x < 0 or point_y < 0
                            or point_x >= screen_width or point_y >= screen_height):
                        warnings.append(
                            '录制流程 %s 第 %d 个动作的%s坐标 (%d, %d) 超出录制分辨率 %dx%d，'
                            '回放会被贴到窗口边缘'
                            % (name, action_index, subject, point_x, point_y,
                               screen_width, screen_height))
    print('设备: %s   轮数: %s' % (
        config.get('deviceId', '') or '（空）',
        config.get('loopCount', 1),
    ))
    print('流程: %d 个，动作合计 %d 个' % (len(flows), total_actions))
    if warnings:
        print()
        print('提醒:')
        for line in warnings:
            print('  · %s' % line)
    if problems:
        print()
        print('问题:')
        for line in problems:
            print('  ！%s' % line)
        print()
        print('自检未通过：请先在「手势录制」里重新录一遍，再去掉 --dry-run 回放。')
        return 1
    print()
    print('自检通过：配置本身没问题，去掉 --dry-run 即可按这份配置回放。')
    return 0


'''


def build_flow_runner(raw: str) -> str:
    text = raw

    # 1) 头部：接入 Windows 设备层
    text = replace_once(text, "import cv2\nimport numpy as np\n",
                        "import cv2\nimport numpy as np\n" + BOOTSTRAP, '头部')

    # 2) 去掉 ADB Keyboard 常量
    text = replace_once(
        text,
        "_adb_keyboard_component = 'com.android.adbkeyboard/.AdbIME'\n"
        "_adb_keyboard_package = 'com.android.adbkeyboard'\n",
        '',
        'ADB Keyboard 常量',
    )

    # 3) 截图
    text = cut_block(text, 'def adb_screenshot(device_id, output_path):', '\ndef sleep_random(', 
                     FLOW_SCREENSHOT, '截图')

    # 4) 屏幕尺寸（连同 parse_screen_size 一起去掉）
    text = cut_block(text, 'def parse_screen_size(output):', '\ndef recorded_flow_screen_size(',
                     FLOW_SCREEN_SIZE, '屏幕尺寸')

    # 5) 点击
    text = cut_block(text, 'def tap(device_id, x, y):', '\ndef adb_shell(',
                     FLOW_TAP, '点击')

    # 6) adb shell / IME 检测段
    text = cut_block(text, 'def adb_shell(device_id, args, check=True):',
                     'def flow_contains_paste_text(steps):',
                     FLOW_ADB_SHELL_BLOCK + '\n\n', 'adb shell 段')

    # 7) ADB Keyboard 准备 / 粘贴文字
    text = cut_block(text, 'def prepare_adb_keyboard(device_id):', 'def split_text_lines(text):',
                     FLOW_TEXT_BLOCK + '\n\n', 'ADB Keyboard 段')

    # 8) Activity 语义
    text = cut_block(text, 'def extract_activity_component(raw_text):',
                     'def schedule_desktop_shutdown(delay_seconds):',
                     FLOW_ACTIVITY_BLOCK + '\n\n', 'Activity 段')

    # 9) gameMode 步骤
    text = cut_block(text, 'def run_game_mode_step(device_id, step, work_dir, runtime_context=None):',
                     'def ensure_sendevent_ready(', FLOW_GAME_MODE_BLOCK + '\n\n', 'gameMode')

    # 10) sendevent 回放
    text = cut_block(text, 'def ensure_sendevent_ready(', 'def run_recorded_flow_step(',
                     FLOW_REPLAY_BLOCK + '\n\n', 'sendevent 段')

    # 11) 录制流程步骤
    text = cut_block(text, 'def run_recorded_flow_step(', 'def execute_steps(',
                     FLOW_RECORDED_STEP + '\n\n', '录制流程步骤')

    # 12) run_device：去掉 ADB Keyboard 准备
    text = cut_block(text, 'def run_device(device_id, steps, image_paths, loop_count, work_dir, runtime_context=None):',
                     'def main():', FLOW_RUN_DEVICE_HEAD + '\n\n', 'run_device')

    # 13) main：设备 id 归一化 + 启动前校验
    text = replace_once(
        text,
        "    device_ids = config.get('deviceIds', [])\n"
        "    if not device_ids:\n"
        "        raise RuntimeError('缺少执行设备')\n",
        FLOW_MAIN_DEVICES,
        'main 设备列表',
    )

    # 14) 顶部说明 + 去掉不再需要的导入
    text = replace_once(
        text,
        'import json\nimport base64\n',
        HEADER_FLOW + 'import json\n',
        '文件头注释',
    )

    # 15) 控制台按 UTF-8 输出，避免 Windows 控制台中文乱码
    text = replace_once(
        text,
        "    config_path = sys.argv[1]\n",
        "    win_api.ensure_utf8_stdout()\n"
        "    config_path = sys.argv[1]\n",
        'main 编码',
    )
    # 16) 参数用法说明（-h/--help、缺参数、多余参数）
    text = replace_once(
        text,
        '\ndef main():',
        '\n' + FLOW_USAGE + FLOW_DRY_RUN + 'def main():',
        '用法说明',
    )
    text = replace_once(
        text,
        "    if len(sys.argv) < 2:\n"
        "        raise RuntimeError('缺少配置文件路径')\n",
        ARG_VALIDATION, 
        '参数校验',
    )
    # 17) --dry-run：只校验配置文件，不连窗口、不点游戏
    text = replace_once(
        text,
        "    with open(config_path, 'r', encoding='utf-8') as file:\n"
        "        config = json.load(file)\n",
        "    with open(config_path, 'r', encoding='utf-8') as file:\n"
        "        config = json.load(file)\n"
        "    if '--dry-run' in sys.argv[2:]:\n"
        "        raise SystemExit(describe_flow_config(config))\n",
        'dry-run 入口',
    )
    return text


def build_record_runner(raw: str) -> str:
    text = raw
    text = replace_once(text, "import traceback\n", "import traceback\n" + RECORD_BOOTSTRAP, '头部')
    text = cut_block(text, 'def parse_screen_size(output):', 'def recorded_flow_screen_size(',
                     RECORD_SCREEN_SIZE, '屏幕尺寸')
    text = cut_block(text, 'def ensure_sendevent_ready(', 'def play_flow(',
                     RECORD_READY, 'sendevent 段')
    text = cut_block(text, 'def play_flow(', 'def main():', RECORD_PLAY_FLOW, 'play_flow')
    text = replace_once(
        text,
        "    device_id = (config.get('deviceId', '') or '').strip()\n"
        "    if not device_id:\n"
        "        raise RuntimeError('Missing target device.')\n",
        RECORD_MAIN,
        'main 设备',
    )
    # 转换后不再需要的 Android 专用导入
    text = replace_once(
        text,
        "import json\nimport os\nimport re\nimport subprocess\nimport sys\nimport time\nimport traceback\n",
        HEADER_RECORD + "import json\nimport os\nimport sys\nimport traceback\n",
        '头部导入',
    )
    text = replace_once(
        text,
        "    config_path = sys.argv[1]\n",
        "    win_api.ensure_utf8_stdout()\n"
        "    config_path = sys.argv[1]\n",
        'main 编码',
    )
    text = replace_once(
        text,
        '\ndef main():',
        '\n' + RECORD_USAGE + RECORD_DRY_RUN + 'def main():',
        '用法说明',
    )
    text = replace_once(
        text,
        "    if len(sys.argv) < 2:\n"
        "        raise RuntimeError('Missing config file path.')\n",
        ARG_VALIDATION, 
        '参数校验',
    )
    # 录制运行器同样支持 --dry-run
    text = replace_once(
        text,
        "    with open(config_path, 'r', encoding='utf-8') as file:\n"
        "        config = json.load(file)\n",
        "    with open(config_path, 'r', encoding='utf-8') as file:\n"
        "        config = json.load(file)\n"
        "    if '--dry-run' in sys.argv[2:]:\n"
        "        raise SystemExit(describe_recorded_flows(config))\n",
        'dry-run 入口',
    )
    return text


FORBIDDEN = ("['adb'", '"adb"', 'sendevent', 'AdbIME', 'adbkeyboard', 'dumpsys')


def assert_clean(text: str, label: str) -> None:
    for forbidden in FORBIDDEN:
        if forbidden in text:
            raise SystemExit(f'{label} 里仍残留 Android 专有实现: {forbidden}')


def main() -> int:
    check_only = '--check' in sys.argv[1:]
    flow_raw, record_raw = read_embedded_scripts()

    flow = build_flow_runner(flow_raw)
    record = build_record_runner(record_raw)

    assert_clean(flow, 'flow_runner_win.py')
    assert_clean(record, 'record_runner_win.py')

    if check_only:
        stale = []
        for path, content in ((OUT_FLOW, flow), (OUT_RECORD, record)):
            current = open(path, encoding='utf-8').read() if os.path.exists(path) else ''
            if current != content:
                stale.append(os.path.basename(path))
        if stale:
            print('运行器与 lib/main.dart 不同步: ' + ', '.join(stale))
            return 1
        print('运行器与 lib/main.dart 同步')
        return 0

    with open(OUT_FLOW, 'w', encoding='utf-8') as file:
        file.write(flow)
    with open(OUT_RECORD, 'w', encoding='utf-8') as file:
        file.write(record)
    print(f'写出 {OUT_FLOW} ({flow.count(chr(10))} 行)')
    print(f'写出 {OUT_RECORD} ({record.count(chr(10))} 行)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
