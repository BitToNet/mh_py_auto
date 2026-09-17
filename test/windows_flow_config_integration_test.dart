import 'dart:convert';
import 'dart:io';

import 'package:ai/custom_flow.dart';
import 'package:ai/recording_flow.dart';
import 'package:flutter_test/flutter_test.dart';

/// 跨语言集成测试：Flutter 侧的流程模型 → JSON → **真实的** Python 运行器。
///
/// 界面写配置、运行器读配置，两边是各自手写的字段名。以前一边改字段名、
/// 另一边不知道，单测都能过，只有用户点"运行"时才炸。这里用运行器的
/// `--dry-run`（不连窗口、不点游戏）把这段链路真跑一遍：
///   CustomFlowStep.toJson()  →  flow_runner_win.py
///   RecordedFlow.toJson()    →  record_runner_win.py
String get _pythonExecutable => Platform.isWindows ? 'python' : 'python3';

const String _flowRunner = 'scripts/win/flow_runner_win.py';
const String _recordRunner = 'scripts/win/record_runner_win.py';

/// 1×1 透明 PNG：自检会检查模板文件是否真的存在。
final List<int> _pngBytes = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
  0x1F, 0x00, 0x05, 0xFE, 0x01, 0xFF, 0xAB, 0xCE, 0x36, 0x89, 0x00, 0x00,
  0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
];

Future<ProcessResult> _runRunner(String script, String configPath) {
  return Process.run(
    _pythonExecutable,
    <String>[script, configPath, '--dry-run'],
    workingDirectory: Directory.current.path,
  );
}

