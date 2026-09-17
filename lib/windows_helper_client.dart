import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'win_workspace.dart';

/// 日志回调（界面里可以显示成"运行日志"）。
typedef HelperLogSink = void Function(String line);

/// 常驻服务 `tools/win_helper.py` 的 JSON-Lines 客户端。
///
/// 协议：一行一个 JSON 请求 `{"id":1,"cmd":"click","args":{...}}`，
/// 一行一个响应 `{"id":1,"ok":true,"data":{...},"error":null}`；日志走 stderr。
class WindowsHelperClient {
  WindowsHelperClient({
    required this.workspace,
    required this.pythonExecutable,
    this.logSink,
    this.defaultTimeout = const Duration(seconds: 30),
  });

  final WinWorkspace workspace;
  final String pythonExecutable;
  final HelperLogSink? logSink;
  final Duration defaultTimeout;

  Process? _process;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  final Map<int, Completer<Map<String, dynamic>>> _pending =
      <int, Completer<Map<String, dynamic>>>{};
  final List<String> _stderrTail = <String>[];
  Future<void>? _starting;
  Future<void> _writeQueue = Future<void>.value();
  int _nextId = 1;
  bool _stopping = false;

  bool get isRunning => _process != null;

  /// 启动常驻服务（并发调用只会启动一次）。
  Future<void> ensureStarted() {
    if (_process != null) {
      return Future<void>.value();
    }
    final pendingStart = _starting;
    if (pendingStart != null) {
      return pendingStart;
    }
    final future = _start();
    _starting = future;
    return future.whenComplete(() {
      _starting = null;
    });
  }

  Future<void> _start() async {
    if (!workspace.isAvailable) {
      throw Exception(workspace.missingHint);
    }
    final process = await Process.start(
      pythonExecutable,
      <String>[workspace.helperScript],
      workingDirectory: workspace.root,
      runInShell: Platform.isWindows,
    );
    _process = process;
    _stopping = false;
    _stderrTail.clear();
    _stdoutSubscription = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleStdoutLine, onError: (Object error) {
      _log('控制服务输出异常：$error');
    });
    _stderrSubscription = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleStderrLine);
    unawaited(process.exitCode.then((int code) {
      _handleExit(code);
    }));
    _log('已启动时空客户端控制服务（python=$pythonExecutable）');
  }

  void _handleStdoutLine(String line) {
    final text = line.trim();
    if (text.isEmpty) {
      return;
    }
    Map<String, dynamic> message;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        _log('控制服务输出（非协议）：$text');
        return;
      }
      message = decoded;
    } catch (_) {
      _log('控制服务输出（非 JSON）：$text');
      return;
    }
    final id = message['id'];
    if (id is! int) {
      _log('控制服务消息缺少 id：$text');
      return;
    }
    final completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) {
      return;
    }
    completer.complete(message);
  }

  void _handleStderrLine(String line) {
    final text = line.trimRight();
    if (text.trim().isEmpty) {
      return;
    }
    _stderrTail.add(text);
    if (_stderrTail.length > 40) {
      _stderrTail.removeAt(0);
    }
    _log(text);
  }

  void _handleExit(int code) {
    final wasStopping = _stopping;
    _process = null;
    _stopping = false;
    _stdoutSubscription?.cancel();
    _stderrSubscription?.cancel();
    _stdoutSubscription = null;
    _stderrSubscription = null;
    final reason = _stderrTail.isEmpty
        ? '控制服务已退出（退出码 $code）'
        : '控制服务已退出（退出码 $code）：${_stderrTail.last}';
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(Exception(reason));
      }
    }
    _pending.clear();
    if (!wasStopping) {
      _log(reason);
    }
  }

  void _log(String line) {
    logSink?.call(line);
  }

  /// 串行写入：Process.stdin 不允许并发 writeln/flush，同时保证一行一个完整请求。
  Future<void> _writeLine(String payload) {
    final next = _writeQueue.then((_) async {
      final process = _process;
      if (process == null) {
        throw Exception('控制服务未在运行');
      }
      process.stdin.writeln(payload);
      await process.stdin.flush();
    });
    _writeQueue = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  /// 发送一条命令并等待响应；[args] 会作为 `args` 字段传给服务。
  Future<Map<String, dynamic>> send(
    String command, {
    Map<String, dynamic> args = const <String, dynamic>{},
    Duration? timeout,
  }) async {
    await ensureStarted();
    final id = _nextId;
    _nextId += 1;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    final payload = jsonEncode(<String, dynamic>{
      'id': id,
      'cmd': command,
      'args': args,
    });
    await _writeLine(payload);
    Map<String, dynamic> response;
    try {
      response = await completer.future.timeout(timeout ?? defaultTimeout);
    } on TimeoutException {
      _pending.remove(id);
      throw Exception('控制服务命令超时（$command，${(timeout ?? defaultTimeout).inSeconds}s）');
    }
    if (response['ok'] != true) {
      final error = response['error'];
      throw Exception(
        error is String && error.trim().isNotEmpty
            ? error
            : '控制服务命令失败：$command',
      );
    }
    final data = response['data'];
    if (data is Map<String, dynamic>) {
      return data;
    }
    return <String, dynamic>{'value': data};
  }

  /// 关闭常驻服务（先发 shutdown，再兜底 kill）。
  Future<void> stop() async {
    final process = _process;
    if (process == null) {
      return;
    }
    _stopping = true;
    try {
      await send('shutdown', timeout: const Duration(seconds: 3));
    } catch (_) {
      // 服务可能已经退出或未响应，下面直接终止进程
    }
    try {
      process.kill();
    } catch (_) {
      // 忽略：进程可能已经结束
    }
    _process = null;
  }

  /// stderr 末尾若干行，用于展示诊断信息。
  List<String> get stderrTail => List<String>.unmodifiable(_stderrTail);
}

