import 'dart:io';

import 'package:flutter/services.dart';

/// 定位时空 Windows 版所需的 Python 侧文件（设备层 + 常驻服务 + 流程运行器）。
///
/// 开发态：从工程根目录（`flutter run` 的工作目录）向上找 `scripts/win/win_device.py`。
/// 发布态：从可执行文件目录向上找；再找不到就把 pubspec 里打进 assets 的脚本
/// 解包到运行目录使用（见 [materializeFromAssets]）。
/// 三条路都走不通时给出明确指引，不做静默降级。
class WinWorkspace {
  WinWorkspace._(this.root);

  /// 直接指定工程根目录（用户设置、测试用）。
  factory WinWorkspace.at(String root) => WinWorkspace._(root);

  /// 工程根目录（绝对路径）。
  final String root;

  static const List<String> _markerFiles = <String>[
    'scripts/win/win_device.py',
    'tools/win_helper.py',
  ];

  /// 发布版解包时需要复制的脚本（必须与 pubspec.yaml 的 assets 声明一致）。
  static const List<String> bundledFiles = <String>[
    'scripts/win/win_api.py',
    'scripts/win/win_window.py',
    'scripts/win/win_capture.py',
    'scripts/win/win_input.py',
    'scripts/win/win_device.py',
    'scripts/win/win_replay.py',
    'scripts/win/win_record.py',
    'scripts/win/flow_runner_win.py',
    'scripts/win/record_runner_win.py',
    'tools/win_helper.py',
    'config/win_backend.example.json',
  ];

  static WinWorkspace? _cached;

  /// 查找工程根目录；[overrideRoot] 来自用户设置，优先使用。
  ///
  /// [includeFallbacks] 为真时（默认）额外尝试当前工作目录与可执行文件目录，
  /// 方便发布版从 `build/windows/.../Release` 往上找到工程根。
  static WinWorkspace? locate({
    String? overrideRoot,
    Directory? startDirectory,
    bool includeFallbacks = true,
  }) {
    final candidates = <String>[
      if (overrideRoot != null && overrideRoot.trim().isNotEmpty) overrideRoot.trim(),
      if (startDirectory != null) startDirectory.path,
      if (includeFallbacks) Directory.current.path,
      if (includeFallbacks) File(Platform.resolvedExecutable).parent.path,
    ];
    for (final candidate in candidates) {
      final found = _searchUpwards(candidate);
      if (found != null) {
        return WinWorkspace._(found);
      }
    }
    return null;
  }

  /// 带缓存的查找，避免每次调用都扫目录。
  static WinWorkspace? locateCached({String? overrideRoot, Directory? startDirectory}) {
    final cached = _cached;
    if (cached != null && File(cached.helperScript).existsSync()) {
      return cached;
    }
    final found = locate(overrideRoot: overrideRoot, startDirectory: startDirectory);
    _cached = found;
    return found;
  }

  /// 优先用工程目录，找不到就解包 assets（发布版路径）。
  static Future<WinWorkspace?> resolve({
    String? overrideRoot,
    Directory? startDirectory,
    Directory? runtimeDirectory,
  }) async {
    final onDisk = locateCached(overrideRoot: overrideRoot, startDirectory: startDirectory);
    if (onDisk != null && onDisk.isAvailable) {
      return onDisk;
    }
    if (runtimeDirectory == null) {
      return null;
    }
    return materializeFromAssets(runtimeDirectory);
  }

  static void resetCache() {
    _cached = null;
  }

  /// 把打进 assets 的脚本解包到 [targetRoot]，返回可用的工作区（失败返回 null）。
  ///
  /// 发布版（安装包）里没有工程目录，靠这一步得到可执行的 Python 文件；
  /// 目标目录通常是应用支持目录下的 `win_runtime/`，每次启动覆盖写入以跟随版本。
  static Future<WinWorkspace?> materializeFromAssets(Directory targetRoot,
      {bool force = false}) async {
    final workspace = WinWorkspace.at(targetRoot.path);
    if (!force && workspace.isAvailable) {
      return workspace;
    }
    var written = 0;
    for (final relative in bundledFiles) {
      ByteData data;
      try {
        data = await rootBundle.load(relative);
      } catch (_) {
        // 该文件没被打进 assets：跳过（例如 example 配置被移除）
        continue;
      }
      final file = File('${targetRoot.path}/$relative');
      await file.parent.create(recursive: true);
      final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      await file.writeAsBytes(bytes, flush: true);
      written += 1;
    }
    if (written == 0 || !workspace.isAvailable) {
      return null;
    }
    _cached = workspace;
    return workspace;
  }

  /// 解包目录里的设备层配置（发布版给用户改后端顺序用）。
  String get bundledConfigExample => path('config/win_backend.example.json');

  /// 标记当前工作区来自 assets 解包（用于日志提示）。
  bool get isBundledRuntime => root.contains('win_runtime');

  static String? _searchUpwards(String path) {
    var directory = Directory(path).absolute;
    for (var depth = 0; depth < 8; depth += 1) {
      if (_markerFiles.every((item) => File('${directory.path}/$item').existsSync())) {
        return directory.path;
      }
      final parent = directory.parent;
      if (parent.path == directory.path) {
        break;
      }
      directory = parent;
    }
    return null;
  }

  String path(String relative) => '$root/$relative';

  String get helperScript => path('tools/win_helper.py');

  String get flowRunnerScript => path('scripts/win/flow_runner_win.py');

  String get recordRunnerScript => path('scripts/win/record_runner_win.py');

  String get backendConfigExample => path('config/win_backend.example.json');

  bool get isAvailable => File(helperScript).existsSync();

  /// 给用户看的缺失提示。
  String get missingHint =>
      '未找到时空客户端控制脚本。请把本项目放在完整工程目录下运行，'
      '或在设置里指定工程根目录（需要包含 scripts/win/win_device.py 与 tools/win_helper.py）。'
      '当前查找起点：${Directory.current.path}';

  @override
  String toString() => 'WinWorkspace($root)';
}
