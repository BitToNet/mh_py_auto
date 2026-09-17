import 'dart:convert';
import 'dart:io';

import 'package:ai/custom_flow.dart';
import 'package:ai/main.dart' as app;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 流程编辑器里的"这一步有问题"红字。
///
/// 规则本身在 `test/custom_flow_lint_test.dart` 里测；这里只确认它真的被画到
/// 界面上：加载一个缺模板图的流程后，步骤卡片上要有红字，顶部要有汇总。
///
/// 注意：加载流程是**真实文件 I/O**，widget 测试的假时钟不会让它完成，
/// 每次触发之后必须用 `runAsync` 放行，否则测试会在"流程根本没加载"的
/// 状态下通过（假绿）。
/// 放行真实文件 I/O：加载流程要串好几个 await（建目录 → 读文件 → 解析），
/// 每完成一个 await 才能发起下一个，所以必须多轮"真实等待 + 假时钟 pump"，
/// 一轮是不够的（一轮会让界面停在"还没读到文件"的状态，测试于是假绿）。
Future<void> settleRealIo(WidgetTester tester, {int rounds = 6}) async {
  for (int round = 0; round < rounds; round++) {
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
  }
}

/// 把 path_provider 的通道指向临时目录。
///
/// 不 mock 的话，录制服务在 macOS 测试环境里会抛 MissingPluginException——
/// 以前这条异常从没暴露过，因为假时钟下这些 I/O 根本不会完成（界面永远停在
/// "还没读到文件"）。一旦用 runAsync 放行真实 I/O，它就会作为未处理异常
/// 把测试打挂。
void mockSupportDirectory(WidgetTester tester, Directory dir) {
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

Future<void> pumpWithFlow(WidgetTester tester, CustomFlowDefinition flow) async {
  final Directory dir = Directory.systemTemp.createTempSync('flow_lint_ui_');
  addTearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });
  // 直接把流程 JSON 写进存储目录：绕开 saveFlow 的规范化流程
  // （那条路会去碰录制服务/资源目录），loadFlow 只认这个文件。
  mockSupportDirectory(tester, dir);
  final Directory flowDir = Directory('${dir.path}/custom_flows')
    ..createSync(recursive: true);
  File('${flowDir.path}/${flow.name}.json').writeAsStringSync(
    jsonEncode(flow.toJson()),
  );
  app.debugCustomFlowStorageService = CustomFlowStorageService(
    baseDirectory: dir,
  );
  addTearDown(() => app.debugCustomFlowStorageService = null);
  app.debugForceWindowsClientMode = true;
  addTearDown(() => app.debugForceWindowsClientMode = false);
  SharedPreferences.setMockInitialValues(<String, Object>{
    'selectedCustomFlowName': flow.name,
  });
  await tester.binding.setSurfaceSize(const Size(1440, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  app.showDialog.value = false;
  await tester.pumpWidget(const app.MyApp());
  await tester.pumpAndSettle(const Duration(milliseconds: 300));
  await tester.tap(find.text('自定义流程'));
  await tester.pumpAndSettle();
  // 关键：刷新/加载都要读真实文件，必须在 runAsync 里触发，
  // 否则假时钟下这些 await 永远不会返回（界面停在"还没读到文件"）。
  await tester.runAsync(() async {
    await tester.tap(find.text('刷新自定义流程列表'));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await tester.tap(find.text('加载所选流程'));
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });
  await tester.pumpAndSettle();
}

/// 列表里渲染出来的步骤卡片数量（用来确认流程真的加载进来了，
/// 避免"什么都没加载"时断言 `findsNothing` 空过）。
int stepCardCount(WidgetTester tester) {
  return find
      .byWidgetPredicate(
        (Widget widget) =>
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(
              'custom-flow-step-',
            ),
      )
      .evaluate()
      .length;
}

CustomFlowDefinition flowWith(List<CustomFlowStep> steps) {
  final DateTime now = DateTime.utc(2026, 1, 1);
  return CustomFlowDefinition(
    name: '自检用流程',
    createdAt: now,
    updatedAt: now,
    steps: steps,
  );
}

void main() {
  testWidgets('缺模板图的步骤在列表里标红，顶部有汇总', (WidgetTester tester) async {
    await pumpWithFlow(
      tester,
      flowWith(<CustomFlowStep>[
        const CustomFlowStep(
          id: 's1',
          type: CustomFlowStepType.wait,
          label: '等待',
        ),
        const CustomFlowStep(
          id: 's2',
          type: CustomFlowStepType.imageTap,
          label: '识图点击',
          imageSource: CustomFlowImageSource.localFile,
          templatePath: '',
        ),
      ]),
    );

    // 先确认流程真的加载进来了（否则后面的断言是空过）
    expect(stepCardCount(tester), 2);
    expect(find.textContaining('流程里有需要修正的地方'), findsOneWidget);
    expect(find.textContaining('没有选择模板图片'), findsOneWidget);
    expect(find.textContaining('第 2 步'), findsWidgets);
  });

  testWidgets('流程没问题时不显示任何红字', (WidgetTester tester) async {
    await pumpWithFlow(
      tester,
      flowWith(<CustomFlowStep>[
        const CustomFlowStep(
          id: 's1',
          type: CustomFlowStepType.coordinateTap,
          label: '坐标点击',
          x: 800,
          y: 450,
        ),
      ]),
    );

    expect(stepCardCount(tester), 1, reason: '流程要真的加载进来，否则这条测试是空过');
    expect(find.textContaining('流程里有需要修正的地方'), findsNothing);
    expect(find.textContaining('没有选择模板图片'), findsNothing);
  });

  testWidgets('痒痒鼠模式步骤在时空模式下被标红', (WidgetTester tester) async {
    await pumpWithFlow(
      tester,
      flowWith(<CustomFlowStep>[
        const CustomFlowStep(
          id: 's1',
          type: CustomFlowStepType.gameMode,
          label: '痒痒鼠模式',
        ),
      ]),
    );

    expect(stepCardCount(tester), 1);
    expect(find.textContaining('在时空客户端上不支持'), findsOneWidget);
  });
}