/// 面向界面的设备服务：把 helper 命令包装成带类型的调用。
class WindowsDeviceService {
  WindowsDeviceService(this.client);

  final WindowsHelperClient client;

  Future<Map<String, dynamic>> ping() => client.send('ping');

  Future<Map<String, dynamic>> health() =>
      client.send('health', timeout: const Duration(seconds: 60));

  Future<List<Map<String, dynamic>>> listDevices({bool includeOther = false}) async {
    final data = await client.send('list_devices', args: <String, dynamic>{
      'includeOther': includeOther,
    });
    final devices = data['devices'];
    if (devices is List) {
      return devices
          .whereType<Map<String, dynamic>>()
          .toList(growable: false);
    }
    return const <Map<String, dynamic>>[];
  }

  Future<List<String>> listDeviceIds({bool includeOther = false}) async {
    final devices = await listDevices(includeOther: includeOther);
    return devices
        .map((item) => (item['deviceId'] ?? '').toString())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }

  /// 截一帧到 [savePath]（默认归一化到设计分辨率），返回实际路径。
  Future<String> capture(
    String deviceId,
    String savePath, {
    bool normalize = true,
    String? method,
  }) async {
    final data = await client.send(
      'capture',
      args: <String, dynamic>{
        'deviceId': deviceId,
        'normalize': normalize,
        'savePath': savePath,
        if (method != null && method.isNotEmpty) 'method': method,
      },
      timeout: const Duration(seconds: 30),
    );
    return (data['path'] ?? savePath).toString();
  }

  /// 截一帧并返回 PNG base64（适合直接喂给 `Image.memory`）。
  Future<String> capturePngBase64(String deviceId, {bool normalize = true}) async {
    final data = await client.send(
      'capture',
      args: <String, dynamic>{
        'deviceId': deviceId,
        'normalize': normalize,
        'encode': 'png_base64',
      },
      timeout: const Duration(seconds: 30),
    );
    return (data['pngBase64'] ?? '').toString();
  }

  Future<Map<String, dynamic>> tap(String deviceId, int x, int y) =>
      client.send('click', args: <String, dynamic>{
        'deviceId': deviceId,
        'x': x,
        'y': y,
      });

  Future<Map<String, dynamic>> doubleTap(String deviceId, int x, int y) =>
      client.send('double_click', args: <String, dynamic>{
        'deviceId': deviceId,
        'x': x,
        'y': y,
      });

  Future<Map<String, dynamic>> swipe(
    String deviceId,
    int x1,
    int y1,
    int x2,
    int y2, {
    int durationMs = 300,
  }) =>
      client.send('swipe', args: <String, dynamic>{
        'deviceId': deviceId,
        'x1': x1,
        'y1': y1,
        'x2': x2,
        'y2': y2,
        'durationMs': durationMs,
      });

  Future<Map<String, dynamic>> inputText(String deviceId, String text) =>
      client.send('text', args: <String, dynamic>{
        'deviceId': deviceId,
        'text': text,
      });

  Future<Map<String, dynamic>> pressKey(String deviceId, int vk) =>
      client.send('key', args: <String, dynamic>{
        'deviceId': deviceId,
        'vk': vk,
      });

  Future<Map<String, dynamic>> activate(String deviceId) =>
      client.send('activate', args: <String, dynamic>{'deviceId': deviceId});

  Future<Map<String, dynamic>> ensureRunning(String deviceId, {int timeout = 120}) =>
      client.send(
        'ensure_running',
        args: <String, dynamic>{'deviceId': deviceId, 'timeout': timeout},
        timeout: Duration(seconds: timeout + 30),
      );

  Future<Map<String, dynamic>> startClient({String deviceId = ''}) =>
      client.send('start', args: <String, dynamic>{'deviceId': deviceId},
          timeout: const Duration(minutes: 3));

  Future<Map<String, dynamic>> stopClient(String deviceId) =>
      client.send('stop', args: <String, dynamic>{'deviceId': deviceId});

  Future<Map<String, dynamic>> restartClient(String deviceId) => client.send(
        'restart',
        args: <String, dynamic>{'deviceId': deviceId},
        timeout: const Duration(minutes: 3),
      );

  /// 把客户区调整到设计分辨率（[force] 为真时即使尺寸相同也重设）。
  Future<Map<String, dynamic>> resize(
    String deviceId, {
    int width = 1600,
    int height = 900,
    bool force = false,
  }) =>
      client.send('resize', args: <String, dynamic>{
        'deviceId': deviceId,
        'width': width,
        'height': height,
        'force': force,
      });

  Future<Map<String, dynamic>> probeCapture(String deviceId) => client.send(
        'probe_capture',
        args: <String, dynamic>{'deviceId': deviceId},
        timeout: const Duration(minutes: 2),
      );

  Future<Map<String, dynamic>> stats() => client.send('stats');

  /// 开始录制鼠标手势（全局低级钩子，录制期间由 helper 线程收集）。
  Future<Map<String, dynamic>> recordStart(String deviceId, {int sampleIntervalMs = 16}) =>
      client.send('record_start', args: <String, dynamic>{
        'deviceId': deviceId,
        'sampleIntervalMs': sampleIntervalMs,
      });

  /// 轮询录制进度（已录到的动作 + 状态）。
  Future<Map<String, dynamic>> recordPoll() => client.send('record_poll');

  /// 停止录制并取回动作列表。
  Future<Map<String, dynamic>> recordStop() =>
      client.send('record_stop', timeout: const Duration(seconds: 30));
}
