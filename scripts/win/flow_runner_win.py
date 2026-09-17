"""时空客户端（Windows）自定义流程执行器。

由 Flutter 侧写出配置文件（deviceIds/steps/imagePaths/recordedFlows/loopCount…）后
以 `python flow_runner_win.py <config.json>` 方式启动。流程语义与旧模拟器版完全一致，
区别只在于底层由 adb 换成了 Windows 窗口设备层（scripts/win/win_device.py）。

本文件由 scripts/win/build_win_runners.py 依据 lib/main.dart 内嵌的旧版运行器生成，
请勿手改：改动请落在生成器里，然后重新执行生成脚本。
"""

import json
import math
import os
import random
import re
import signal
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor

import cv2
import numpy as np

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

_template_cache = {}
_ocr_engine = None
_ocr_engine_lock = threading.Lock()
_shutdown_schedule_lock = threading.Lock()
_shutdown_scheduled = False
_mac_shutdown_pid_file = os.path.join(
    tempfile.gettempdir(),
    'py_auto_custom_flow_shutdown.pid',
)
_pointer_slot = 0
_tracking_id = 1
_device_screen_size_cache = {}


class SerialDeviceCoordinator:
    def __init__(self, device_ids):
        self._device_ids = [str(item).strip() for item in device_ids if str(item).strip()]
        self._active_device_ids = set(self._device_ids)
        self._next_index = 0
        self._condition = threading.Condition()
        self._owner_device_id = None
        self._owner_depth = 0

    def _advance_locked(self):
        if not self._active_device_ids or not self._device_ids:
            return
        for offset in range(len(self._device_ids)):
            index = (self._next_index + offset) % len(self._device_ids)
            if self._device_ids[index] in self._active_device_ids:
                self._next_index = index
                return

    def run_turn(self, device_id, callback, label=''):
        with self._condition:
            self._advance_locked()
            while (
                device_id in self._active_device_ids
                and self._active_device_ids
                and (
                    self._owner_device_id is not None
                    or self._device_ids[self._next_index] != device_id
                )
            ):
                self._condition.wait()
                self._advance_locked()
            if device_id not in self._active_device_ids:
                return None
            self._owner_device_id = device_id
            self._owner_depth = 1
            if label:
                print(f'[{device_id}] 串行轮次开始: {label}')
        try:
            return callback()
        finally:
            with self._condition:
                if self._owner_device_id == device_id:
                    self._owner_depth = 0
                    self._owner_device_id = None
                    if device_id in self._device_ids:
                        self._next_index = (self._device_ids.index(device_id) + 1) % len(self._device_ids)
                    self._advance_locked()
                    self._condition.notify_all()

    def is_owner(self, device_id):
        with self._condition:
            return self._owner_device_id == device_id

    def run_nested(self, device_id, callback):
        """让当前设备暂时让出轮次，执行递归子步骤后再恢复。"""
        with self._condition:
            if self._owner_device_id != device_id:
                return callback()
            self._owner_device_id = None
            self._owner_depth = 0
            if device_id in self._device_ids:
                self._next_index = (self._device_ids.index(device_id) + 1) % len(self._device_ids)
            self._advance_locked()
            self._condition.notify_all()
        try:
            return callback()
        finally:
            # 子步骤完成后，当前设备必须重新排队，不能直接抢回轮次。
            self.run_turn(device_id, lambda: None, label='恢复父步骤轮次')

    def finish(self, device_id):
        with self._condition:
            self._active_device_ids.discard(device_id)
            self._advance_locked()
            self._condition.notify_all()


def load_image_file(image_path):
    try:
        data = np.fromfile(image_path, dtype=np.uint8)
    except Exception:
        data = None
    if data is not None and data.size > 0:
        image = cv2.imdecode(data, cv2.IMREAD_COLOR)
        if image is not None:
            return image
    return cv2.imread(image_path)


def load_template(template_path):
    template = _template_cache.get(template_path)
    if template is None:
        template = load_image_file(template_path)
        if template is None:
            raise RuntimeError(f'无法加载模板图片: {template_path}')
        _template_cache[template_path] = template
    return template


def get_branch_screenshot_path(runtime_context):
    if not isinstance(runtime_context, dict):
        return None
    branch_screenshot_path = runtime_context.get('branchScreenshotPath')
    if not isinstance(branch_screenshot_path, str):
        return None
    branch_screenshot_path = branch_screenshot_path.strip()
    return branch_screenshot_path or None


def persist_branch_screenshot(screenshot_path):
    screenshot_dir = os.path.dirname(screenshot_path) or None
    fd, branch_screenshot_path = tempfile.mkstemp(
        prefix='custom_flow_branch_',
        suffix='.png',
        dir=screenshot_dir,
    )
    os.close(fd)
    shutil.copy2(screenshot_path, branch_screenshot_path)
    return branch_screenshot_path


def build_branch_child_context(runtime_context, branch_screenshot_path):
    child_context = dict(runtime_context or {})
    if branch_screenshot_path:
        child_context['branchScreenshotPath'] = branch_screenshot_path
    return child_context


def adb_screenshot(device_id, output_path):
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

def sleep_random(min_ms, max_ms):
    low = min(float(min_ms), float(max_ms))
    high = max(float(min_ms), float(max_ms))
    wait_seconds = random.uniform(low, high) if high > low else low
    if wait_seconds > 0:
        time.sleep(wait_seconds)
    return wait_seconds


def choose_wait_seconds(min_seconds, max_seconds):
    low = min(float(min_seconds), float(max_seconds))
    high = max(float(min_seconds), float(max_seconds))
    return random.uniform(low, high) if high > low else low


def get_step_seconds(step, seconds_key, legacy_ms_key, default=0):
    if seconds_key in step:
        return max(float(step.get(seconds_key, default) or 0), 0.0)
    legacy_value = step.get(legacy_ms_key, None)
    if legacy_value is None:
        return max(float(default), 0.0)
    return max(float(legacy_value) / 1000.0, 0.0)


def format_seconds(value):
    normalized = float(value)
    if normalized.is_integer():
        return str(int(normalized))
    return f'{normalized:.3f}'.rstrip('0').rstrip('.')


def format_clock(value):
    total_seconds = max(int(value), 0)
    hours, remainder = divmod(total_seconds, 3600)
    minutes, seconds = divmod(remainder, 60)
    if hours > 0:
        return f'{hours:02d}:{minutes:02d}:{seconds:02d}'
    return f'{minutes:02d}:{seconds:02d}'


def sleep_with_countdown(device_id, label, wait_seconds):
    wait_seconds = max(float(wait_seconds), 0.0)
    if wait_seconds <= 0:
        print(f'[{device_id}] [{label}] 倒计时 00:00')
        return 0.0
    end_time = time.time() + wait_seconds
    last_remaining = None
    while True:
        remaining = max(end_time - time.time(), 0.0)
        remaining_seconds = int(math.ceil(remaining))
        if remaining_seconds != last_remaining:
            sys.stdout.write(
                f'\r[{device_id}] [{label}] 倒计时 {format_clock(remaining_seconds)}'
            )
            sys.stdout.flush()
            last_remaining = remaining_seconds
        if remaining <= 0:
            break
        time.sleep(min(0.2, remaining))
    sys.stdout.write(f'\r[{device_id}] [{label}] 倒计时 {format_clock(0)}\n')
    sys.stdout.flush()
    return wait_seconds