void main() {
  late Directory tempDir;

  setUpAll(() {
    final ProcessResult probe = Process.runSync(
      _pythonExecutable,
      <String>['-c', 'print(1)'],
    );
    if (probe.exitCode != 0) {
      fail('本机没有可用的 $_pythonExecutable，无法跑跨语言集成测试');
    }
  });

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('win_flow_config_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  File writeTemplate(String name) {
    final File file = File('${tempDir.path}/$name');
    file.writeAsBytesSync(_pngBytes);
    return file;
  }

  String writeConfig(String name, Map<String, dynamic> config) {
    final File file = File('${tempDir.path}/$name');
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(config),
    );
    return file.path;
  }

  /// 界面侧真正会写的自定义流程配置（字段与 lib/main.dart 一致）。
  Map<String, dynamic> customFlowConfig(List<CustomFlowStep> steps) {
    return <String, dynamic>{
      'deviceIds': <String>['win:1111'],
      'loopCount': 1,
      'parallelDevices': false,
      'steps': steps.map((CustomFlowStep item) => item.toJson()).toList(),
      'imagePaths': <String, String>{},
      'recordedFlows': <String, dynamic>{},
      'mainModeScriptPath': '',
      'shutdownPidFilePath': '',
      'pythonExecutable': _pythonExecutable,
    };
  }

  test('自定义流程 JSON 能被真实运行器读懂（含嵌套与录制流程）', () async {
    final File template = writeTemplate('start.png');
    final File branchTemplate = writeTemplate('battle.png');
    final RecordedFlow recorded = RecordedFlow(
      name: '出招',
      deviceId: 'win:1111',
      touchDevicePath: '',
      screenWidth: 1600,
      screenHeight: 900,
      createdAt: DateTime.utc(2026, 1, 1),
      actions: <RecordedAction>[
        const RecordedAction(
          type: RecordedActionType.tap,
          delayMs: 120,
          startX: 800,
          startY: 450,
          endX: 800,
          endY: 450,
          durationMs: 120,
          holdBeforeMoveMs: 0,
          dragPath: <RecordedPathPoint>[],
          rawEvents: <RawInputEvent>[],
        ),
        const RecordedAction(
          type: RecordedActionType.swipe,
          delayMs: 300,
          startX: 100,
          startY: 200,
          endX: 300,
          endY: 400,
          durationMs: 250,
          holdBeforeMoveMs: 0,
          dragPath: <RecordedPathPoint>[
            RecordedPathPoint(x: 150, y: 250, delayMs: 0),
          ],
          rawEvents: <RawInputEvent>[],
        ),
      ],
    );

    final List<CustomFlowStep> steps = <CustomFlowStep>[
      const CustomFlowStep(
        id: 's1',
        type: CustomFlowStepType.wait,
        label: '等待',
        waitMinSeconds: 0.2,
        waitMaxSeconds: 0.3,
      ),
      CustomFlowStep(
        id: 'tpl-1',
        type: CustomFlowStepType.imageTap,
        label: '识图点击',
        templateName: '开始按钮',
        templatePath: template.path,
      ),
      const CustomFlowStep(
        id: 's3',
        type: CustomFlowStepType.coordinateTap,
        label: '坐标点击',
        x: 800,
        y: 450,
      ),
      const CustomFlowStep(
        id: 's4',
        type: CustomFlowStepType.loopBlock,
        label: '循环块',
        loopCount: 3,
        children: <CustomFlowStep>[
          CustomFlowStep(
            id: 's4-1',
            type: CustomFlowStepType.recordedFlow,
            label: '出招',
            recordedFlowName: '出招',
          ),
        ],
      ),
      CustomFlowStep(
        id: 's5',
        type: CustomFlowStepType.imageBranch,
        label: '多图条件分支',
        branchCases: <CustomFlowBranchCase>[
          CustomFlowBranchCase(
            id: 'case-1',
            label: '战斗',
            // 旧格式单模板分支：模板 id 就是分支 id（界面导出与运行器都按这个来）
            templateName: '战斗图标',
            templatePath: branchTemplate.path,
            steps: <CustomFlowStep>[
              const CustomFlowStep(
                id: 's5-1',
                type: CustomFlowStepType.wait,
                label: '等待',
              ),
            ],
          ),
        ],
      ),
    ];

    final Map<String, dynamic> config = customFlowConfig(steps);
    (config['imagePaths'] as Map<String, String>)['tpl-1'] = template.path;
    (config['imagePaths'] as Map<String, String>)['case-1'] = branchTemplate.path;
    (config['recordedFlows'] as Map<String, dynamic>)['出招'] =
        recorded.toJson();
    final String configPath = writeConfig('custom_flow_config.json', config);

    final ProcessResult result = await _runRunner(_flowRunner, configPath);
    final String output = '${result.stdout}\n${result.stderr}';
    expect(result.exitCode, 0, reason: output);
    expect(output, contains('自检通过'));
    // 嵌套步骤（循环块里的录制流程、分支里的等待）都要被数到
    expect(output, contains('步骤: 共 6 个'));
    expect(output, contains('recordedFlow'));
    expect(output, contains('出招（2 个动作）'));
    // 界面写进去的模板路径必须被认出来（说明 imagePaths 的键约定一致：
    // 识图步骤用 step.id，旧格式单模板分支用分支 id）
    expect(output, contains('模板图片: 引用 2 个'));
  });

  test('带痒痒鼠模式的流程会被运行器拦下（时空版不内置任务脚本）', () async {
    final List<CustomFlowStep> steps = <CustomFlowStep>[
      const CustomFlowStep(
        id: 's1',
        type: CustomFlowStepType.gameMode,
        label: '痒痒鼠模式',
      ),
    ];
    final String configPath =
        writeConfig('bad_flow.json', customFlowConfig(steps));

    final ProcessResult result = await _runRunner(_flowRunner, configPath);
    final String output = '${result.stdout}\n${result.stderr}';
    expect(result.exitCode, 1, reason: output);
    expect(output, contains('痒痒鼠模式'));
    expect(output, contains('不支持'));
  });

  test('缺模板图片的流程会被拦下（用户不用等跑起来才发现）', () async {
    final List<CustomFlowStep> steps = <CustomFlowStep>[
      const CustomFlowStep(
        id: 'tpl-missing',
        type: CustomFlowStepType.imageTap,
        label: '识图点击',
        templateName: '不存在',
        templatePath: '/nowhere/not_here.png',
      ),
    ];
    final Map<String, dynamic> config = customFlowConfig(steps);
    (config['imagePaths'] as Map<String, String>)['tpl-missing'] =
        '/nowhere/not_here.png';
    final String configPath = writeConfig('missing_tpl.json', config);

    final ProcessResult result = await _runRunner(_flowRunner, configPath);
    final String output = '${result.stdout}\n${result.stderr}';
    expect(result.exitCode, 1, reason: output);
    expect(output, contains('模板图片文件不存在'));
  });

  test('录制流程 JSON 能被真实回放器读懂', () async {
    final RecordedFlow flow = RecordedFlow(
      name: '排队',
      deviceId: 'win:1111',
      touchDevicePath: '',
      screenWidth: 1600,
      screenHeight: 900,
      createdAt: DateTime.utc(2026, 1, 1),
      actions: <RecordedAction>[
        const RecordedAction(
          type: RecordedActionType.tap,
          delayMs: 100,
          startX: 10,
          startY: 20,
          endX: 10,
          endY: 20,
          durationMs: 120,
          holdBeforeMoveMs: 0,
          dragPath: <RecordedPathPoint>[],
          rawEvents: <RawInputEvent>[],
        ),
        const RecordedAction(
          type: RecordedActionType.longPressSwipe,
          delayMs: 400,
          startX: 100,
          startY: 100,
          endX: 200,
          endY: 200,
          durationMs: 600,
          holdBeforeMoveMs: 400,
          dragPath: <RecordedPathPoint>[],
          rawEvents: <RawInputEvent>[],
        ),
      ],
    );

    // 界面侧录制回放真正写的字段（lib/main.dart 的 recorded_flow_config.json）
    final String configPath = writeConfig('recorded_flow_config.json', {
      'deviceId': 'win:1111',
      'loopCount': 1,
      'flows': <Map<String, dynamic>>[flow.toJson()],
    });

    final ProcessResult result = await _runRunner(_recordRunner, configPath);
    final String output = '${result.stdout}\n${result.stderr}';
    expect(result.exitCode, 0, reason: output);
    expect(output, contains('自检通过'));
    expect(output, contains('排队'));
    expect(output, contains('动作合计 2 个'));
    expect(output, contains('录制分辨率 1600x900'));
  });

  test('界面的圆形录制流程（只有 tap）也能被读懂', () async {
    final RecordedFlow flow = RecordedFlow(
      name: '单点',
      deviceId: 'win:2222',
      touchDevicePath: '',
      screenWidth: 1280,
      screenHeight: 720,
      createdAt: DateTime.utc(2026, 1, 1),
      actions: <RecordedAction>[
        const RecordedAction(
          type: RecordedActionType.tap,
          delayMs: 0,
          startX: 1,
          startY: 2,
          endX: 1,
          endY: 2,
          durationMs: 120,
          holdBeforeMoveMs: 0,
          dragPath: <RecordedPathPoint>[],
          rawEvents: <RawInputEvent>[],
        ),
      ],
    );
    final String configPath = writeConfig('one_tap.json', {
      'deviceId': 'win:2222',
      'loopCount': 1,
      'flows': <Map<String, dynamic>>[flow.toJson()],
    });

    final ProcessResult result = await _runRunner(_recordRunner, configPath);
    final String output = '${result.stdout}\n${result.stderr}';
    expect(result.exitCode, 0, reason: output);
    expect(output, contains('动作合计 1 个'));
  });
}
