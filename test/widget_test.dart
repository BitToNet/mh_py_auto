import 'package:ai/main.dart' as app;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> pumpLauncher(WidgetTester tester) async {
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

Future<void> openFirstBranchCaseEditor(WidgetTester tester) async {
  await tester.tap(find.text('添加多图条件分支'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('添加条件分支').last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('launcher renders main sections and tabs', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(1440, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    app.showDialog.value = false;

    await tester.pumpWidget(const app.MyApp());
    await tester.pumpAndSettle(const Duration(milliseconds: 300));

    expect(find.text('ADB管理:'), findsOneWidget);
    expect(find.text('设备管理:'), findsOneWidget);
    expect(find.text('痒痒鼠'), findsOneWidget);
    expect(find.text('手势录制'), findsOneWidget);
    expect(find.text('自定义流程'), findsOneWidget);
    expect(find.text('启动python程序'), findsOneWidget);
  });

  testWidgets('deprecated Bai Gui mode is hidden and old preference is safe', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({'selectedArg': 'bai_gui'});
    await tester.binding.setSurfaceSize(const Size(1440, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    app.showDialog.value = false;

    await tester.pumpWidget(const app.MyApp());
    await tester.pumpAndSettle(const Duration(milliseconds: 300));

    expect(find.text('百鬼夜行'), findsNothing);
    expect(find.text('御灵'), findsOneWidget);

    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();

    expect(find.text('百鬼夜行'), findsNothing);
  });

  testWidgets('custom flow exposes OCR as image recognition mode', (
    WidgetTester tester,
  ) async {
    await pumpLauncher(tester);
    await openCustomFlowTab(tester);

    expect(find.text('添加文字识别点击'), findsNothing);
    expect(find.text('添加识图点击'), findsOneWidget);

    await tester.tap(find.text('添加识图点击'));
    await tester.pumpAndSettle();

    expect(find.text('识别模式'), findsOneWidget);
    expect(find.text('图片识别'), findsWidgets);
  });

  testWidgets('custom flow exposes and toggles simulator execution mode', (
    WidgetTester tester,
  ) async {
    await pumpLauncher(tester);
    await openCustomFlowTab(tester);

    expect(find.text('模拟器串行执行'), findsOneWidget);
    expect(
      find.text('并行模式下各模拟器独立执行，互不等待，也不共享流程步骤的等待时间。'),
      findsOneWidget,
    );

    await tester.tap(find.text('模拟器串行执行'));
    await tester.pumpAndSettle();

    expect(find.text('模拟器并行执行'), findsOneWidget);
  });

  testWidgets('loop image condition exposes text-recognition actions', (
    WidgetTester tester,
  ) async {
    await pumpLauncher(tester);
    await openCustomFlowTab(tester);

    await tester.tap(find.text('添加循环块'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('固定次数').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('识图条件').last);
    await tester.pumpAndSettle();

    expect(find.text('识别后的循环动作'), findsOneWidget);
    expect(find.text('识别到图片停止循环'), findsOneWidget);
    expect(find.text('识别模式'), findsOneWidget);

    await tester.tap(find.text('图片识别').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('文字识别（RapidOCR）').last);
    await tester.pumpAndSettle();

    expect(find.text('目标文字'), findsOneWidget);
    expect(find.text('识别到文字停止循环'), findsOneWidget);
    expect(find.text('识别到图片停止循环'), findsNothing);

    await tester.tap(find.text('识别到文字停止循环').last);
    await tester.pumpAndSettle();

    expect(find.text('识别到文字继续循环'), findsWidgets);
    expect(find.text('识别到文字停止循环'), findsWidgets);
  });

  testWidgets('branch case child toolbar matches top-level actions', (
    WidgetTester tester,
  ) async {
    await pumpLauncher(tester);
    await openCustomFlowTab(tester);
    await openFirstBranchCaseEditor(tester);
    Finder currentDialogText(String text) => find.descendant(
      of: find.byType(AlertDialog).last,
      matching: find.text(text),
    );

    expect(find.text('编辑分支条件'), findsOneWidget);
    expect(find.text('编辑多图条件分支'), findsOneWidget);
    expect(find.text('编辑识图坐标分支'), findsNothing);
    expect(currentDialogText('添加多图条件分支'), findsOneWidget);
    expect(currentDialogText('添加识图坐标分支'), findsOneWidget);
    expect(currentDialogText('添加条件分支'), findsNothing);
    expect(currentDialogText('添加坐标分支'), findsNothing);
    expect(currentDialogText('添加重启Activity（可以用来重启游戏）'), findsOneWidget);

    final imageBranchTitleCount = find.text('编辑多图条件分支').evaluate().length;
    await tester.tap(currentDialogText('添加多图条件分支'));
    await tester.pumpAndSettle();
    expect(
      find.text('编辑多图条件分支').evaluate().length,
      greaterThan(imageBranchTitleCount),
    );
    await tester.tap(currentDialogText('取消').last);
    await tester.pumpAndSettle();

    await tester.tap(currentDialogText('添加识图坐标分支'));
    await tester.pumpAndSettle();
    expect(find.text('编辑识图坐标分支'), findsOneWidget);
  });

  testWidgets('branch step editor can reuse parent screenshots', (
    WidgetTester tester,
  ) async {
    await pumpLauncher(tester);
    await openCustomFlowTab(tester);

    await tester.tap(find.text('添加多图条件分支'));
    await tester.pumpAndSettle();

    final reuseSwitch = find.text('复用上级分支截图');
    expect(reuseSwitch, findsOneWidget);

    await tester.tap(reuseSwitch);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();

    expect(find.textContaining('复用上级截图'), findsOneWidget);

    final branchSummary = find.textContaining('复用上级截图').first;
    final branchTile = find
        .ancestor(of: branchSummary, matching: find.byType(ListTile))
        .first;
    await tester.tap(
      find.descendant(of: branchTile, matching: find.byTooltip('编辑')).first,
    );
    await tester.pumpAndSettle();

    expect(reuseSwitch, findsOneWidget);
    expect(
      tester
          .widget<SwitchListTile>(
            find.ancestor(
              of: reuseSwitch,
              matching: find.byType(SwitchListTile),
            ),
          )
          .value,
      isTrue,
    );

    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('添加识图坐标分支'));
    await tester.pumpAndSettle();

    expect(reuseSwitch, findsOneWidget);
  });
}