def step_label(step, fallback):
    label = (step.get('label', '') or '').strip()
    return label or fallback


def print_log_separator(device_id, label, detail=''):
    suffix = f' {detail}' if detail else ''
    print(f'[{device_id}] ----- {label} 完成{suffix} -----')


def image_display_name(step, template_path):
    template_name = (step.get('templateName', '') or '').strip()
    if template_name:
        return template_name
    return os.path.basename(template_path) or template_path


_tap_min_x = 4
_tap_min_y = 4
_tap_max_x = 1598
_tap_max_y = 898


def clamp_tap_point(x, y, screen_size=None):
    raw_x = int(x)
    raw_y = int(y)
    if screen_size and screen_size[0] > 0 and screen_size[1] > 0:
        max_x = max(int(screen_size[0]) - 2, 0)
        max_y = max(int(screen_size[1]) - 2, 0)
        min_x = _tap_min_x if max_x >= _tap_min_x else 0
        min_y = _tap_min_y if max_y >= _tap_min_y else 0
    else:
        max_x = _tap_max_x
        max_y = _tap_max_y
        min_x = _tap_min_x
        min_y = _tap_min_y
    clamped_x = min(max(raw_x, min_x), max_x)
    clamped_y = min(max(raw_y, min_y), max_y)
    return raw_x, raw_y, clamped_x, clamped_y


def get_device_screen_size(device_id):
    """Windows 版：返回设计分辨率（截图与坐标都统一在这个空间里）。"""
    cached = _device_screen_size_cache.get(device_id)
    if cached:
        return cached
    device = require_device(device_id)
    backend = get_backend()
    screen_size = (int(device.capture_width), int(device.capture_height)) \
        if device.is_child_capture else backend.design_size
    screen_size = backend.design_size
    _device_screen_size_cache[device_id] = screen_size
    return screen_size

def recorded_flow_screen_size(flow):
    width = int(flow.get('screenWidth', 0) or 0)
    height = int(flow.get('screenHeight', 0) or 0)
    if width > 0 and height > 0:
        return width, height
    return None


def scale_recorded_point(x, y, source_size, target_size):
    raw_x = int(x)
    raw_y = int(y)
    if (
        source_size
        and target_size
        and source_size[0] > 0
        and source_size[1] > 0
        and target_size[0] > 0
        and target_size[1] > 0
    ):
        raw_x = round(raw_x / source_size[0] * target_size[0])
        raw_y = round(raw_y / source_size[1] * target_size[1])
    return clamp_tap_point(raw_x, raw_y, target_size)


def tap(device_id, x, y):
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

# Windows 版没有 adb shell / ADB Keyboard：文本输入由设备层直接完成，
# 相关函数（adb_shell / adb_command_error / 各种 ime 检测）已整体移除。


def flow_contains_paste_text(steps):
    for step in steps:
        if step.get('type') == 'pasteText':
            return True
        if flow_contains_paste_text(step.get('children', [])):
            return True
        if flow_contains_paste_text(step.get('fallbackChildren', [])):
            return True
        for branch_case in step.get('branchCases', []):
            if flow_contains_paste_text(branch_case.get('steps', [])):
                return True
    return False


def flow_contains_paste_text_for_device(steps, device_id, runtime_context):
    for step in steps:
        if not step_applies_to_device(step, device_id, runtime_context):
            continue
        if step.get('type') == 'pasteText':
            return True
        if flow_contains_paste_text_for_device(
            step.get('children', []), device_id, runtime_context
        ):
            return True
        if flow_contains_paste_text_for_device(
            step.get('fallbackChildren', []), device_id, runtime_context
        ):
            return True
        for branch_case in step.get('branchCases', []):
            if flow_contains_paste_text_for_device(
                branch_case.get('steps', []), device_id, runtime_context
            ):
                return True
    return False


def prepare_text_input(device_id):
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


def split_text_lines(text):
    return [
        line.strip()
        for line in str(text or '').splitlines()
        if line.strip()
    ]


def find_template(screen, template_path, confidence):
    template = load_template(template_path)
    result = cv2.matchTemplate(screen, template, cv2.TM_CCOEFF_NORMED)
    _, max_val, _, max_loc = cv2.minMaxLoc(result)
    if max_val < confidence:
        return None
    h, w = template.shape[:2]
    return max_loc[0] + w // 2, max_loc[1] + h // 2, max_val


def get_ocr_engine():
    global _ocr_engine
    if _ocr_engine is not None:
        return _ocr_engine
    with _ocr_engine_lock:
        if _ocr_engine is not None:
            return _ocr_engine
        try:
            from rapidocr import RapidOCR
        except Exception as error:
            raise RuntimeError(
                '未安装 RapidOCR。请先执行: python -m pip install rapidocr onnxruntime'
            ) from error
        _ocr_engine = RapidOCR()
        return _ocr_engine


def read_result_field(result, field_name):
    if result is None:
        return None
    if isinstance(result, dict):
        return result.get(field_name)
    return getattr(result, field_name, None)


def normalize_ocr_output(result):
    boxes = read_result_field(result, 'boxes')
    txts = read_result_field(result, 'txts')
    scores = read_result_field(result, 'scores')
    if boxes is not None and txts is not None:
        return [
            {'box': box, 'text': text, 'score': scores[index] if scores is not None and index < len(scores) else None}
            for index, (box, text) in enumerate(zip(boxes, txts))
        ]

    if not isinstance(result, (list, tuple)):
        return []
    first_item = result[0] if result else None
    first_item_is_entry = isinstance(first_item, dict) or (
        isinstance(first_item, (list, tuple))
        and len(first_item) >= 2
        and (
            isinstance(first_item[1], str)
            or (
                isinstance(first_item[1], (list, tuple))
                and len(first_item[1]) > 0
                and isinstance(first_item[1][0], str)
            )
        )
    )
    if len(result) == 3 and not first_item_is_entry:
        boxes, txts, scores = result
        return [
            {'box': box, 'text': text, 'score': scores[index] if scores is not None and index < len(scores) else None}
            for index, (box, text) in enumerate(zip(boxes or [], txts or []))
        ]

    entries = []
    for item in result:
        if isinstance(item, dict):
            entries.append({
                'box': item.get('box') or item.get('points') or item.get('dt_box'),
                'text': item.get('text') or item.get('txt') or item.get('rec_text') or '',
                'score': item.get('score') or item.get('confidence') or item.get('rec_score'),
            })
            continue
        if not isinstance(item, (list, tuple)) or len(item) < 2:
            continue
        box = item[0]
        text = ''
        score = None
        if len(item) >= 3:
            text = item[1]
            score = item[2]
        elif isinstance(item[1], (list, tuple)) and item[1]:
            text = item[1][0]
            score = item[1][1] if len(item[1]) > 1 else None
        entries.append({'box': box, 'text': text, 'score': score})
    return entries


