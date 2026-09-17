import 'package:ai/main.dart' as app;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 时空（Windows 客户端）模式的界面测试。
///
/// 真机由 `Platform.isWindows` 决定分支，macOS 上跑 `flutter test` 进不去，
/// 所以用 `app.debugForceWindowsClientMode` 强制切换——这保证了
/// "界面切成时空模式"这条分支至少在本机是被测过的。
Future<void> pumpLauncher(
  WidgetTester tester, {
  required bool windowsMode,
}) async {
  app.debugForceWindowsClientMode = windowsMode;
  addTearDown(() => app.debugForceWindowsClientMode = false);
  SharedPreferences.setMockInitialValues({});
  await tester.binding.setSurfaceSize(const Size(1440, 1800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  app.showDialog.value = false;
  await tester.pumpWidget(const app.MyApp());
  await tester.pumpAndSettle(const Duration(milliseconds: 300));
}

Future<void> openCustomFlowTab(WidgetTester tester) async {
  await tester.tap(find.text('自定义流程'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('时空模式下用 Windows 客户端工具面板替换模拟器坐标显示', (
    WidgetTester tester,
  ) async {
    await pumpLauncher(tester, windowsMode: true);
    await openCustomFlowTab(tester);

    expect(find.text('时空客户端工具'), findsOneWidget);
    expect(find.text('模拟器坐标显示'), findsNothing);
    for (final String label in <String>[
      '刷新客户端窗口',
      '确保客户端运行',
      '重启客户端',
      '窗口对齐 1600×900',
      '截图后端自检',
    ]) {
      expect(find.text(label), findsOneWidget, reason: '缺少按钮：$label');
    }
    // 面板文案要讲清"窗口消息级控制、不注入、不读内存、坐标统一 1600×900"
    expect(find.textContaining('窗口消息级控制'), findsOneWidget);
    expect(find.textContaining('win:<进程号>'), findsOneWidget);
    expect(find.textContaining('1600×900'), findsWidgets);
  });

  testWidgets('时空模式下痒痒鼠页签标注为不支持，其它页签照常', (
    WidgetTester tester,
  ) async {
    await pumpLauncher(tester, windowsMode: true);

    expect(find.text('痒痒鼠（不支持）'), findsOneWidget);
    expect(find.text('痒痒鼠'), findsNothing);
    expect(find.text('手势录制'), findsOneWidget);
    expect(find.text('自定义流程'), findsOneWidget);
  });

  testWidgets('非时空模式仍是模拟器界面（开关确实在起作用）', (
    WidgetTester tester,
  ) async {
    await pumpLauncher(tester, windowsMode: false);
    await openCustomFlowTab(tester);

    expect(find.text('模拟器坐标显示'), findsOneWidget);
    expect(find.text('时空客户端工具'), findsNothing);
    expect(find.text('痒痒鼠'), findsOneWidget);
    expect(find.text('痒痒鼠（不支持）'), findsNothing);
  });

  testWidgets('时空模式下点「启动python程序」只给提示，不跑内置任务脚本', (
    WidgetTester tester,
  ) async {
    await pumpLauncher(tester, windowsMode: true);

    await tester.tap(find.text('启动python程序'));
    await tester.pumpAndSettle();

    // 目标②的硬要求：时空版不内置阴阳师任务脚本，必须明确拦住并给替代方案
    expect(find.text('痒痒鼠模式不支持时空客户端'), findsOneWidget);
    // 弹窗与日志区都会出现这句，按"至少一处"断言
    expect(find.textContaining('不内置阴阳师任务脚本'), findsWidgets);
    expect(find.textContaining('识图点击'), findsWidgets);
  });

  testWidgets('时空模式下自定义流程页签仍能正常渲染', (WidgetTester tester) async {
    await pumpLauncher(tester, windowsMode: true);
    await openCustomFlowTab(tester);

    // 录制流程与识图/坐标步骤在时空模式下都应保留
    expect(find.text('添加识图点击'), findsOneWidget);
    expect(find.text('自定义流程'), findsWidgets);
    expect(find.text('时空客户端工具'), findsOneWidget);
  });
}
