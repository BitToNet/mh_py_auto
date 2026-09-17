import 'custom_flow.dart';

/// 编辑流程时的"这一步有问题"提示。
///
/// 纯逻辑：不碰界面、不跑 Python。判定规则与运行器保持一致（第 11 轮吃过
/// "两边各写一套字段/规则"的亏）：
/// - 模板图能不能用 → 对应界面导出 `exportOne` 与运行器 `template_source_of`：
///   本地文件要有路径，内置图片要有名字；
/// - 文字识别要填目标文字 → 运行器 `run_ocr_tap` / `run_wait_ocr_state` 会直接报错；
/// - 逐行文本循环至少要一行字 → 运行器 `run_loop_block` 会直接报错；
/// - 痒痒鼠模式在时空客户端不支持 → 运行器 `UNSUPPORTED_STEP_TYPES`。
///
/// 运行前还有一道更权威的关卡（`flow_runner_win.py --dry-run`，界面上的
/// 「流程自检」按钮）；这里是让用户在**编辑时**就看到红字，不用等自检。
enum CustomFlowIssueLevel { error, warning }

class CustomFlowIssue {
  const CustomFlowIssue({
    required this.stepId,
    required this.location,
    required this.message,
    this.level = CustomFlowIssueLevel.error,
  });

  /// 出问题的步骤 id（用来在列表里定位到具体那一步）。
  final String stepId;

  /// 人能读的位置，例如 `第 2 步 › 第 1 步`。
  final String location;

  final String message;

  final CustomFlowIssueLevel level;

  bool get isError => level == CustomFlowIssueLevel.error;
}

/// 判定时需要的环境信息。
class CustomFlowLintContext {
  const CustomFlowLintContext({
    required this.windowsClientMode,
    this.availableRecordedFlows,
    this.fileExists,
  });

  /// 时空（Windows 客户端）模式：痒痒鼠模式步骤不可用。
  final bool windowsClientMode;

  /// 已保存的录制流程名。为 null 表示"还不知道"（比如列表没加载成功），
  /// 这时不检查录制流程是否存在，避免整篇报错。
  final Set<String>? availableRecordedFlows;

  /// 模板文件是否存在（界面传 `File(path).existsSync`；测试里可注入）。
  final bool Function(String path)? fileExists;
}

/// 走一遍流程，列出所有问题（含嵌套步骤与条件分支里的步骤）。
List<CustomFlowIssue> lintCustomFlowSteps(
  List<CustomFlowStep> steps,
  CustomFlowLintContext context,
) {
  final List<CustomFlowIssue> issues = <CustomFlowIssue>[];
  _walk(steps, '', context, issues);
  return issues;
}

/// 只检查一个步骤及其子树，`location` 是它在流程里的位置（如 `第 2 步`）。
///
/// 列表是按顶层步骤分卡片显示的，这个入口让每张卡片只关心自己子树里的问题。
List<CustomFlowIssue> lintCustomFlowStep(
  CustomFlowStep step,
  CustomFlowLintContext context, {
  String location = '第 1 步',
}) {
  final List<CustomFlowIssue> issues = <CustomFlowIssue>[];
  _checkStepAndChildren(step, location, context, issues);
  return issues;
}

/// 按步骤 id 归组，方便列表里那一步直接显示自己的红字。
Map<String, List<CustomFlowIssue>> groupCustomFlowIssuesByStepId(
  List<CustomFlowIssue> issues,
) {
  final Map<String, List<CustomFlowIssue>> grouped =
      <String, List<CustomFlowIssue>>{};
  for (final CustomFlowIssue issue in issues) {
    grouped.putIfAbsent(issue.stepId, () => <CustomFlowIssue>[]).add(issue);
  }
  return grouped;
}

