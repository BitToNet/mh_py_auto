"""时空客户端（Windows）录制手势回放器。

由 Flutter 侧写出配置文件（deviceId/flows/loopCount）后
以 `python record_runner_win.py <config.json>` 方式启动。

本文件由 scripts/win/build_win_runners.py 依据 lib/main.dart 内嵌的旧版运行器生成，
请勿手改：改动请落在生成器里，然后重新执行生成脚本。
"""

import json
import os
import sys
import traceback

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

_pointer_slot = 0
_tracking_id = 100
_device_screen_size_cache = {}


def log(message):
    print(message, flush=True)


def get_device_screen_size(device_id):
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
def recorded_flow_screen_size(flow):
    width = int(flow.get('screenWidth', 0) or 0)
    height = int(flow.get('screenHeight', 0) or 0)
    if width > 0 and height > 0:
        return width, height
    return None


def clamp_tap_point(x, y, screen_size=None):
    raw_x = int(x)
    raw_y = int(y)
    if screen_size and screen_size[0] > 0 and screen_size[1] > 0:
        max_x = max(int(screen_size[0]) - 2, 0)
        max_y = max(int(screen_size[1]) - 2, 0)
        min_x = 4 if max_x >= 4 else 0
        min_y = 4 if max_y >= 4 else 0
    else:
        max_x = 1598
        max_y = 898
        min_x = 4
        min_y = 4
    clamped_x = min(max(raw_x, min_x), max_x)
    clamped_y = min(max(raw_y, min_y), max_y)
    return raw_x, raw_y, clamped_x, clamped_y


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


def ensure_replay_ready(device_id, flow):
    """Windows 版：确认窗口可用。"""
    backend = get_backend()
    device = backend.resolve(device_id)
    if device is None:
        raise RuntimeError(f'找不到时空客户端窗口: {device_id}')
    if device.minimized:
        log(f'[{device_id}] window is minimized, restoring')
        backend.activate(device_id)
    return device
def play_flow(device_id, flow, flow_index, flow_count):
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
def _print_usage() -> None:
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
        sep='\n',
    )



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
        raise SystemExit(describe_recorded_flows(config))
    device_id = normalize_device_id(config.get('deviceId', ''))
    if not device_id:
        raise RuntimeError('Missing target device.')
    if not config.get('skipDeviceCheck', False):
        if get_backend().resolve(device_id) is None:
            raise RuntimeError(f'找不到时空客户端窗口: {device_id}')
    loop_count = int(config.get('loopCount', 1) or 0)
    flows = config.get('flows', [])
    if not isinstance(flows, list) or not flows:
        raise RuntimeError('No recorded flows to replay.')

    log(f'[{device_id}] recorded flow playback started')
    log(f'[{device_id}] flow count={len(flows)}, loop count={"infinite" if loop_count <= 0 else loop_count}')
    current_loop = 0
    while loop_count <= 0 or current_loop < loop_count:
        current_loop += 1
        log(f'[{device_id}] queue loop {current_loop} started')
        for flow_index, flow in enumerate(flows, start=1):
            play_flow(device_id, flow, flow_index, len(flows))
        log(f'[{device_id}] queue loop {current_loop} completed')
    log(f'[{device_id}] recorded flow playback completed')


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        log('Playback cancelled by terminal close or keyboard interrupt.')
        raise
    except Exception:
        traceback.print_exc()
        raise
