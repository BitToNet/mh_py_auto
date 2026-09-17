import 'package:ai/main.dart' as app;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 界面上两个"自检"按钮的接线测试。
///
/// 真正跑 Python 的逻辑在 `test/win_flow_self_check_test.dart` 里针对
/// `WinFlowSelfCheck` 测（点界面堆步骤来做这件事太依赖布局，容易假绿）；
/// 这里只确认按钮该出现时出现、该禁用时禁用——避免"点了什么都不发生"。
Future<void> pumpLauncher(WidgetTester tester, {required bool windowsMode}) async {
  app.debugForceWindowsClientMode = windowsMode;
  addTearDown(() => app.debugForceWindowsClientMode = false);
  SharedPreferences.setMockInitialValues({});
  await tester.binding.setSurfaceSize(const Size(1440, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  app.showDialog.value = false;
  await tester.pumpWidget(const app.MyApp());
  await tester.pumpAndSettle(const Duration(milliseconds: 300));
}

bool? buttonEnabled(WidgetTester tester, String label) {
  final Finder outlined = find.widgetWithText(OutlinedButton, label);
  if (outlined.evaluate().isNotEmpty) {
    return tester.widget<OutlinedButton>(outlined).onPressed != null;
  }
  final Finder elevated = find.widgetWithText(ElevatedButton, label);
  if (elevated.evaluate().isNotEmpty) {
    return tester.widget<ElevatedButton>(elevated).onPressed != null;
  }
  return null;
}

void main() {
  testWidgets('时空模式：自定义流程自检按钮存在，空流程时禁用', (WidgetTester tester) async {
    await pumpLauncher(tester, windowsMode: true);
    await tester.tap(find.text('自定义流程'));
    await tester.pumpAndSettle();

    const String label = '流程自检（不连游戏）';
    expect(find.text(label), findsOneWidget);
    expect(buttonEnabled(tester, label), isFalse, reason: '空流程不该能自检');
  });

  testWidgets('时空模式：录制流程自检按钮存在，回放列表为空时禁用', (
    WidgetTester tester,
  ) async {
    await pumpLauncher(tester, windowsMode: true);
    await tester.tap(find.text('手势录制'));
    await tester.pumpAndSettle();

    const String label = '录制流程自检（不回放）';
    expect(find.text(label), findsOneWidget);
    expect(buttonEnabled(tester, label), isFalse, reason: '回放列表为空不该能自检');
  });

  testWidgets('模拟器模式：两个自检按钮都不出现（它只对 Windows 运行器有意义）', (
    WidgetTester tester,
  ) async {
    await pumpLauncher(tester, windowsMode: false);
    await tester.tap(find.text('自定义流程'));
    await tester.pumpAndSettle();
    expect(find.text('流程自检（不连游戏）'), findsNothing);

    await tester.tap(find.text('手势录制'));
    await tester.pumpAndSettle();
    expect(find.text('录制流程自检（不回放）'), findsNothing);
  });
}