/// 一句话概括（给顶部的提示条用）。
String describeCustomFlowIssues(List<CustomFlowIssue> issues) {
  if (issues.isEmpty) {
    return '';
  }
  final int errors = issues.where((CustomFlowIssue item) => item.isError).length;
  final int warnings = issues.length - errors;
  final List<String> parts = <String>[];
  if (errors > 0) {
    parts.add('$errors 个步骤有问题');
  }
  if (warnings > 0) {
    parts.add('$warnings 个提醒');
  }
  return parts.join('，');
}

void _walk(
  List<CustomFlowStep> steps,
  String parentLocation,
  CustomFlowLintContext context,
  List<CustomFlowIssue> issues,
) {
  for (int index = 0; index < steps.length; index++) {
    final CustomFlowStep step = steps[index];
    final String location = parentLocation.isEmpty
        ? '第 ${index + 1} 步'
        : '$parentLocation › 第 ${index + 1} 步';
    _checkStepAndChildren(step, location, context, issues);
  }
}

/// 检查一步 + 它的子步骤 + 它的条件分支。
void _checkStepAndChildren(
  CustomFlowStep step,
  String location,
  CustomFlowLintContext context,
  List<CustomFlowIssue> issues,
) {
  _checkStep(step, location, context, issues);
  _walk(step.children, location, context, issues);
  _walk(step.fallbackChildren, location, context, issues);
  for (int caseIndex = 0; caseIndex < step.branchCases.length; caseIndex++) {
    final CustomFlowBranchCase branchCase = step.branchCases[caseIndex];
    final String caseLocation = '$location › 分支 ${caseIndex + 1}';
    _checkBranchCase(step, branchCase, caseLocation, context, issues);
    _walk(branchCase.steps, caseLocation, context, issues);
  }
}

/// 模板图能不能用 —— 与运行器 `template_source_of` 同规则。
void _checkTemplateSource(
  CustomFlowStep step,
  String location,
  String subject,
  CustomFlowImageSource imageSource,
  String templateName,
  String templatePath,
  CustomFlowLintContext context,
  List<CustomFlowIssue> issues,
) {
  final String path = templatePath.trim();
  final String name = templateName.trim();
  if (imageSource == CustomFlowImageSource.localFile) {
    if (path.isEmpty) {
      issues.add(
        CustomFlowIssue(
          stepId: step.id,
          location: location,
          message: '$subject没有选择模板图片（本地图片要选一张图）',
        ),
      );
      return;
    }
  } else if (path.isEmpty && name.isEmpty) {
    issues.add(
      CustomFlowIssue(
        stepId: step.id,
        location: location,
        message: '$subject没有选择模板图片（内置图片要选一个名字）',
      ),
    );
    return;
  }
  final bool Function(String path)? fileExists = context.fileExists;
  if (path.isNotEmpty && fileExists != null && !fileExists(path)) {
    issues.add(
      CustomFlowIssue(
        stepId: step.id,
        location: location,
        message: '$subject的模板图片文件不存在：$path',
      ),
    );
  }
}

void _checkRecognizeTarget(
  CustomFlowStep step,
  String location,
  String subject,
  String ocrTargetText,
  List<CustomFlowIssue> issues,
) {
  if (ocrTargetText.trim().isEmpty) {
    issues.add(
      CustomFlowIssue(
        stepId: step.id,
        location: location,
        message: '$subject没有填写要识别的文字',
      ),
    );
  }
}

bool _isImageStep(CustomFlowStep step) {
  switch (step.type) {
    case CustomFlowStepType.imageTap:
    case CustomFlowStepType.waitImageState:
    case CustomFlowStepType.imagePositionBranch:
      return true;
    case CustomFlowStepType.loopBlock:
      return step.loopMode == CustomFlowLoopMode.imageCondition;
    default:
      return false;
  }
}

