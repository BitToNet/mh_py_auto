import 'dart:convert';
import 'dart:io';

import 'package:ai/main.dart' as app;
import 'package:ai/recording_flow.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel, MethodCall;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 录制流程列表上的编辑期提示（坐标越界、原始指针事件、空流程）。
///
/// 规则在 `test/recorded_flow_lint_test.dart` 里测；这里确认它被画到界面上。
/// 和流程编辑器那条测试一样：读取流程是真实文件 I/O，必须在 runAsync 里触发，
/// 并且要 mock path_provider（否则录制服务在测试环境会抛 MissingPluginException）。
void mockSupportDirectory(Directory dir) {
  const MethodChannel channel = MethodChannel(
    'plugins.flutter.io/path_provider',
  );
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (MethodCall call) async => dir.path);
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
}

RecordedFlow brokenFlow() {
  return RecordedFlow(
    name: '越界的录制',
    deviceId: 'win:1111',
    touchDevicePath: '',
    screenWidth: 1600,
    screenHeight: 900,
    createdAt: DateTime.utc(2026, 1, 1),
    actions: <RecordedAction>[
      const RecordedAction(
        type: RecordedActionType.tap,
        delayMs: 100,
        startX: 1700,
        startY: 450,
        endX: 1700,
        endY: 450,
        durationMs: 120,
        holdBeforeMoveMs: 0,
        dragPath: <RecordedPathPoint>[],
        rawEvents: <RawInputEvent>[],
      ),
      const RecordedAction(
        type: RecordedActionType.move,
        delayMs: 10,
        startX: 100,
        startY: 100,
        endX: 100,
        endY: 100,
        durationMs: 10,
        holdBeforeMoveMs: 0,
        dragPath: <RecordedPathPoint>[],
        rawEvents: <RawInputEvent>[],
      ),
    ],
  );
}

Future<void> pumpRecordingTab(WidgetTester tester) async {
  final Directory dir = Directory.systemTemp.createTempSync('rec_lint_ui_');
  addTearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });
  mockSupportDirectory(dir);
  final Directory recordDir = Directory('${dir.path}/recordings')
    ..createSync(recursive: true);
  File('${recordDir.path}/${brokenFlow().name}.json').writeAsStringSync(
    jsonEncode(brokenFlow().toJson()),
  );
  app.debugForceWindowsClientMode = true;
  addTearDown(() => app.debugForceWindowsClientMode = false);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  await tester.binding.setSurfaceSize(const Size(1440, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  app.showDialog.value = false;
  await tester.pumpWidget(const app.MyApp());
  await tester.pumpAndSettle(const Duration(milliseconds: 300));
  await tester.tap(find.text('手势录制'));
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    await tester.tap(find.text('刷新流程列表'));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await tester.tap(find.text('添加到回放列表'));
    await Future<void>.delayed(const Duration(milliseconds: 200));
  });
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('回放列表里标出越界坐标与原始指针事件', (WidgetTester tester) async {
    await pumpRecordingTab(tester);

    // 流程要真的进了回放列表（否则下面的断言是空过）
    expect(find.textContaining('1. 越界的录制'), findsOneWidget);
    expect(find.textContaining('超出录制分辨率'), findsOneWidget);
    expect(find.textContaining('原始指针事件'), findsOneWidget);
    expect(find.textContaining('回放列表里有需要确认的地方'), findsOneWidget);
  });
}
