import 'recording_flow.dart';

/// 录制流程的编辑期提示。
///
/// 规则与回放侧对齐（`scripts/win/record_runner_win.py` 的自检 +
/// `win_replay.build_replay_plan`）：
/// - 原始指针事件（down/move/up/cancel）是旧安卓录制留下来的，时空客户端回放不了；
/// - 坐标超出录制分辨率时，回放会被**贴到窗口边缘**（`scale_recorded_point`
///   最后会 clamp），点不到想点的地方，但运行器不会报错——所以要在这里提醒；
/// - 没记录分辨率时不做缩放，坐标按 1600×900 设计坐标直接用；
/// - 空流程回放等于什么都不做。
enum RecordedFlowIssueLevel { error, warning }

class RecordedFlowIssue {
  const RecordedFlowIssue({
    required this.flowName,
    required this.message,
    this.actionIndex = 0,
    this.level = RecordedFlowIssueLevel.error,
  });

  final String flowName;

  /// 第几个动作（1 开始）；0 表示整条流程的问题。
  final int actionIndex;

  final String message;

  final RecordedFlowIssueLevel level;

  bool get isError => level == RecordedFlowIssueLevel.error;

  String get location =>
      actionIndex <= 0 ? '整条流程' : '第 $actionIndex 个动作';
}

const List<RecordedActionType> _rawPointerTypes = <RecordedActionType>[
  RecordedActionType.down,
  RecordedActionType.move,
  RecordedActionType.up,
  RecordedActionType.cancel,
];

/// 录制分辨率（回放时用来把坐标缩放到窗口大小）。没有就返回 null。
({int width, int height})? recordedFlowScreenSize(RecordedFlow flow) {
  if (flow.screenWidth > 0 && flow.screenHeight > 0) {
    return (width: flow.screenWidth, height: flow.screenHeight);
  }
  return null;
}

List<RecordedFlowIssue> lintRecordedFlow(RecordedFlow flow) {
  final List<RecordedFlowIssue> issues = <RecordedFlowIssue>[];
  final String name = flow.name.trim().isEmpty ? '未命名流程' : flow.name.trim();
  if (flow.actions.isEmpty) {
    issues.add(
      RecordedFlowIssue(
        flowName: name,
        message: '这条录制流程没有动作，回放不会做任何事',
        level: RecordedFlowIssueLevel.warning,
      ),
    );
    return issues;
  }
  final ({int width, int height})? size = recordedFlowScreenSize(flow);
  if (size == null) {
    issues.add(
      RecordedFlowIssue(
        flowName: name,
        message: '没有记录分辨率，坐标会按 1600×900 直接使用',
        level: RecordedFlowIssueLevel.warning,
      ),
    );
  }
  for (int index = 0; index < flow.actions.length; index++) {
    final RecordedAction action = flow.actions[index];
    final int actionIndex = index + 1;
    if (_rawPointerTypes.contains(action.type)) {
      issues.add(
        RecordedFlowIssue(
          flowName: name,
          actionIndex: actionIndex,
          message: '是原始指针事件（${action.type.name}），时空客户端回放不了，'
              '请在客户端上重新录一遍',
        ),
      );
      continue;
    }
    if (size != null) {
      _checkPoint(
        issues,
        name,
        actionIndex,
        action.startX,
        action.startY,
        size,
        '起点',
      );
      if (action.type == RecordedActionType.swipe ||
          action.type == RecordedActionType.longPressSwipe) {
        _checkPoint(
          issues,
          name,
          actionIndex,
          action.endX,
          action.endY,
          size,
          '终点',
        );
      }
      for (int i = 0; i < action.dragPath.length; i++) {
        final RecordedPathPoint point = action.dragPath[i];
        _checkPoint(
          issues,
          name,
          actionIndex,
          point.x,
          point.y,
          size,
          '拖拽轨迹第 ${i + 1} 个点',
        );
      }
    }
    if ((action.type == RecordedActionType.swipe ||
            action.type == RecordedActionType.longPressSwipe) &&
        action.startX == action.endX &&
        action.startY == action.endY) {
      issues.add(
        RecordedFlowIssue(
          flowName: name,
          actionIndex: actionIndex,
          message: '滑动的起点和终点相同，回放起来等于点一下',
          level: RecordedFlowIssueLevel.warning,
        ),
      );
    }
  }
  return issues;
}

List<RecordedFlowIssue> lintRecordedFlows(List<RecordedFlow> flows) {
  final List<RecordedFlowIssue> issues = <RecordedFlowIssue>[];
  for (final RecordedFlow flow in flows) {
    issues.addAll(lintRecordedFlow(flow));
  }
  return issues;
}

/// 一句话概括（给按钮/汇总条用）。
String describeRecordedFlowIssues(List<RecordedFlowIssue> issues) {
  if (issues.isEmpty) {
    return '';
  }
  final int errors = issues
      .where((RecordedFlowIssue item) => item.isError)
      .length;
  final int warnings = issues.length - errors;
  final List<String> parts = <String>[];
  if (errors > 0) {
    parts.add('$errors 处问题');
  }
  if (warnings > 0) {
    parts.add('$warnings 处提醒');
  }
  return parts.join('，');
}

void _checkPoint(
  List<RecordedFlowIssue> issues,
  String flowName,
  int actionIndex,
  int x,
  int y,
  ({int width, int height}) size,
  String subject,
) {
  final bool outside =
      x < 0 || y < 0 || x >= size.width || y >= size.height;
  if (outside) {
    issues.add(
      RecordedFlowIssue(
        flowName: flowName,
        actionIndex: actionIndex,
        message: '$subject坐标 ($x, $y) 超出录制分辨率 '
            '${size.width}×${size.height}，回放会被贴到窗口边缘',
        level: RecordedFlowIssueLevel.warning,
      ),
    );
  }
}
