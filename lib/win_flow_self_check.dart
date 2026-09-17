import 'dart:convert';
import 'dart:io';

/// 一次流程自检的结果。
class FlowSelfCheckResult {
  const FlowSelfCheckResult({
    required this.exitCode,
    required this.output,
    required this.configPath,
  });

  final int exitCode;

  /// 运行器的 stdout + stderr（原样展示给用户，里面已经是人话）。
  final String output;

  final String configPath;

  bool get ok => exitCode == 0;

  /// 问题行的摘要（运行器用 `！` 开头标出每条问题）。
  List<String> get problems => output
      .split('\n')
      .map((String line) => line.trim())
      .where((String line) => line.startsWith('！'))
      .toList();

  String get summary {
    if (ok) {
      return '自检通过';
    }
    if (problems.isEmpty) {
      return '自检未通过';
    }
    return '自检未通过：${problems.first.replaceFirst('！', '')}';
  }
}

/// 时空客户端：把流程配置交给运行器做**离线**自检（`--dry-run`）。
///
/// 只读配置文件：不连窗口、不点游戏、不需要设备在线。抽成独立类是为了能脱离
/// 界面直接测——界面上的按钮只负责"写配置 → 调用 → 展示结果"。
class WinFlowSelfCheck {
  const WinFlowSelfCheck({
    required this.pythonExecutable,
    required this.scriptPath,
    required this.workingDirectory,
    this.timeout = const Duration(seconds: 120),
  });

  final String pythonExecutable;

  /// `flow_runner_win.py` 或 `record_runner_win.py` 的路径。
  final String scriptPath;

  /// 运行器工作目录（时空客户端版本从仓库根目录跑）。
  final String workingDirectory;

  final Duration timeout;

  /// 写配置文件 → 跑 `--dry-run` → 返回结果（不抛异常，失败也返回结果）。
  Future<FlowSelfCheckResult> check({
    required Map<String, dynamic> config,
    required Directory workDir,
    String fileName = 'custom_flow_config.json',
  }) async {
    final File configFile = File('${workDir.path}/$fileName');
    await configFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(config),
    );
    final ProcessResult result = await Process.run(
      pythonExecutable,
      <String>[scriptPath, configFile.path, '--dry-run'],
      workingDirectory: workingDirectory,
    ).timeout(timeout);
    final String stdout = result.stdout.toString();
    final String stderr = result.stderr.toString();
    final StringBuffer buffer = StringBuffer(stdout);
    if (stderr.trim().isNotEmpty) {
      if (!stdout.endsWith('\n')) {
        buffer.write('\n');
      }
      buffer.write(stderr);
    }
    return FlowSelfCheckResult(
      exitCode: result.exitCode,
      output: buffer.toString(),
      configPath: configFile.path,
    );
  }
}
