import 'package:ai/custom_flow.dart';
import 'package:ai/custom_flow_lint.dart';
import 'package:flutter_test/flutter_test.dart';

/// 编辑期提示的纯逻辑测试：规则必须和运行器一致，
/// 否则用户会被"红字"骗着改一堆没问题的步骤。
CustomFlowLintContext context({
  bool windowsClientMode = false,
  Set<String>? recordedFlows,
  Set<String> missingFiles = const <String>{},
}) {
  return CustomFlowLintContext(
    windowsClientMode: windowsClientMode,
    availableRecordedFlows: recordedFlows,
    fileExists: (String path) => !missingFiles.contains(path),
  );
}

CustomFlowStep imageTap({
  String id = 's1',
  CustomFlowImageSource source = CustomFlowImageSource.localFile,
  String templatePath = '/tmp/a.png',
  String templateName = '开始按钮',
}) {
  return CustomFlowStep(
    id: id,
    type: CustomFlowStepType.imageTap,
    label: '识图点击',
    imageSource: source,
    templatePath: templatePath,
    templateName: templateName,
  );
}

List<String> messages(List<CustomFlowIssue> issues) =>
    issues.map((CustomFlowIssue item) => item.message).toList();

void main() {
  test('正常流程没有任何提示', () {
    final List<CustomFlowIssue> issues = lintCustomFlowSteps(<CustomFlowStep>[
      const CustomFlowStep(
        id: 'w',
        type: CustomFlowStepType.wait,
        label: '等待',
      ),
      imageTap(),
      const CustomFlowStep(
        id: 'c',
        type: CustomFlowStepType.coordinateTap,
        label: '坐标点击',
        x: 800,
        y: 450,
      ),
    ], context());
    expect(issues, isEmpty);
  });

  test('痒痒鼠模式：时空模式下报错，模拟器模式不报', () {
    final List<CustomFlowStep> steps = <CustomFlowStep>[
      const CustomFlowStep(
        id: 'g',
        type: CustomFlowStepType.gameMode,
        label: '痒痒鼠模式',
      ),
    ];
    expect(lintCustomFlowSteps(steps, context()), isEmpty);
    final List<CustomFlowIssue> issues = lintCustomFlowSteps(
      steps,
      context(windowsClientMode: true),
    );
    expect(issues.single.message, contains('在时空客户端上不支持'));
    expect(issues.single.isError, isTrue);
    expect(issues.single.location, '第 1 步');
  });

  test('本地模板没选文件时报错（界面根本不会导出这张图）', () {
    final List<CustomFlowIssue> issues = lintCustomFlowSteps(
      <CustomFlowStep>[imageTap(templatePath: '')],
      context(),
    );
    expect(issues.single.message, contains('没有选择模板图片'));
    expect(issues.single.message, contains('本地图片'));
  });

  test('本地模板文件不在了要报出来', () {
    final List<CustomFlowIssue> issues = lintCustomFlowSteps(
      <CustomFlowStep>[imageTap(templatePath: '/tmp/gone.png')],
      context(missingFiles: <String>{'/tmp/gone.png'}),
    );
    expect(issues.single.message, contains('模板图片文件不存在'));
    expect(issues.single.message, contains('/tmp/gone.png'));
  });

  test('内置模板只要有名字就行', () {
    expect(
      lintCustomFlowSteps(<CustomFlowStep>[
        imageTap(
          source: CustomFlowImageSource.asset,
          templatePath: '',
          templateName: '开始按钮',
        ),
      ], context()),
      isEmpty,
    );
    final List<CustomFlowIssue> issues = lintCustomFlowSteps(
      <CustomFlowStep>[
        imageTap(
          source: CustomFlowImageSource.asset,
          templatePath: '',
          templateName: '',
        ),
      ],
      context(),
    );
    expect(issues.single.message, contains('内置图片'));
  });

  test('文字识别模式要填目标文字', () {
    final List<CustomFlowIssue> issues = lintCustomFlowSteps(
      <CustomFlowStep>[
        const CustomFlowStep(
          id: 't',
          type: CustomFlowStepType.imageTap,
          label: '识图点击',
          recognitionMode: CustomFlowRecognitionMode.text,
        ),
        const CustomFlowStep(
          id: 'o',
          type: CustomFlowStepType.ocrTap,
          label: '文字识别点击',
        ),
      ],
      context(),
    );
    expect(issues, hasLength(2));
    expect(messages(issues).every((String m) => m.contains('没有填写要识别的文字')), isTrue);
  });

  test('录制流程：没选 / 不存在 / 列表未知时不乱报', () {
    List<CustomFlowIssue> lint(Set<String>? available, String name) {
      return lintCustomFlowSteps(<CustomFlowStep>[
        CustomFlowStep(
          id: 'r',
          type: CustomFlowStepType.recordedFlow,
          label: '录制流程',
          recordedFlowName: name,
        ),
      ], context(recordedFlows: available));
    }

    expect(lint(<String>{'出招'}, '').single.message, contains('没有选择'));
    expect(lint(<String>{'出招'}, '连招').single.message, contains('录制流程不存在'));
    expect(lint(null, '连招'), isEmpty, reason: '列表未知时不该报"不存在"');
    expect(lint(<String>{'出招'}, '出招'), isEmpty);
  });

  test('粘贴文字空内容只是提醒（运行器会照样清空输入框）', () {
    final List<CustomFlowIssue> issues = lintCustomFlowSteps(
      <CustomFlowStep>[
        const CustomFlowStep(
          id: 'p',
          type: CustomFlowStepType.pasteText,
          label: '粘贴文字',
        ),
        const CustomFlowStep(
          id: 'p2',
          type: CustomFlowStepType.pasteText,
          label: '粘贴文字',
          useParentLoopText: true,
        ),
      ],
      context(),
    );
    expect(issues.single.isError, isFalse);
    expect(issues.single.message, contains('没有填写要粘贴的文字'));
  });

  test('循环块：逐行文本没内容是错误，次数为 0 是提醒', () {
    final List<CustomFlowIssue> textLoop = lintCustomFlowSteps(
      <CustomFlowStep>[
        const CustomFlowStep(
          id: 'l',
          type: CustomFlowStepType.loopBlock,
          label: '循环块',
          loopMode: CustomFlowLoopMode.textLines,
          loopTextContent: ' \n  \n',
        ),
      ],
      context(),
    );
    expect(textLoop.single.isError, isTrue);
    expect(textLoop.single.message, contains('至少要填一行文字'));

    final List<CustomFlowIssue> zeroLoop = lintCustomFlowSteps(
      <CustomFlowStep>[
        const CustomFlowStep(
          id: 'l2',
          type: CustomFlowStepType.loopBlock,
          label: '循环块',
          loopCount: 0,
        ),
      ],
      context(),
    );
    expect(zeroLoop.single.isError, isFalse);
    expect(zeroLoop.single.message, contains('会一直循环'));
  });

  test('嵌套步骤的位置能说清是第几步里的第几步', () {
    final List<CustomFlowIssue> issues = lintCustomFlowSteps(
      <CustomFlowStep>[
        const CustomFlowStep(
          id: 'loop',
          type: CustomFlowStepType.loopBlock,
          label: '循环块',
          loopCount: 3,
          children: <CustomFlowStep>[
            CustomFlowStep(
              id: 'inner',
              type: CustomFlowStepType.imageTap,
              label: '识图点击',
              templatePath: '',
            ),
          ],
        ),
      ],
      context(),
    );
    expect(issues.single.location, '第 1 步 › 第 1 步');
    expect(issues.single.stepId, 'inner');
  });

  test('条件分支：没配模板 / 文字模式没填字 / 顺带查文件在不在', () {
    CustomFlowStep branch(List<CustomFlowBranchCase> cases) {
      return CustomFlowStep(
        id: 'b',
        type: CustomFlowStepType.imageBranch,
        label: '多图条件分支',
        branchCases: cases,
      );
    }

    final List<CustomFlowIssue> noTemplate = lintCustomFlowSteps(
      <CustomFlowStep>[
        branch(<CustomFlowBranchCase>[
          const CustomFlowBranchCase(id: 'c1', label: '战斗'),
        ]),
      ],
      context(),
    );
    expect(noTemplate.single.message, contains('条件分支「战斗」没有配模板图片'));
    expect(noTemplate.single.location, '第 1 步 › 分支 1');

    final List<CustomFlowIssue> textCase = lintCustomFlowSteps(
      <CustomFlowStep>[
        branch(<CustomFlowBranchCase>[
          const CustomFlowBranchCase(
            id: 'c2',
            label: '弹窗',
            recognitionMode: CustomFlowRecognitionMode.text,
          ),
        ]),
      ],
      context(),
    );
    expect(textCase.single.message, contains('「弹窗」'));
    expect(textCase.single.message, contains('没有填写要识别的文字'));

    final List<CustomFlowIssue> missingFile = lintCustomFlowSteps(
      <CustomFlowStep>[
        branch(<CustomFlowBranchCase>[
          CustomFlowBranchCase(
            id: 'c3',
            label: '战斗',
            templateImages: const <CustomFlowBranchImage>[
              CustomFlowBranchImage(id: 'c3', templatePath: '/tmp/ok.png'),
              CustomFlowBranchImage(id: 'c3-2', templatePath: '/tmp/gone.png'),
            ],
          ),
        ]),
      ],
      context(missingFiles: <String>{'/tmp/gone.png'}),
    );
    expect(missingFile.single.message, contains('/tmp/gone.png'));
  });

  test('按步骤归组 + 一句话概括', () {
    final List<CustomFlowIssue> issues = lintCustomFlowSteps(
      <CustomFlowStep>[
        const CustomFlowStep(
          id: 'g',
          type: CustomFlowStepType.gameMode,
          label: '痒痒鼠模式',
        ),
        const CustomFlowStep(
          id: 'p',
          type: CustomFlowStepType.pasteText,
          label: '粘贴文字',
        ),
      ],
      context(windowsClientMode: true),
    );
    expect(describeCustomFlowIssues(issues), '1 个步骤有问题，1 个提醒');
    final Map<String, List<CustomFlowIssue>> grouped =
        groupCustomFlowIssuesByStepId(issues);
    expect(grouped.keys.toSet(), <String>{'g', 'p'});
    expect(grouped['g']!.single.isError, isTrue);
    expect(describeCustomFlowIssues(<CustomFlowIssue>[]), '');
  });
}