def ocr_box_center(box):
    try:
        points = np.asarray(box, dtype=float).reshape(-1, 2)
    except Exception:
        return None
    if points.size == 0:
        return None
    return int(round(float(points[:, 0].mean()))), int(round(float(points[:, 1].mean())))


def normalize_text_for_ocr_match(value):
    return re.sub(r'\s+', '', str(value or '')).lower()


def ocr_text_matches(text, target_text, match_mode):
    if match_mode == 'regex':
        return re.search(target_text, str(text or '')) is not None
    normalized_text = normalize_text_for_ocr_match(text)
    normalized_target = normalize_text_for_ocr_match(target_text)
    if match_mode == 'exact':
        return normalized_text == normalized_target
    return normalized_target in normalized_text


def crop_ocr_region(screen, step):
    height, width = screen.shape[:2]
    def read_region_value(key):
        value = step.get(key, -1)
        if value is None or value == '':
            return -1
        return int(value)
    left = read_region_value('ocrRegionLeft')
    top = read_region_value('ocrRegionTop')
    right = read_region_value('ocrRegionRight')
    bottom = read_region_value('ocrRegionBottom')
    if left < 0 or top < 0 or right <= left or bottom <= top:
        return screen, 0, 0, '全屏'
    clamped_left = min(max(left, 0), width)
    clamped_top = min(max(top, 0), height)
    clamped_right = min(max(right, 0), width)
    clamped_bottom = min(max(bottom, 0), height)
    if clamped_right <= clamped_left or clamped_bottom <= clamped_top:
        raise RuntimeError(
            f'OCR 识别区域超出屏幕或无效: ({left}, {top})-({right}, {bottom})'
        )
    return (
        screen[clamped_top:clamped_bottom, clamped_left:clamped_right],
        clamped_left,
        clamped_top,
        f'({clamped_left}, {clamped_top})-({clamped_right}, {clamped_bottom})',
    )


def find_ocr_matches(screen, step):
    target_text = str(step.get('ocrTargetText', '') or '').strip()
    if not target_text:
        raise RuntimeError('识图文字识别模式缺少目标文字')
    match_mode = step.get('ocrMatchMode', 'contains')
    if match_mode not in ('contains', 'exact', 'regex'):
        match_mode = 'contains'
    confidence = float(step.get('confidence', 0.50))
    ocr_image, offset_x, offset_y, region_text = crop_ocr_region(screen, step)
    engine = get_ocr_engine()
    with _ocr_engine_lock:
        result = engine(ocr_image)
    matches = []
    for entry in normalize_ocr_output(result):
        text = str(entry.get('text', '') or '')
        raw_score = entry.get('score', None)
        score = 1.0 if raw_score is None else float(raw_score)
        if score < confidence:
            continue
        center = ocr_box_center(entry.get('box'))
        if center is None:
            continue
        try:
            matched = ocr_text_matches(text, target_text, match_mode)
        except re.error as error:
            raise RuntimeError(f'OCR 正则表达式不正确: {target_text}, {error}') from error
        if not matched:
            continue
        matches.append({
            'x': center[0] + offset_x,
            'y': center[1] + offset_y,
            'text': text,
            'score': score,
            'region': region_text,
        })
    matches.sort(key=lambda item: (item['y'], item['x']))
    return matches


def position_branch_case_matches(branch_case, center_x, center_y):
    x_min = branch_case.get('centerXMin', None)
    x_max = branch_case.get('centerXMax', None)
    y_min = branch_case.get('centerYMin', None)
    y_max = branch_case.get('centerYMax', None)
    if x_min is not None and float(center_x) < float(x_min):
        return False
    if x_max is not None and float(center_x) > float(x_max):
        return False
    if y_min is not None and float(center_y) < float(y_min):
        return False
    if y_max is not None and float(center_y) > float(y_max):
        return False
    return True


def image_path_for(item, image_paths):
    template_path = image_paths.get(item.get('id', ''))
    if not template_path or not os.path.exists(template_path):
        raise RuntimeError(f"模板图片不存在: {item.get('templateName', '') or template_path}")
    return template_path


def template_images_for_branch_case(branch_case):
    template_images = branch_case.get('templateImages', [])
    if isinstance(template_images, list) and template_images:
        return template_images
    return [branch_case]


def detect_current_activity(device_id):
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