void _checkStep(
  CustomFlowStep step,
  String location,
  CustomFlowLintContext context,
  List<CustomFlowIssue> issues,
) {
  if (step.type == CustomFlowStepType.gameMode && context.windowsClientMode) {
    issues.add(
      CustomFlowIssue(
        stepId: step.id,
        location: location,
        message: '「痒痒鼠模式」在时空客户端上不支持，请删除这一步',
      ),
    );
    return;
  }

  if (_isImageStep(step)) {
    if (step.recognitionMode == CustomFlowRecognitionMode.text) {
      _checkRecognizeTarget(step, location, '这一步', step.ocrTargetText, issues);
    } else {
      _checkTemplateSource(
        step,
        location,
        '这一步',
        step.imageSource,
        step.templateName,
        step.templatePath,
        context,
        issues,
      );
    }
  }

  if (step.type == CustomFlowStepType.ocrTap &&
      step.ocrTargetText.trim().isEmpty) {
    _checkRecognizeTarget(step, location, '这一步', step.ocrTargetText, issues);
  }

  if (step.type == CustomFlowStepType.recordedFlow) {
    final String name = step.recordedFlowName.trim();
    if (name.isEmpty) {
      issues.add(
        CustomFlowIssue(
          stepId: step.id,
          location: location,
          message: '这一步没有选择要执行的录制流程',
        ),
      );
    } else if (context.availableRecordedFlows != null &&
        !context.availableRecordedFlows!.contains(name)) {
      issues.add(
        CustomFlowIssue(
          stepId: step.id,
          location: location,
          message: '录制流程不存在：$name（先刷新「已保存流程」列表再选一次）',
        ),
      );
    }
  }

  if (step.type == CustomFlowStepType.pasteText) {
    if (!step.useParentLoopText && step.textContent.trim().isEmpty) {
      issues.add(
        CustomFlowIssue(
          stepId: step.id,
          location: location,
          message: '这一步没有填写要粘贴的文字',
          level: CustomFlowIssueLevel.warning,
        ),
      );
    }
  }

  if (step.type == CustomFlowStepType.loopBlock) {
    if (step.loopMode == CustomFlowLoopMode.textLines &&
        _splitTextLines(step.loopTextContent).isEmpty) {
      issues.add(
        CustomFlowIssue(
          stepId: step.id,
          location: location,
          message: '按文本逐行循环至少要填一行文字',
        ),
      );
    } else if (step.loopMode == CustomFlowLoopMode.fixedCount &&
        step.loopCount <= 0) {
      issues.add(
        CustomFlowIssue(
          stepId: step.id,
          location: location,
          message: '循环次数为 0，会一直循环下去',
          level: CustomFlowIssueLevel.warning,
        ),
      );
    }
  }
}

void _checkBranchCase(
  CustomFlowStep step,
  CustomFlowBranchCase branchCase,
  String caseLocation,
  CustomFlowLintContext context,
  List<CustomFlowIssue> issues,
) {
  final String caseName = branchCase.label.trim().isEmpty
      ? '条件分支'
      : '条件分支「${branchCase.label.trim()}」';
  if (branchCase.recognitionMode == CustomFlowRecognitionMode.text) {
    _checkRecognizeTarget(
      step,
      caseLocation,
      caseName,
      branchCase.ocrTargetText,
      issues,
    );
    return;
  }
  final List<CustomFlowBranchImage> images = branchCase.effectiveTemplateImages;
  if (images.isEmpty) {
    issues.add(
      CustomFlowIssue(
        stepId: step.id,
        location: caseLocation,
        message: '$caseName没有配模板图片（这个分支永远不会命中）',
      ),
    );
    return;
  }
  for (final CustomFlowBranchImage image in images) {
    _checkTemplateSource(
      step,
      caseLocation,
      caseName,
      image.imageSource,
      image.templateName,
      image.templatePath,
      context,
      issues,
    );
  }
}

/// 与运行器 `split_text_lines` 同规则：按行切，去掉空行。
List<String> _splitTextLines(String text) {
  return text
      .split(RegExp(r'\r?\n'))
      .map((String line) => line.trim())
      .where((String line) => line.isNotEmpty)
      .toList();
}
