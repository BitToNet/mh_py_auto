import 'dart:convert';
import 'dart:io';

import 'package:ai/win_flow_self_check.dart';
import 'package:flutter_test/flutter_test.dart';

/// 流程自检器：把配置交给**真实的** Python 运行器跑 `--dry-run`。
///
/// 界面上的按钮只做三件事：写配置 → 调用这里 → 展示结果，所以真正需要
/// 盯住的是这个类：退出码怎么判、问题行怎么摘、失败时给用户看什么。
String get _pythonExecutable => Platform.isWindows ? 'python' : 'python3';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('win_self_check_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  WinFlowSelfCheck flowChecker() => WinFlowSelfCheck(
    pythonExecutable: _pythonExecutable,
    scriptPath: 'scripts/win/flow_runner_win.py',
    workingDirectory: Directory.current.path,
  );

  WinFlowSelfCheck recordChecker() => WinFlowSelfCheck(
    pythonExecutable: _pythonExecutable,
    scriptPath: 'scripts/win/record_runner_win.py',
    workingDirectory: Directory.current.path,
  );

  test('正常自定义流程：自检通过，摘要干净', () async {
    final FlowSelfCheckResult result = await flowChecker().check(
      config: <String, dynamic>{
        'deviceIds': <String>['win:1111'],
        'loopCount': 1,
        'steps': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'coordinateTap',
            'x': 800,
            'y': 450,
          },
        ],
        'imagePaths': <String, String>{},
        'recordedFlows': <String, dynamic>{},
      },
      workDir: tempDir,
    );

    expect(result.ok, isTrue, reason: result.output);
    expect(result.summary, '自检通过');
    expect(result.problems, isEmpty);
    expect(result.output, contains('不会连接窗口'));
    expect(File(result.configPath).existsSync(), isTrue);
    // 写出去的配置必须是能读回来的 JSON（界面就是靠这一步交接给 Python）
    final Map<String, dynamic> written =
        json.decode(File(result.configPath).readAsStringSync())
            as Map<String, dynamic>;
    expect(written['deviceIds'], <String>['win:1111']);
  });

  test('坏流程：不通过，并且能摘出问题行给用户', () async {
    final FlowSelfCheckResult result = await flowChecker().check(
      config: <String, dynamic>{
        'deviceIds': <String>['win:1111'],
        'steps': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'screenshot'},
        ],
        'imagePaths': <String, String>{},
        'recordedFlows': <String, dynamic>{},
      },
      workDir: tempDir,
    );

    expect(result.ok, isFalse);
    expect(result.problems, isNotEmpty);
    expect(result.problems.first, contains('不支持的步骤类型'));
    expect(result.summary, contains('不支持的步骤类型'));
    // 摘要里不带运行器用来标问题的那个符号，直接给用户看
    expect(result.summary, isNot(contains('！')));
  });

  test('没装 RapidOCR 之类的环境问题不该影响自检（纯离线）', () async {
    // 带文字识别步骤但没有任何依赖：自检仍然只校配置文件
    final FlowSelfCheckResult result = await flowChecker().check(
      config: <String, dynamic>{
        'deviceIds': <String>[],
        'steps': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'ocrTap',
            'ocrTargetText': '确定',
          },
        ],
        'imagePaths': <String, String>{},
        'recordedFlows': <String, dynamic>{},
      },
      workDir: tempDir,
    );
    expect(result.ok, isTrue, reason: result.output);
  });

  test('录制流程：交给回放器自检，能认出动作数', () async {
    final FlowSelfCheckResult result = await recordChecker().check(
      config: <String, dynamic>{
        'deviceId': 'win:1111',
        'loopCount': 1,
        'flows': <Map<String, dynamic>>[
          <String, dynamic>{
            'name': '排队',
            'screenWidth': 1600,
            'screenHeight': 900,
            'actions': <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'tap',
                'startX': 10,
                'startY': 20,
                'delayMs': 100,
              },
            ],
          },
        ],
      },
      workDir: tempDir,
      fileName: 'recorded_flow_config.json',
    );

    expect(result.ok, isTrue, reason: result.output);
    expect(result.output, contains('动作合计 1 个'));
  });

  test('录制流程缺字段：不通过，问题行指到具体动作', () async {
    final FlowSelfCheckResult result = await recordChecker().check(
      config: <String, dynamic>{
        'deviceId': 'win:1111',
        'flows': <Map<String, dynamic>>[
          <String, dynamic>{
            'name': '坏的',
            'screenWidth': 1600,
            'screenHeight': 900,
            'actions': <Map<String, dynamic>>[
              <String, dynamic>{'type': 'tap'},
            ],
          },
        ],
      },
      workDir: tempDir,
    );

    expect(result.ok, isFalse);
    expect(result.problems.first, contains('缺少 startX'));
  });

  test('脚本路径不对：返回非 0 而不是抛异常（界面能照常展示）', () async {
    final FlowSelfCheckResult result = await WinFlowSelfCheck(
      pythonExecutable: _pythonExecutable,
      scriptPath: 'scripts/win/not_a_runner.py',
      workingDirectory: Directory.current.path,
    ).check(
      config: <String, dynamic>{'deviceIds': <String>[]},
      workDir: tempDir,
    );

    expect(result.ok, isFalse);
    expect(result.output, isNotEmpty);
  });

  test('自检不会在临时目录里留下别的文件', () async {
    await flowChecker().check(
      config: <String, dynamic>{
        'deviceIds': <String>[],
        'steps': <Map<String, dynamic>>[],
        'imagePaths': <String, String>{},
        'recordedFlows': <String, dynamic>{},
      },
      workDir: tempDir,
    );
    final List<String> names = tempDir
        .listSync()
        .map((FileSystemEntity entity) => entity.uri.pathSegments.last)
        .toList();
    expect(names, <String>['custom_flow_config.json']);
  });
}