def schedule_desktop_shutdown(delay_seconds):
    delay_seconds = max(int(float(delay_seconds or 0)), 0)
    if sys.platform.startswith('win'):
        result = subprocess.run(
            ['shutdown', '/s', '/t', str(delay_seconds)],
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            details = '\n'.join(
                part for part in [(result.stdout or '').strip(), (result.stderr or '').strip()] if part
            )
            raise RuntimeError(details or 'Windows 关机任务创建失败')
        return f'Windows 已设置 {delay_seconds} 秒后关机'
    if sys.platform == 'darwin':
        try:
            if os.path.exists(_mac_shutdown_pid_file):
                with open(_mac_shutdown_pid_file, 'r', encoding='utf-8') as file:
                    existing_pid = int((file.read() or '').strip())
                if existing_pid > 0:
                    try:
                        os.killpg(existing_pid, signal.SIGTERM)
                    except OSError:
                        pass
                os.remove(_mac_shutdown_pid_file)
        except Exception:
            pass
        shell_command = (
            f"sleep {delay_seconds}; "
            "osascript -e 'tell application "
            '"System Events"'
            " to shut down'; "
            f"rm -f '{_mac_shutdown_pid_file}'"
        )
        process = subprocess.Popen(
            ['/bin/sh', '-c', shell_command],
            start_new_session=True,
        )
        with open(_mac_shutdown_pid_file, 'w', encoding='utf-8') as file:
            file.write(str(process.pid))
        return f'macOS 已设置 {delay_seconds} 秒后关机'
    raise RuntimeError('当前平台不支持桌面关机')


def run_shutdown_step(device_id, step):
    global _shutdown_scheduled
    label = step_label(step, '关机操作')
    delay_seconds = max(float(step.get('shutdownDelaySeconds', 60) or 0), 0.0)
    with _shutdown_schedule_lock:
        if _shutdown_scheduled:
            print(f'[{device_id}] [{label}] 已有桌面关机任务，本次跳过重复设置')
            return
        message = schedule_desktop_shutdown(delay_seconds)
        _shutdown_scheduled = True
    print(f'[{device_id}] [{label}] {message}')


def run_image_tap(device_id, step, image_paths, screenshot_path):
    if step.get('recognitionMode', 'image') == 'text':
        run_ocr_tap(device_id, step, screenshot_path)
        return
    template_path = image_path_for(step, image_paths)
    template_name = image_display_name(step, template_path)
    label = step_label(step, '识图点击')
    max_attempts = max(int(step.get('maxAttempts', 1)), 1)
    retry_interval_seconds = get_step_seconds(step, 'retryIntervalSeconds', 'retryIntervalMs')
    confidence = float(step.get('confidence', 0.68))
    random_offset = max(int(step.get('randomOffsetPx', 0)), 0)
    continue_on_failure = bool(step.get('continueOnFailure', False))
    for attempt in range(1, max_attempts + 1):
        print(
            f'[{device_id}] [{label}] 第 {attempt}/{max_attempts} 次识图: {template_name}, '
            f'阈值 {confidence:.2f}, 重试间隔 {format_seconds(retry_interval_seconds)}s'
        )
        screen = adb_screenshot(device_id, screenshot_path)
        found = find_template(screen, template_path, confidence)
        if found is not None:
            raw_x, raw_y, score = found
            x, y = raw_x, raw_y
            if random_offset > 0:
                x += random.randint(-random_offset, random_offset)
                y += random.randint(-random_offset, random_offset)
                print(
                    f'[{device_id}] [{label}] 识图成功: {template_name}, 置信度 {score:.3f}, '
                    f'原始坐标 ({raw_x}, {raw_y}), 随机偏移后点击 ({x}, {y})'
                )
            else:
                print(
                    f'[{device_id}] [{label}] 识图成功: {template_name}, 置信度 {score:.3f}, '
                    f'点击坐标 ({x}, {y})'
                )
            tap(device_id, x, y)
            post_wait_min_seconds = get_step_seconds(step, 'postWaitMinSeconds', 'postWaitMinMs')
            post_wait_max_seconds = get_step_seconds(step, 'postWaitMaxSeconds', 'postWaitMaxMs')
            post_wait_seconds = choose_wait_seconds(post_wait_min_seconds, post_wait_max_seconds)
            print(
                f'[{device_id}] [{label}] 点击完成，开始等待 '
                f'{format_seconds(post_wait_min_seconds)}-{format_seconds(post_wait_max_seconds)}s，'
                f'本次 {format_seconds(post_wait_seconds)}s'
            )
            sleep_with_countdown(
                device_id,
                label,
                post_wait_seconds,
            )
            return
        if attempt < max_attempts and retry_interval_seconds > 0:
            print(
                f'[{device_id}] [{label}] 未命中图片: {template_name}，'
                f'{format_seconds(retry_interval_seconds)}s 后重试'
            )
            time.sleep(retry_interval_seconds)
    if continue_on_failure:
        print(f'[{device_id}] [{label}] 未命中图片，继续后续步骤: {template_name}')
        return
    raise RuntimeError(f'步骤执行失败，未找到图片: {template_name}')


def run_ocr_tap(device_id, step, screenshot_path):
    label = step_label(step, '识图点击（文字识别）')
    target_text = str(step.get('ocrTargetText', '') or '').strip()
    if not target_text:
        raise RuntimeError('识图文字识别模式缺少目标文字')
    max_attempts = max(int(step.get('maxAttempts', 1)), 1)
    retry_interval_seconds = get_step_seconds(step, 'retryIntervalSeconds', 'retryIntervalMs')
    random_offset = max(int(step.get('randomOffsetPx', 0)), 0)
    continue_on_failure = bool(step.get('continueOnFailure', False))
    match_index = max(int(step.get('ocrMatchIndex', 1) or 1), 1)
    click_offset_x = int(step.get('ocrClickOffsetX', 0) or 0)
    click_offset_y = int(step.get('ocrClickOffsetY', 0) or 0)
    confidence = float(step.get('confidence', 0.50))
    match_mode = step.get('ocrMatchMode', 'contains')

    for attempt in range(1, max_attempts + 1):
        print(
            f'[{device_id}] [{label}] 第 {attempt}/{max_attempts} 次文字识别: '
            f'目标“{target_text}”，模式 {match_mode}, 阈值 {confidence:.2f}, '
            f'点击第 {match_index} 个命中'
        )
        screen = adb_screenshot(device_id, screenshot_path)
        matches = find_ocr_matches(screen, step)
        if len(matches) >= match_index:
            match = matches[match_index - 1]
            raw_x = int(match['x']) + click_offset_x
            raw_y = int(match['y']) + click_offset_y
            x, y = raw_x, raw_y
            if random_offset > 0:
                x += random.randint(-random_offset, random_offset)
                y += random.randint(-random_offset, random_offset)
            print(
                f'[{device_id}] [{label}] 文字识别成功: “{match["text"]}”, '
                f'置信度 {match["score"]:.3f}, 区域 {match["region"]}, '
                f'基础坐标 ({raw_x}, {raw_y}), 点击坐标 ({x}, {y})'
            )
            tap(device_id, x, y)
            post_wait_min_seconds = get_step_seconds(step, 'postWaitMinSeconds', 'postWaitMinMs')
            post_wait_max_seconds = get_step_seconds(step, 'postWaitMaxSeconds', 'postWaitMaxMs')
            post_wait_seconds = choose_wait_seconds(post_wait_min_seconds, post_wait_max_seconds)
            print(
                f'[{device_id}] [{label}] 点击完成，开始等待 '
                f'{format_seconds(post_wait_min_seconds)}-{format_seconds(post_wait_max_seconds)}s，'
                f'本次 {format_seconds(post_wait_seconds)}s'
            )
            sleep_with_countdown(
                device_id,
                label,
                post_wait_seconds,
            )
            return
        print(
            f'[{device_id}] [{label}] 未命中文字“{target_text}”，'
            f'当前命中数 {len(matches)}，需要第 {match_index} 个'
        )
        if attempt < max_attempts and retry_interval_seconds > 0:
            print(
                f'[{device_id}] [{label}] {format_seconds(retry_interval_seconds)}s 后重试'
            )
            time.sleep(retry_interval_seconds)
    if continue_on_failure:
        print(f'[{device_id}] [{label}] 未命中文字，继续后续步骤: {target_text}')
        return
    raise RuntimeError(f'步骤执行失败，未找到文字: {target_text}')


def run_wait_ocr_state(device_id, step, screenshot_path):
    label = step_label(step, '文字识别等待')
    target_text = str(step.get('ocrTargetText', '') or '').strip()
    if not target_text:
        raise RuntimeError('文字识别等待缺少目标文字')
    timeout_seconds = get_step_seconds(step, 'timeoutSeconds', 'timeoutMs')
    poll_interval_seconds = get_step_seconds(step, 'pollIntervalSeconds', 'pollIntervalMs')
    wait_target_state = step.get('waitTargetState', 'appear')
    continue_on_failure = bool(step.get('continueOnFailure', False))
    start_time = time.time()
    target_state_text = '出现' if wait_target_state == 'appear' else '消失'
    print(
        f'[{device_id}] [{label}] 开始等待文字{target_state_text}: {target_text}, '
        f'轮询间隔 {format_seconds(poll_interval_seconds)}s, '
        f'超时 {("无限" if timeout_seconds <= 0 else f"{format_seconds(timeout_seconds)}s")}'
    )
    while True:
        screen = adb_screenshot(device_id, screenshot_path)
        matches = find_ocr_matches(screen, step)
        found = bool(matches)
        matched = found if wait_target_state == 'appear' else not found
        elapsed_seconds = time.time() - start_time
        print(
            f'[{device_id}] [{label}] 判断结果: 文字当前{"已出现" if found else "未出现"}, '
            f'目标为{target_state_text}, 本次{"命中" if matched else "未命中"}, '
            f'已等待 {format_seconds(elapsed_seconds)}s'
        )
        if matched:
            print(f'[{device_id}] [{label}] 文字识别等待完成: {target_text}, 条件 {wait_target_state}')
            return
        if timeout_seconds > 0 and (time.time() - start_time) >= timeout_seconds:
            if continue_on_failure:
                print(f'[{device_id}] [{label}] 文字识别等待超时，继续后续步骤: {target_text}')
                return
            raise RuntimeError(f'文字识别等待超时: {target_text}')
        if poll_interval_seconds > 0:
            time.sleep(poll_interval_seconds)


def run_wait_image_state(device_id, step, image_paths, screenshot_path):
    if step.get('recognitionMode', 'image') == 'text':
        run_wait_ocr_state(device_id, step, screenshot_path)
        return
    template_path = image_path_for(step, image_paths)
    template_name = image_display_name(step, template_path)
    label = step_label(step, '识图等待')
    confidence = float(step.get('confidence', 0.68))
    timeout_seconds = get_step_seconds(step, 'timeoutSeconds', 'timeoutMs')
    poll_interval_seconds = get_step_seconds(step, 'pollIntervalSeconds', 'pollIntervalMs')
    wait_target_state = step.get('waitTargetState', 'appear')
    continue_on_failure = bool(step.get('continueOnFailure', False))
    start_time = time.time()
    target_text = '出现' if wait_target_state == 'appear' else '消失'
    print(
        f'[{device_id}] [{label}] 开始等待图片{target_text}: {template_name}, '
        f'阈值 {confidence:.2f}, 轮询间隔 {format_seconds(poll_interval_seconds)}s, '
        f'超时 {("无限" if timeout_seconds <= 0 else f"{format_seconds(timeout_seconds)}s")}'
    )
    while True:
        screen = adb_screenshot(device_id, screenshot_path)
        found = find_template(screen, template_path, confidence) is not None
        matched = found if wait_target_state == 'appear' else not found
        elapsed_seconds = time.time() - start_time
        print(
            f'[{device_id}] [{label}] 判断结果: 图片当前{"已出现" if found else "未出现"}，'
            f'目标为{target_text}，本次{"命中" if matched else "未命中"}，'
            f'已等待 {format_seconds(elapsed_seconds)}s'
        )
        if matched:
            print(f'[{device_id}] [{label}] 识图等待完成: {template_name}, 条件 {wait_target_state}')
            return
        if timeout_seconds > 0 and (time.time() - start_time) >= timeout_seconds:
            if continue_on_failure:
                print(f'[{device_id}] [{label}] 识图等待超时，继续后续步骤: {template_name}')
                return
            raise RuntimeError(f'识图等待超时: {template_name}')
        if poll_interval_seconds > 0:
            time.sleep(poll_interval_seconds)


def run_image_position_branch(
    device_id,
    step,
    image_paths,
    screenshot_path,
    work_dir,
    runtime_context=None,
):
    runtime_context = dict(runtime_context or {})
    reuse_parent_branch_screenshot = bool(
        step.get('reuseParentBranchScreenshot', False)
    )
    branch_screenshot_path = get_branch_screenshot_path(runtime_context)
    if step.get('recognitionMode', 'image') == 'text':
        label = step_label(step, '文字识别坐标分支')
        if reuse_parent_branch_screenshot and branch_screenshot_path:
            screen = load_image_file(branch_screenshot_path)
            if screen is None:
                raise RuntimeError(
                    f'无法读取可复用的分支截图: {branch_screenshot_path}'
                )
        else:
            screen = adb_screenshot(device_id, screenshot_path)
            branch_screenshot_path = persist_branch_screenshot(screenshot_path)
        branch_context = build_branch_child_context(
            runtime_context,
            branch_screenshot_path,
        )
        match_index = max(int(step.get('ocrMatchIndex', 1) or 1), 1)
        matches = find_ocr_matches(screen, step)
        if len(matches) < match_index:
            print(f'[{device_id}] [{label}] 未命中文字，执行默认分支: {step.get("ocrTargetText", "")}')
            execute_steps(
                device_id,
                step.get('fallbackChildren', []),
                image_paths,
                work_dir,
                branch_context,
            )
            return
        match = matches[match_index - 1]
        center_x = int(match['x'])
        center_y = int(match['y'])
        score = float(match['score'])
        matched_name = str(match.get('text', '') or step.get('ocrTargetText', ''))
        print(
            f'[{device_id}] [{label}] 文字识别成功: {matched_name}, '
            f'置信度 {score:.3f}, 中心点 ({center_x}, {center_y})'
        )
        matched = False
        branch_cases = step.get('branchCases', [])
        for index, branch_case in enumerate(branch_cases, start=1):
            branch_label = step_label(branch_case, f'分支{index}')
            condition_result = position_branch_case_matches(branch_case, center_x, center_y)
            print(
                f'[{device_id}] [{label}] 判断条件 {index}: {branch_label}, '
                f'结果 {"命中" if condition_result else "未命中"}'
            )
            if condition_result:
                matched = True
                print(f'[{device_id}] [{label}] 执行分支: {branch_label}')
                child_context = build_branch_child_context(
                    branch_context,
                    branch_screenshot_path,
                )
                child_context['matchedPositionCenter'] = {
                    'x': int(center_x),
                    'y': int(center_y),
                    'score': float(score),
                    'templateName': matched_name,
                }
                execute_steps(
                    device_id,
                    branch_case.get('steps', []),
                    image_paths,
                    work_dir,
                    child_context,
                )
                break
        if not matched:
            print(f'[{device_id}] [{label}] 坐标条件均未命中，执行默认分支')
            execute_steps(
                device_id,
                step.get('fallbackChildren', []),
                image_paths,
                work_dir,
                branch_context,
            )
        return
    template_path = image_path_for(step, image_paths)
    template_name = image_display_name(step, template_path)
    label = step_label(step, '识图坐标分支')
    confidence = float(step.get('confidence', 0.68))
    if reuse_parent_branch_screenshot and branch_screenshot_path:
        screen = load_image_file(branch_screenshot_path)
        if screen is None:
            raise RuntimeError(f'无法读取可复用的分支截图: {branch_screenshot_path}')
    else:
        screen = adb_screenshot(device_id, screenshot_path)
        branch_screenshot_path = persist_branch_screenshot(screenshot_path)
    branch_context = build_branch_child_context(
        runtime_context,
        branch_screenshot_path,
    )
    found = find_template(screen, template_path, confidence)
    if found is None:
        print(f'[{device_id}] [{label}] 未命中图片，执行默认分支: {template_name}')
        execute_steps(
            device_id,
            step.get('fallbackChildren', []),
            image_paths,
            work_dir,
            branch_context,
        )
        return
    center_x, center_y, score = found
    print(
        f'[{device_id}] [{label}] 识图成功: {template_name}, '
        f'置信度 {score:.3f}, 中心点 ({center_x}, {center_y})'
    )
    matched = False
    branch_cases = step.get('branchCases', [])
    for index, branch_case in enumerate(branch_cases, start=1):
        branch_label = step_label(branch_case, f'分支{index}')
        condition_result = position_branch_case_matches(branch_case, center_x, center_y)
        print(
            f'[{device_id}] [{label}] 判断条件 {index}: {branch_label}, '
            f'结果 {"命中" if condition_result else "未命中"}'
        )
        if condition_result:
            matched = True
            print(f'[{device_id}] [{label}] 执行分支: {branch_label}')
            child_context = build_branch_child_context(
                branch_context,
                branch_screenshot_path,
            )
            child_context['matchedPositionCenter'] = {
                'x': int(center_x),
                'y': int(center_y),
                'score': float(score),
                'templateName': template_name,
            }
            execute_steps(
                device_id,
                branch_case.get('steps', []),
                image_paths,
                work_dir,
                child_context,
            )
            break
    if not matched:
        print(f'[{device_id}] [{label}] 坐标条件均未命中，执行默认分支')
        execute_steps(
            device_id,
            step.get('fallbackChildren', []),
            image_paths,
            work_dir,
            branch_context,
        )


def should_continue_loop(device_id, step, image_paths, screenshot_path):
    loop_mode = step.get('loopMode', 'fixedCount')
    if loop_mode != 'imageCondition':
        return None
    if step.get('recognitionMode', 'image') == 'text':
        label = step_label(step, '循环块')
        loop_action = step.get('loopImageAction', 'stopOnMatch')
        screen = adb_screenshot(device_id, screenshot_path)
        matched = bool(find_ocr_matches(screen, step))
        if loop_action == 'continueOnMatch':
            should_continue = matched
        else:
            should_continue = not matched
        action_text = '继续循环' if should_continue else '停止循环'
        print(
            f'[{device_id}] [{label}] 循环条件文字识别结果: {step.get("ocrTargetText", "")}, '
            f'本次{"命中" if matched else "未命中"}, 动作: {action_text}'
        )
        return should_continue
    template_path = image_path_for(step, image_paths)
    template_name = image_display_name(step, template_path)
    label = step_label(step, '循环块')
    confidence = float(step.get('confidence', 0.68))
    loop_action = step.get('loopImageAction', 'stopOnMatch')
    screen = adb_screenshot(device_id, screenshot_path)
    matched = find_template(screen, template_path, confidence) is not None
    if loop_action == 'continueOnMatch':
        should_continue = matched
    else:
        should_continue = not matched
    action_text = '继续循环' if should_continue else '停止循环'
    print(
        f'[{device_id}] [{label}] 循环条件识图结果: {template_name}, '
        f'阈值 {confidence:.2f}, 本次{"命中" if matched else "未命中"}，'
        f'动作: {action_text}'
    )
    return should_continue


def run_image_branch(device_id, step, image_paths, screenshot_path, work_dir, runtime_context=None):
    runtime_context = dict(runtime_context or {})
    label = step_label(step, 'multi image branch')
    matched = False
    branch_cases = step.get('branchCases', [])
    reuse_parent_branch_screenshot = bool(
        step.get('reuseParentBranchScreenshot', False)
    )
    branch_screenshot_path = get_branch_screenshot_path(runtime_context)
    branch_screen = None
    if reuse_parent_branch_screenshot:
        if branch_screenshot_path:
            branch_screen = load_image_file(branch_screenshot_path)
            if branch_screen is None:
                raise RuntimeError(
                    f'无法读取可复用的分支截图: {branch_screenshot_path}'
                )
        else:
            branch_screen = adb_screenshot(device_id, screenshot_path)
            branch_screenshot_path = persist_branch_screenshot(screenshot_path)
    print(f'[{device_id}] [{label}] start image branch, conditions={len(branch_cases)}')
    for index, branch_case in enumerate(branch_cases, start=1):
        screen = branch_screen if reuse_parent_branch_screenshot else adb_screenshot(
            device_id,
            screenshot_path,
        )
        branch_label = step_label(branch_case, f'branch{index}')
        branch_confidence = float(branch_case.get('confidence', 0.68))
        if branch_case.get('recognitionMode', 'image') == 'text':
            matches = find_ocr_matches(screen, branch_case)
            branch_result = bool(matches)
            matched_text = str(matches[0].get('text', '') if matches else '')
            matched_score = float(matches[0].get('score', 0.0) if matches else 0.0)
            matched_center_x = int(matches[0].get('x', 0) if matches else 0)
            matched_center_y = int(matches[0].get('y', 0) if matches else 0)
            result_detail = (
                f'matched text={matched_text}, score={matched_score:.3f}'
                if branch_result
                else 'not matched'
            )
            print(
                f'[{device_id}] [{label}] condition {index}: {branch_label}, '
                f'text={branch_case.get("ocrTargetText", "")}, result={result_detail}'
            )
            print_log_separator(device_id, f'{label} condition {index}', result_detail)
            if branch_result:
                matched = True
                print(f'[{device_id}] [{label}] execute branch: {branch_label}')
                if not reuse_parent_branch_screenshot:
                    branch_screenshot_path = persist_branch_screenshot(
                        screenshot_path,
                    )
                child_context = build_branch_child_context(
                    runtime_context,
                    branch_screenshot_path,
                )
                child_context['matchedPositionCenter'] = {
                    'x': int(matched_center_x),
                    'y': int(matched_center_y),
                    'score': float(matched_score),
                    'templateName': matched_text,
                }
                execute_steps(
                    device_id,
                    branch_case.get('steps', []),
                    image_paths,
                    work_dir,
                    child_context,
                )
                break
            continue
        branch_images = template_images_for_branch_case(branch_case)
        print(
            f'[{device_id}] [{label}] condition {index}: {branch_label}, '
            f'images={len(branch_images)}, threshold={branch_confidence:.2f}'
        )
        branch_result = False
        matched_template_name = ''
        matched_score = 0.0
        matched_center_x = 0
        matched_center_y = 0
        for image_index, branch_image in enumerate(branch_images, start=1):
            template_path = image_path_for(branch_image, image_paths)
            branch_template_name = image_display_name(branch_image, template_path)
            found = find_template(screen, template_path, branch_confidence)
            print(
                f'[{device_id}] [{label}] condition {index} image '
                f'{image_index}/{len(branch_images)}: {branch_template_name}, '
                f'result={"matched" if found is not None else "not matched"}'
            )
            if found is not None:
                branch_result = True
                matched_template_name = branch_template_name
                matched_center_x = int(found[0])
                matched_center_y = int(found[1])
                matched_score = float(found[2])
                break
        result_detail = (
            f'matched image={matched_template_name}, score={matched_score:.3f}'
            if branch_result
            else 'not matched'
        )
        print(f'[{device_id}] [{label}] condition {index} result: {result_detail}')
        print_log_separator(device_id, f'{label} condition {index}', result_detail)
        if branch_result:
            matched = True
            print(f'[{device_id}] [{label}] execute branch: {branch_label}')
            if not reuse_parent_branch_screenshot:
                branch_screenshot_path = persist_branch_screenshot(screenshot_path)
            child_context = build_branch_child_context(
                runtime_context,
                branch_screenshot_path,
            )
            child_context['matchedPositionCenter'] = {
                'x': int(matched_center_x),
                'y': int(matched_center_y),
                'score': float(matched_score),
                'templateName': matched_template_name,
            }
            execute_steps(
                device_id,
                branch_case.get('steps', []),
                image_paths,
                work_dir,
                child_context,
            )
            break
    if not matched:
        if branch_cases and not reuse_parent_branch_screenshot:
            branch_screenshot_path = persist_branch_screenshot(screenshot_path)
        print(f'[{device_id}] [{label}] no conditions matched, execute fallback branch')
        fallback_context = build_branch_child_context(
            runtime_context,
            branch_screenshot_path,
        )
        execute_steps(
            device_id,
            step.get('fallbackChildren', []),
            image_paths,
            work_dir,
            fallback_context,
        )
    print_log_separator(device_id, label)


def step_target_device_ids(step, runtime_context):
    device_ids = runtime_context.get('deviceIds', [])
    if not isinstance(device_ids, list):
        device_ids = []
    device_ids = [str(item).strip() for item in device_ids if str(item).strip()]
    scope = str(step.get('deviceScope', 'all') or 'all').strip()
    if scope == 'first':
        return device_ids[:1]
    if scope == 'others':
        return device_ids[1:]
    return device_ids


def step_applies_to_device(step, device_id, runtime_context):
    return device_id in step_target_device_ids(step, runtime_context)


def run_game_mode_step(device_id, step, work_dir, runtime_context=None):
    """时空客户端版本不内置任何游戏任务脚本，此步骤不再支持。"""
    raise RuntimeError(
        '时空客户端版本不支持「痒痒鼠模式」步骤（该步骤对应内置的阴阳师任务脚本）。'
        '请改用「识图点击 / 坐标点击 / 录制流程」等步骤。'
    )


def ensure_replay_ready(device_id, flow):
    """Windows 版：确认窗口可用、必要时把客户区对齐到设计分辨率。"""
    backend = get_backend()
    device = require_device(device_id)
    if device.minimized:
        print(f'[{device_id}] [录制流程] 窗口最小化，正在恢复')
        backend.activate(device_token(device_id))
    return device


def run_recorded_flow_step(device_id, step, runtime_context=None):
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


def execute_steps(device_id, steps, image_paths, work_dir, runtime_context=None):
    runtime_context = dict(runtime_context or {})
    coordinator = runtime_context.get('serialCoordinator')
    if coordinator is None:
        return execute_steps_uncoordinated(
            device_id,
            steps,
            image_paths,
            work_dir,
            runtime_context,
        )

    if coordinator.is_owner(device_id):
        return coordinator.run_nested(
            device_id,
            lambda: execute_steps(
                device_id,
                steps,
                image_paths,
                work_dir,
                runtime_context,
            ),
        )

    for step in steps:
        step_type = step.get('type', 'step') if isinstance(step, dict) else 'step'
        label = step_label(step, step_type)
        coordinator.run_turn(
            device_id,
            lambda current_step=step: execute_steps_uncoordinated(
                device_id,
                [current_step],
                image_paths,
                work_dir,
                runtime_context,
            ),
            label=label,
        )


def execute_steps_uncoordinated(device_id, steps, image_paths, work_dir, runtime_context=None):
    screenshot_path = os.path.join(work_dir, f'{device_id}_custom_flow_screen.png')
    runtime_context = dict(runtime_context or {})
    for step in steps:
        if not step_applies_to_device(step, device_id, runtime_context):
            label = step_label(step, step.get('type', 'step'))
            print(
                f'[{device_id}] [{label}] 按模拟器对象范围跳过 '
                f'（{step.get("deviceScope", "all")}）'
            )
            continue
        step_type = step['type']
        if step_type == 'wait':
            label = step_label(step, '等待')
            wait_min_seconds = get_step_seconds(step, 'waitMinSeconds', 'waitMinMs')
            wait_max_seconds = get_step_seconds(step, 'waitMaxSeconds', 'waitMaxMs')
            wait_seconds = choose_wait_seconds(wait_min_seconds, wait_max_seconds)
            print(
                f'[{device_id}] [{label}] 开始固定等待 '
                f'{format_seconds(wait_min_seconds)}-{format_seconds(wait_max_seconds)}s，'
                f'本次 {format_seconds(wait_seconds)}s'
            )
            sleep_with_countdown(
                device_id,
                label,
                wait_seconds,
            )
            print_log_separator(device_id, label)
        elif step_type == 'imageTap':
            run_image_tap(device_id, step, image_paths, screenshot_path)
            print_log_separator(device_id, step_label(step, '识图点击'))
        elif step_type == 'ocrTap':
            run_ocr_tap(device_id, step, screenshot_path)
            print_log_separator(device_id, step_label(step, '识图点击（文字识别）'))
        elif step_type == 'coordinateTap':
            label = step_label(step, '固定坐标点击')
            use_branch_detected_position = bool(
                step.get('useBranchDetectedPosition', False)
            )
            if use_branch_detected_position:
                matched_position = runtime_context.get('matchedPositionCenter', None)
                if not isinstance(matched_position, dict):
                    raise RuntimeError(
                        '当前固定坐标点击被设置为使用识图坐标分支中心点，但上层没有可用的识图位置'
                    )
                base_x = int(matched_position.get('x', 0))
                base_y = int(matched_position.get('y', 0))
                offset_x = int(step.get('branchPositionOffsetX', 0))
                offset_y = int(step.get('branchPositionOffsetY', 0))
                x = base_x + offset_x
                y = base_y + offset_y
                raw_x, raw_y = x, y
                print(
                    f'[{device_id}] [{label}] 使用识图中心点 ({base_x}, {base_y})，'
                    f'偏移 ({offset_x}, {offset_y})，基础点击坐标 ({raw_x}, {raw_y})'
                )
            else:
                x = int(step.get('x', 0))
                y = int(step.get('y', 0))
                raw_x, raw_y = x, y
            random_offset = max(int(step.get('randomOffsetPx', 0)), 0)
            if random_offset > 0:
                x += random.randint(-random_offset, random_offset)
                y += random.randint(-random_offset, random_offset)
                print(
                    f'[{device_id}] [{label}] 固定坐标点击: 基础坐标 ({raw_x}, {raw_y}), '
                    f'随机偏移后点击 ({x}, {y})'
                )
            else:
                print(f'[{device_id}] [{label}] 固定坐标点击: 点击位置 ({x}, {y})')
            tap(device_id, x, y)
            post_wait_min_seconds = get_step_seconds(step, 'postWaitMinSeconds', 'postWaitMinMs')
            post_wait_max_seconds = get_step_seconds(step, 'postWaitMaxSeconds', 'postWaitMaxMs')
            post_wait_seconds = choose_wait_seconds(post_wait_min_seconds, post_wait_max_seconds)
            print(
                f'[{device_id}] [{label}] 点击完成，开始等待 '
                f'{format_seconds(post_wait_min_seconds)}-{format_seconds(post_wait_max_seconds)}s，'
                f'本次 {format_seconds(post_wait_seconds)}s'
            )
            sleep_with_countdown(
                device_id,
                label,
                post_wait_seconds,
            )
            print_log_separator(device_id, label)
        elif step_type == 'pasteText':
            run_paste_text_step(device_id, step, runtime_context)
            print_log_separator(device_id, step_label(step, '粘贴文字'))
        elif step_type == 'waitImageState':
            run_wait_image_state(device_id, step, image_paths, screenshot_path)
            print_log_separator(device_id, step_label(step, '识图等待'))
        elif step_type == 'loopBlock':
            label = step_label(step, '循环块')
            loop_count = int(step.get('loopCount', 1))
            loop_mode = step.get('loopMode', 'fixedCount')
            if loop_mode == 'textLines':
                text_lines = split_text_lines(step.get('loopTextContent', ''))
                if not text_lines:
                    raise RuntimeError('按文本逐行循环至少需要一行有效文字')
                total = len(text_lines)
                for current, current_text in enumerate(text_lines, start=1):
                    print(
                        f'[{device_id}] [{label}] 开始第 {current}/{total} 次文本循环，'
                        f'当前文字字符数: {len(current_text)}'
                    )
                    child_context = dict(runtime_context)
                    child_context['currentLoopText'] = current_text
                    execute_steps(
                        device_id,
                        step.get('children', []),
                        image_paths,
                        work_dir,
                        child_context,
                    )
                    print(f'[{device_id}] [{label}] 第 {current}/{total} 次文本循环完成')
                    print_log_separator(
                        device_id,
                        label,
                        f'第 {current}/{total} 次文本循环',
                    )
                continue
            current = 0
            while True:
                if loop_mode == 'fixedCount' and loop_count > 0 and current >= loop_count:
                    break
                current += 1
                remaining = (
                    '按识图条件判断'
                    if loop_mode == 'imageCondition'
                    else ('无限' if loop_count <= 0 else str(max(loop_count - current, 0)))
                )
                total = '识图条件' if loop_mode == 'imageCondition' else ('无限' if loop_count <= 0 else str(loop_count))
                print(
                    f'[{device_id}] [{label}] 开始第 {current}/{total} 次循环，'
                    f'剩余 {remaining} 次'
                )
                execute_steps(
                    device_id,
                    step.get('children', []),
                    image_paths,
                    work_dir,
                    runtime_context,
                )
                print(f'[{device_id}] [{label}] 第 {current} 次循环完成')
                print_log_separator(device_id, label, f'第 {current} 次循环')
                if loop_mode == 'imageCondition':
                    if not should_continue_loop(device_id, step, image_paths, screenshot_path):
                        print(f'[{device_id}] [{label}] 达到识图循环停止条件，结束循环')
                        break
        elif step_type == 'flowGroup':
            label = step_label(step, '流程组')
            print(f'[{device_id}] [{label}] 开始执行流程组，子步骤 {len(step.get("children", []))} 个')
            execute_steps(
                device_id,
                step.get('children', []),
                image_paths,
                work_dir,
                runtime_context,
            )
            print_log_separator(device_id, label)
        elif step_type == 'gameMode':
            run_game_mode_step(device_id, step, work_dir, runtime_context)
            print_log_separator(device_id, step_label(step, '执行痒痒鼠模式'))
        elif step_type == 'recordedFlow':
            run_recorded_flow_step(device_id, step, runtime_context)
            print_log_separator(device_id, step_label(step, '执行录制手势流程'))
        elif step_type == 'imageBranch':
            run_image_branch(device_id, step, image_paths, screenshot_path, work_dir, runtime_context)
            continue
        elif step_type == 'imagePositionBranch':
            run_image_position_branch(
                device_id,
                step,
                image_paths,
                screenshot_path,
                work_dir,
                runtime_context,
            )
            print_log_separator(device_id, step_label(step, '识图坐标分支'))
        elif step_type == 'restartActivity':
            label = step_label(step, '重启当前Activity')
            component = (step.get('activityComponent', '') or '').strip()
            if not component:
                component = detect_current_activity(device_id)
            restart_activity(device_id, component)
            print_log_separator(device_id, label)
        elif step_type == 'shutdownComputer':
            run_shutdown_step(device_id, step)
            print_log_separator(device_id, step_label(step, '关机操作'))
        else:
            raise RuntimeError(f'不支持的步骤类型: {step_type}')


def run_device(device_id, steps, image_paths, loop_count, work_dir, runtime_context=None):
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


def _print_usage() -> None:
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
        sep='\n',
    )



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


