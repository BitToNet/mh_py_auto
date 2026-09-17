import 'package:ai/recorded_flow_lint.dart';
import 'package:ai/recording_flow.dart';
import 'package:flutter_test/flutter_test.dart';

/// 录制流程编辑期提示的规则测试。
/// 规则要对齐回放侧（record_runner_win 的自检 + win_replay 的坐标缩放），
/// 尤其是"坐标越界会被贴到窗口边缘但运行器不报错"这条。
RecordedAction action({
  RecordedActionType type = RecordedActionType.tap,
  int startX = 100,
  int startY = 200,
  int? endX,
  int? endY,
  List<RecordedPathPoint> dragPath = const <RecordedPathPoint>[],
}) {
  return RecordedAction(
    type: type,
    delayMs: 100,
    startX: startX,
    startY: startY,
    endX: endX ?? startX,
    endY: endY ?? startY,
    durationMs: 120,
    holdBeforeMoveMs: 0,
    dragPath: dragPath,
    rawEvents: const <RawInputEvent>[],
  );
}

RecordedFlow flow(
  List<RecordedAction> actions, {
  String name = '排队',
  int width = 1600,
  int height = 900,
}) {
  return RecordedFlow(
    name: name,
    deviceId: 'win:1111',
    touchDevicePath: '',
    screenWidth: width,
    screenHeight: height,
    createdAt: DateTime.utc(2026, 1, 1),
    actions: actions,
  );
}

List<String> messages(List<RecordedFlowIssue> issues) =>
    issues.map((RecordedFlowIssue item) => item.message).toList();

void main() {
  test('正常一条点击没有任何提示', () {
    expect(
      lintRecordedFlow(flow(<RecordedAction>[action(startX: 800, startY: 450)])),
      isEmpty,
    );
  });

  test('空流程只是提醒（回放等于什么都不做）', () {
    final List<RecordedFlowIssue> issues = lintRecordedFlow(
      flow(const <RecordedAction>[]),
    );
    expect(issues.single.isError, isFalse);
    expect(issues.single.message, contains('没有动作'));
    expect(issues.single.location, '整条流程');
  });

  test('原始指针事件是错误（旧安卓录制留下来的）', () {
    final List<RecordedFlowIssue> issues = lintRecordedFlow(
      flow(<RecordedAction>[action(type: RecordedActionType.down)]),
    );
    expect(issues.single.isError, isTrue);
    expect(issues.single.message, contains('原始指针事件'));
    expect(issues.single.location, '第 1 个动作');
  });

  test('坐标越界要提醒（回放会被贴到窗口边缘）', () {
    final List<RecordedFlowIssue> issues = lintRecordedFlow(
      flow(<RecordedAction>[
        action(startX: 1700, startY: 450),
        action(startX: -5, startY: 10),
        action(startX: 1599, startY: 899),
      ]),
    );
    expect(issues, hasLength(2));
    expect(messages(issues).first, contains('超出录制分辨率'));
    expect(messages(issues).first, contains('1600×900'));
    expect(messages(issues).first, contains('(1700, 450)'));
    expect(issues.first.location, '第 1 个动作');
    expect(messages(issues).last, contains('(-5, 10)'));
  });

  test('滑动的终点与拖拽轨迹点也要查', () {
    final List<RecordedFlowIssue> issues = lintRecordedFlow(
      flow(<RecordedAction>[
        action(
          type: RecordedActionType.swipe,
          startX: 10,
          startY: 10,
          endX: 2000,
          endY: 20,
          dragPath: const <RecordedPathPoint>[
            RecordedPathPoint(x: 500, y: 500, delayMs: 0),
            RecordedPathPoint(x: 1600, y: 900, delayMs: 10),
          ],
        ),
      ]),
    );
    expect(issues, hasLength(2));
    expect(messages(issues)[0], contains('终点'));
    expect(messages(issues)[1], contains('拖拽轨迹第 2 个点'));
  });

  test('点击/长按不看终点坐标（回放器也不用它）', () {
    expect(
      lintRecordedFlow(
        flow(<RecordedAction>[
          action(
            type: RecordedActionType.longPress,
            startX: 800,
            startY: 450,
            endX: 5000,
            endY: 5000,
          ),
        ]),
      ),
      isEmpty,
    );
  });

  test('没记录分辨率时只提醒，不做越界判断', () {
    final List<RecordedFlowIssue> issues = lintRecordedFlow(
      flow(<RecordedAction>[action(startX: 9999, startY: 9999)], width: 0, height: 0),
    );
    expect(issues.single.isError, isFalse);
    expect(issues.single.message, contains('没有记录分辨率'));
  });

  test('滑动起终点相同只是提醒', () {
    final List<RecordedFlowIssue> issues = lintRecordedFlow(
      flow(<RecordedAction>[
        action(
          type: RecordedActionType.swipe,
          startX: 300,
          startY: 400,
          endX: 300,
          endY: 400,
        ),
      ]),
    );
    expect(issues.single.isError, isFalse);
    expect(issues.single.message, contains('等于点一下'));
  });

  test('多条流程合并 + 一句话概括', () {
    final List<RecordedFlowIssue> issues = lintRecordedFlows(<RecordedFlow>[
      flow(<RecordedAction>[action(type: RecordedActionType.move)], name: 'A'),
      flow(<RecordedAction>[action(startX: 1700)], name: 'B'),
      flow(const <RecordedAction>[], name: 'C'),
    ]);
    expect(describeRecordedFlowIssues(issues), '1 处问题，2 处提醒');
    expect(issues.first.flowName, 'A');
    expect(describeRecordedFlowIssues(const <RecordedFlowIssue>[]), '');
  });
}