def main():
    args = sys.argv[1:]
    if not args or args[0] in ('-h', '--help'):
        _print_usage()
        raise SystemExit(0 if args else 2)
    if args[0].startswith('-'):
        print(f'未知选项: {args[0]}', file=sys.stderr)
        _print_usage()
        raise SystemExit(2)
    extra_args = [item for item in args[1:] if item != '--dry-run']
    if extra_args:
        print(f'多余的参数: {extra_args}', file=sys.stderr)
        _print_usage()
        raise SystemExit(2)
    win_api.ensure_utf8_stdout()
    config_path = sys.argv[1]
    with open(config_path, 'r', encoding='utf-8') as file:
        config = json.load(file)
    if '--dry-run' in sys.argv[2:]:
        raise SystemExit(describe_flow_config(config))
    global _mac_shutdown_pid_file
    _mac_shutdown_pid_file = config.get('shutdownPidFilePath', _mac_shutdown_pid_file)
    device_ids = [
        normalize_device_id(item) for item in (config.get('deviceIds', []) or [])
    ]
    device_ids = [item for item in device_ids if item]
    if not device_ids:
        raise RuntimeError('缺少执行设备')
    if device_ids and not config.get('skipDeviceCheck', False):
        for device_id in device_ids:
            require_device(device_id)
    loop_count = int(config.get('loopCount', 1))
    steps = config.get('steps', [])
    image_paths = config.get('imagePaths', {})
    recorded_flows = config.get('recordedFlows', {})
    main_mode_script_path = config.get('mainModeScriptPath', '')
    python_executable = config.get(
        'pythonExecutable',
        'python' if sys.platform.startswith('win') else 'python3',
    )
    work_dir = os.path.dirname(config_path)
    runtime_context = {
        'deviceIds': device_ids,
        'deviceCount': len(device_ids),
        'recordedFlows': recorded_flows,
        'mainModeScriptPath': main_mode_script_path,
        'pythonExecutable': python_executable,
        'stepErrors': {},
    }
    parallel_devices = bool(config.get('parallelDevices', False))
    if not parallel_devices:
        runtime_context['serialCoordinator'] = SerialDeviceCoordinator(device_ids)
    with ThreadPoolExecutor(max_workers=max(1, len(device_ids))) as executor:
        futures = [
            executor.submit(
                run_device,
                device_id,
                steps,
                image_paths,
                loop_count,
                work_dir,
                runtime_context,
            )
            for device_id in device_ids
        ]
        for future in futures:
            future.result()


if __name__ == '__main__':
    main()
