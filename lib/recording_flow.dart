import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

enum RecordedActionType {
  down,
  move,
  up,
  cancel,
  tap,
  longPress,
  swipe,
  longPressSwipe,
}

class RawInputEvent {
  const RawInputEvent({
    required this.delayMs,
    required this.type,
    required this.code,
    required this.value,
  });

  final int delayMs;
  final int type;
  final int code;
  final int value;

  Map<String, dynamic> toJson() => {
    'delayMs': delayMs,
    'type': type,
    'code': code,
    'value': value,
  };

  factory RawInputEvent.fromJson(Map<String, dynamic> json) {
    return RawInputEvent(
      delayMs: (json['delayMs'] as num?)?.toInt() ?? 0,
      type: (json['type'] as num?)?.toInt() ?? 0,
      code: (json['code'] as num?)?.toInt() ?? 0,
      value: (json['value'] as num?)?.toInt() ?? 0,
    );
  }
}

class RecordedPathPoint {
  const RecordedPathPoint({
    required this.x,
    required this.y,
    required this.delayMs,
  });

  final int x;
  final int y;
  final int delayMs;

  Map<String, dynamic> toJson() => {'x': x, 'y': y, 'delayMs': delayMs};

  factory RecordedPathPoint.fromJson(Map<String, dynamic> json) {
    return RecordedPathPoint(
      x: (json['x'] as num?)?.toInt() ?? 0,
      y: (json['y'] as num?)?.toInt() ?? 0,
      delayMs: (json['delayMs'] as num?)?.toInt() ?? 0,
    );
  }
}

class RecordedAction {
  const RecordedAction({
    required this.type,
    required this.delayMs,
    required this.startX,
    required this.startY,
    required this.endX,
    required this.endY,
    required this.durationMs,
    required this.holdBeforeMoveMs,
    required this.dragPath,
    required this.rawEvents,
  });

  final RecordedActionType type;
  final int delayMs;
  final int startX;
  final int startY;
  final int endX;
  final int endY;
  final int durationMs;
  final int holdBeforeMoveMs;
  final List<RecordedPathPoint> dragPath;
  final List<RawInputEvent> rawEvents;

  bool get isPointerEvent =>
      type == RecordedActionType.down ||
      type == RecordedActionType.move ||
      type == RecordedActionType.up ||
      type == RecordedActionType.cancel;

  Map<String, dynamic> toJson() => {
    'type': type.name,
    'delayMs': delayMs,
    'startX': startX,
    'startY': startY,
    'endX': endX,
    'endY': endY,
    'durationMs': durationMs,
    'holdBeforeMoveMs': holdBeforeMoveMs,
    'dragPath': dragPath.map((item) => item.toJson()).toList(),
    'rawEvents': rawEvents.map((item) => item.toJson()).toList(),
  };

  factory RecordedAction.fromJson(Map<String, dynamic> json) {
    return RecordedAction(
      type: RecordedActionType.values.firstWhere(
        (item) => item.name == json['type'],
        orElse: () => RecordedActionType.tap,
      ),
      delayMs: (json['delayMs'] as num?)?.toInt() ?? 0,
      startX: (json['startX'] as num?)?.toInt() ?? 0,
      startY: (json['startY'] as num?)?.toInt() ?? 0,
      endX: (json['endX'] as num?)?.toInt() ?? 0,
      endY: (json['endY'] as num?)?.toInt() ?? 0,
      durationMs: (json['durationMs'] as num?)?.toInt() ?? 120,
      holdBeforeMoveMs: (json['holdBeforeMoveMs'] as num?)?.toInt() ?? 0,
      dragPath: ((json['dragPath'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(RecordedPathPoint.fromJson)
          .toList(),
      rawEvents: ((json['rawEvents'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(RawInputEvent.fromJson)
          .toList(),
    );
  }
}

class RecordedFlow {
  const RecordedFlow({
    required this.name,
    required this.deviceId,
    required this.touchDevicePath,
    required this.screenWidth,
    required this.screenHeight,
    required this.createdAt,
    required this.actions,
  });

  final String name;
  final String deviceId;
  final String touchDevicePath;
  final int screenWidth;
  final int screenHeight;
  final DateTime createdAt;
  final List<RecordedAction> actions;

  RecordedFlow copyWith({String? name}) {
    return RecordedFlow(
      name: name ?? this.name,
      deviceId: deviceId,
      touchDevicePath: touchDevicePath,
      screenWidth: screenWidth,
      screenHeight: screenHeight,
      createdAt: createdAt,
      actions: actions,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'deviceId': deviceId,
    'touchDevicePath': touchDevicePath,
    'screenWidth': screenWidth,
    'screenHeight': screenHeight,
    'createdAt': createdAt.toIso8601String(),
    'actions': actions.map((item) => item.toJson()).toList(),
  };

  factory RecordedFlow.fromJson(Map<String, dynamic> json) {
    final rawActions = json['actions'] as List<dynamic>? ?? const [];
    return RecordedFlow(
      name: json['name']?.toString() ?? '未命名流程',
      deviceId: json['deviceId']?.toString() ?? '',
      touchDevicePath: json['touchDevicePath']?.toString() ?? '',
      screenWidth: (json['screenWidth'] as num?)?.toInt() ?? 0,
      screenHeight: (json['screenHeight'] as num?)?.toInt() ?? 0,
      createdAt:
          DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
          DateTime.now(),
      actions: rawActions
          .whereType<Map<String, dynamic>>()
          .map(RecordedAction.fromJson)
          .toList(),
    );
  }
}

class TouchBounds {
  const TouchBounds({
    required this.devicePath,
    required this.maxX,
    required this.maxY,
  });

  final String devicePath;
  final int maxX;
  final int maxY;
}

class ScreenSize {
  const ScreenSize({required this.width, required this.height});

  final int width;
  final int height;

  bool get isValid => width > 0 && height > 0;

  bool get isSupportedAutomationResolution =>
      (width == 1600 && height == 900) || (width == 900 && height == 1600);

  (int, int) scalePointTo({
    required int x,
    required int y,
    required ScreenSize target,
  }) {
    if (!isValid || !target.isValid) {
      return (x, y);
    }
    final scaledX = (x / width * target.width).round();
    final scaledY = (y / height * target.height).round();
    return (
      scaledX.clamp(0, target.width).toInt(),
      scaledY.clamp(0, target.height).toInt(),
    );
  }

  static ScreenSize? tryParseWmSizeOutput(String output) {
    final overrideMatch = RegExp(
      r'Override size:\s*(\d+)x(\d+)',
      caseSensitive: false,
    ).firstMatch(output);
    final physicalMatch = RegExp(
      r'Physical size:\s*(\d+)x(\d+)',
      caseSensitive: false,
    ).firstMatch(output);
    final match = overrideMatch ?? physicalMatch;
    if (match == null) {
      return null;
    }
    return ScreenSize(
      width: int.parse(match.group(1)!),
      height: int.parse(match.group(2)!),
    );
  }
}

class RecordingSessionResult {
  const RecordingSessionResult({required this.flow, required this.filePath});

  final RecordedFlow flow;
  final String filePath;
}

class ParseAttemptResult {
  const ParseAttemptResult({
    required this.devicePath,
    required this.actions,
    required this.debugSummary,
  });

  final String devicePath;
  final List<RecordedAction> actions;
  final String debugSummary;
}

class TouchRecorderService {
  static const int _defaultPointerSlot = 0;
  static const int _defaultTrackingId = 1;
  static const String exportFileExtension = 'rflowpkg';
  static const int _defaultDragPathSampleIntervalMs = 16;

  TouchRecorderService({Directory? flowDirectory})
    : _configuredFlowDirectory = flowDirectory;

  final Directory? _configuredFlowDirectory;
  Process? _recordingProcess;
  final StringBuffer _recordingOutput = StringBuffer();
  final StreamController<String> _logController = StreamController.broadcast();
  int _dragPathSampleIntervalMs = _defaultDragPathSampleIntervalMs;
  bool _activeWindowsRecorder = false;
  DateTime? _windowsRecordingStartedAt;

  Stream<String> get logs => _logController.stream;

  bool get isRecording => _recordingProcess != null || _activeWindowsRecorder;

  Future<Directory> _ensureFlowDirectory() async {
    final configuredDirectory = _configuredFlowDirectory;
    if (configuredDirectory != null) {
      if (!await configuredDirectory.exists()) {
        await configuredDirectory.create(recursive: true);
      }
      return configuredDirectory;
    }

    Directory baseDir;
    if (Platform.isWindows) {
      final appDataPath = Platform.environment['APPDATA']?.trim();
      if (appDataPath != null && appDataPath.isNotEmpty) {
        baseDir = Directory(p.join(appDataPath, 'FeloneConfs'));
      } else {
        baseDir = await getApplicationSupportDirectory();
      }
    } else {
      baseDir = await getApplicationSupportDirectory();
    }
    final flowDir = Directory('${baseDir.path}/recordings');
    if (!await flowDir.exists()) {
      await flowDir.create(recursive: true);
    }
    return flowDir;
  }

  String sanitizeFlowName(String value) {
    final sanitized = value
        .trim()
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), '_');
    if (sanitized.isEmpty) {
      return 'flow_${DateTime.now().millisecondsSinceEpoch}';
    }
    return sanitized;
  }

  Future<List<String>> listFlowNames() async {
    final dir = await _ensureFlowDirectory();
    final result = <String>[];
    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.json')) {
        result.add(entity.uri.pathSegments.last.replaceAll('.json', ''));
      }
    }
    result.sort();
    return result;
  }

  Future<RecordedFlow?> loadFlow(String name) async {
    final dir = await _ensureFlowDirectory();
    final file = File('${dir.path}/${sanitizeFlowName(name)}.json');
    if (!await file.exists()) {
      return null;
    }
    final jsonMap =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    return RecordedFlow.fromJson(jsonMap);
  }

  Future<String> saveFlow(RecordedFlow flow) async {
    final dir = await _ensureFlowDirectory();
    final file = File('${dir.path}/${sanitizeFlowName(flow.name)}.json');
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(flow.toJson()),
    );
    return file.path;
  }

  Future<void> exportFlowPackage({
    required RecordedFlow flow,
    required String exportPath,
  }) async {
    final sanitizedName = sanitizeFlowName(flow.name);
    final payload = {
      'version': 1,
      'exportedAt': DateTime.now().toIso8601String(),
      'flow': RecordedFlow(
        name: sanitizedName,
        deviceId: flow.deviceId,
        touchDevicePath: flow.touchDevicePath,
        screenWidth: flow.screenWidth,
        screenHeight: flow.screenHeight,
        createdAt: flow.createdAt,
        actions: flow.actions,
      ).toJson(),
    };
    final file = File(exportPath);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
    );
  }

  Future<String> _resolveAvailableFlowName(
    String desiredName, {
    String duplicateTag = 'import',
  }) async {
    final baseName = sanitizeFlowName(desiredName);
    final dir = await _ensureFlowDirectory();
    final directFile = File('${dir.path}/$baseName.json');
    if (!await directFile.exists()) {
      return baseName;
    }
    var index = 2;
    while (true) {
      final candidate = '${baseName}_${duplicateTag}_$index';
      final candidateFile = File('${dir.path}/$candidate.json');
      if (!await candidateFile.exists()) {
        return candidate;
      }
      index += 1;
    }
  }

  Future<RecordedFlow> saveFlowAsNew(
    RecordedFlow flow, {
    String duplicateTag = 'import',
  }) async {
    final finalName = await _resolveAvailableFlowName(
      flow.name,
      duplicateTag: duplicateTag,
    );
    final normalizedFlow = flow.copyWith(name: finalName);
    await saveFlow(normalizedFlow);
    return normalizedFlow;
  }

  Future<RecordedFlow> importFlowPackage(String packagePath) async {
    final file = File(packagePath);
    final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final flowJson = Map<String, dynamic>.from(
      raw['flow'] as Map? ?? const <String, dynamic>{},
    );
    final importedFlow = RecordedFlow.fromJson(flowJson);
    return saveFlowAsNew(importedFlow);
  }

  Future<bool> deleteFlow(String name) async {
    final dir = await _ensureFlowDirectory();
    final file = File('${dir.path}/${sanitizeFlowName(name)}.json');
    if (!await file.exists()) {
      return false;
    }
    await file.delete();
    return true;
  }

  Future<ScreenSize> getScreenSize(String deviceId) async {
    final result = await Process.run('adb', [
      '-s',
      deviceId,
      'shell',
      'wm',
      'size',
    ]);
    if (result.exitCode != 0) {
      throw Exception('获取屏幕分辨率失败: ${result.stderr}');
    }
    final screenSize = ScreenSize.tryParseWmSizeOutput(
      result.stdout.toString(),
    );
    if (screenSize == null) {
      throw Exception('无法解析屏幕分辨率: ${result.stdout}');
    }
    return screenSize;
  }

  Future<List<TouchBounds>> getTouchBoundsList(String deviceId) async {
    final result = await Process.run('adb', [
      '-s',
      deviceId,
      'shell',
      'getevent',
      '-lp',
    ]);
    if (result.exitCode != 0) {
      throw Exception('获取触摸设备信息失败: ${result.stderr}');
    }
    final lines = const LineSplitter().convert(result.stdout.toString());
    String? currentDevicePath;
    String? candidateDevicePath;
    int? maxX;
    int? maxY;
    final touchBoundsList = <TouchBounds>[];

    void commitCurrentDevice() {
      if (candidateDevicePath != null && maxX != null && maxY != null) {
        final devicePath = candidateDevicePath;
        final currentMaxX = maxX;
        final currentMaxY = maxY;
        touchBoundsList.add(
          TouchBounds(
            devicePath: devicePath,
            maxX: currentMaxX,
            maxY: currentMaxY,
          ),
        );
      }
    }

    for (final rawLine in lines) {
      final line = rawLine.trimRight();
      final deviceMatch = RegExp(r'add device \d+: (.+)$').firstMatch(line);
      if (deviceMatch != null) {
        commitCurrentDevice();
        currentDevicePath = deviceMatch.group(1)?.trim();
        candidateDevicePath = null;
        maxX = null;
        maxY = null;
        continue;
      }

      if (currentDevicePath == null) {
        continue;
      }

      if (line.contains('ABS_MT_POSITION_X') || line.contains('ABS_X')) {
        candidateDevicePath = currentDevicePath;
        maxX = _extractMaxValue(line);
      }
      if (line.contains('ABS_MT_POSITION_Y') || line.contains('ABS_Y')) {
        candidateDevicePath = currentDevicePath;
        maxY = _extractMaxValue(line);
      }
    }
    commitCurrentDevice();

    if (touchBoundsList.isEmpty) {
      throw Exception('未找到可用的触摸事件设备，请确认设备支持 getevent');
    }

    return touchBoundsList;
  }

  Future<TouchBounds> getTouchBounds(String deviceId) async {
    final touchBoundsList = await getTouchBoundsList(deviceId);
    return touchBoundsList.first;
  }

  int? _extractMaxValue(String line) {
    final match = RegExp(r'max\s+(\d+)').firstMatch(line);
    if (match != null) {
      return int.parse(match.group(1)!);
    }
    final fallback = RegExp(r'0x[0-9a-fA-F]+').allMatches(line).toList();
    if (fallback.isNotEmpty) {
      return int.parse(fallback.last.group(0)!.substring(2), radix: 16);
    }
    return null;
  }

  ParsedInputEvent? _parseInputEventLine(String line) {
    final match = RegExp(
      r'\[\s*(\d+\.\d+)\s*\]\s+(?:(/dev/input/\S+):\s+)?([0-9a-fA-F]{4})\s+([0-9a-fA-F]{4})\s+([0-9a-fA-F]{8})',
    ).firstMatch(line);
    if (match == null) {
      return null;
    }
    return ParsedInputEvent(
      timestamp: double.parse(match.group(1)!),
      devicePath: match.group(2) ?? '',
      type: int.parse(match.group(3)!, radix: 16),
      code: int.parse(match.group(4)!, radix: 16),
      value: _parseSigned32(match.group(5)!),
    );
  }

  int _parseSigned32(String hexValue) {
    final parsed = int.parse(hexValue, radix: 16);
    if (parsed > 0x7fffffff) {
      return parsed - 0x100000000;
    }
    return parsed;
  }

  Future<void> startRecording(
    String deviceId, {
    int? dragPathSampleIntervalMs,
  }) async {
    if (isRecording) {
      throw Exception('当前已有录制任务在进行中');
    }
    _dragPathSampleIntervalMs = _normalizeDragPathSampleIntervalMs(
      dragPathSampleIntervalMs,
    );
    _recordingOutput.clear();
    _recordingProcess = await Process.start('adb', [
      '-s',
      deviceId,
      'shell',
      'getevent',
      '-t',
    ]);
    _recordingProcess!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          _recordingOutput.writeln(line);
          _logController.add(line);
        });
    _recordingProcess!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          _recordingOutput.writeln(line);
          _logController.add(line);
        });
  }

  int _normalizeDragPathSampleIntervalMs(int? value) {
    if (value == null) {
      return _defaultDragPathSampleIntervalMs;
    }
    return value.clamp(8, 1000);
  }

  Future<RecordingSessionResult> stopRecording({
    required String flowName,
    required String deviceId,
  }) async {
    final process = _recordingProcess;
    if (process == null) {
      throw Exception('当前没有正在录制的流程');
    }

    process.kill();
    await process.exitCode.timeout(
      const Duration(seconds: 3),
      onTimeout: () => 0,
    );
    _recordingProcess = null;

    final touchBoundsList = await getTouchBoundsList(deviceId);
    final screenSize = await getScreenSize(deviceId);
    final attemptResults = touchBoundsList
        .map(
          (bounds) => parseRecording(
            recordingOutput: _recordingOutput.toString(),
            bounds: bounds,
            screenSize: screenSize,
          ),
        )
        .toList();
    attemptResults.sort(
      (left, right) => right.actions.length.compareTo(left.actions.length),
    );
    final bestAttempt = attemptResults.first;
    if (bestAttempt.actions.isEmpty) {
      throw Exception('没有解析到有效的触摸事件');
    }

    final flow = RecordedFlow(
      name: sanitizeFlowName(flowName),
      deviceId: deviceId,
      touchDevicePath: bestAttempt.devicePath,
      screenWidth: screenSize.width,
      screenHeight: screenSize.height,
      createdAt: DateTime.now(),
      actions: bestAttempt.actions,
    );
    final filePath = await saveFlow(flow);
    return RecordingSessionResult(flow: flow, filePath: filePath);
  }

  // ---------------------------------------------------------------------
  // Windows（时空客户端）：录制交给常驻服务里的全局鼠标钩子
  // ---------------------------------------------------------------------

  /// 开始录制：由 [recordStart] 安装 WH_MOUSE_LL，动作在设计分辨率坐标下采集。
  Future<void> startWindowsRecording(
    Future<Map<String, dynamic>> Function(int sampleIntervalMs) recordStart, {
    int? dragPathSampleIntervalMs,
  }) async {
    if (isRecording) {
      throw Exception('当前已有录制任务在进行中');
    }
    _activeWindowsRecorder = true;
    _dragPathSampleIntervalMs = _normalizeDragPathSampleIntervalMs(
      dragPathSampleIntervalMs,
    );
    try {
      final started = await recordStart(_dragPathSampleIntervalMs);
      _windowsRecordingStartedAt = DateTime.now();
      _logController.add('录制已开始：${started['device'] ?? ''}');
    } catch (e) {
      _activeWindowsRecorder = false;
      rethrow;
    }
  }

  /// 停止录制：把服务返回的动作列表落盘成与 Android 版完全一致的流程 JSON。
  Future<RecordingSessionResult> stopWindowsRecording({
    required String flowName,
    required String deviceId,
    required Future<Map<String, dynamic>> Function() recordStop,
  }) async {
    if (!_activeWindowsRecorder) {
      throw Exception('当前没有正在录制的流程');
    }
    _activeWindowsRecorder = false;
    final payload = await recordStop();
    final rawActions = (payload['actions'] as List<dynamic>?) ?? const <dynamic>[];
    final actions = rawActions
        .whereType<Map<String, dynamic>>()
        .map(RecordedAction.fromJson)
        .toList();
    if (actions.isEmpty) {
      throw Exception('没有录到有效的鼠标动作，请确认在客户端窗口上完成了点击或拖拽');
    }
    final flow = RecordedFlow(
      name: sanitizeFlowName(flowName),
      deviceId: deviceId,
      touchDevicePath: '',
      screenWidth: (payload['screenWidth'] as num?)?.toInt() ?? 1600,
      screenHeight: (payload['screenHeight'] as num?)?.toInt() ?? 900,
      createdAt: _windowsRecordingStartedAt ?? DateTime.now(),
      actions: actions,
    );
    final filePath = await saveFlow(flow);
    return RecordingSessionResult(flow: flow, filePath: filePath);
  }

  /// 录制中的实时动作（保存前可以先在界面上展示）。
  Future<List<RecordedAction>> pollWindowsRecording(
    Future<Map<String, dynamic>> Function() recordPoll,
  ) async {
    final payload = await recordPoll();
    final rawActions = (payload['actions'] as List<dynamic>?) ?? const <dynamic>[];
    return rawActions
        .whereType<Map<String, dynamic>>()
        .map(RecordedAction.fromJson)
        .toList();
  }

  ParseAttemptResult parseRecording({
    required String recordingOutput,
    required TouchBounds bounds,
    required ScreenSize screenSize,
  }) {
    final lines = const LineSplitter().convert(recordingOutput);
    final actions = <RecordedAction>[];
    double? previousGestureEndTime;
    double? previousRawEventTime;
    double? gestureStartTime;
    int? currentRawX;
    int? currentRawY;
    int? gestureStartRawX;
    int? gestureStartRawY;
    int? gestureLastRawX;
    int? gestureLastRawY;
    double? firstMoveTime;
    bool isTouching = false;
    bool moved = false;
    int totalLines = 0;
    int matchedDeviceLines = 0;
    int touchDownCount = 0;
    int touchUpCount = 0;
    int touchCancelCount = 0;
    int xUpdateCount = 0;
    int yUpdateCount = 0;
    final gestureRawEvents = <RawInputEvent>[];
    final gesturePathSamples = <TimedRawPoint>[];
    double? lastPathSampleTime;

    void appendGestureRawEvent(ParsedInputEvent event) {
      final eventDelayMs = previousRawEventTime == null
          ? 0
          : max(((event.timestamp - previousRawEventTime!) * 1000).round(), 0);
      gestureRawEvents.add(
        RawInputEvent(
          delayMs: eventDelayMs,
          type: event.type,
          code: event.code,
          value: event.value,
        ),
      );
      previousRawEventTime = event.timestamp;
    }

    void finishGesture({
      required double gestureEndTime,
      required RecordedActionType fallbackType,
    }) {
      final rawStartX = gestureStartRawX ?? currentRawX;
      final rawStartY = gestureStartRawY ?? currentRawY;
      final rawEndX = gestureLastRawX ?? currentRawX;
      final rawEndY = gestureLastRawY ?? currentRawY;
      if (rawStartX == null ||
          rawStartY == null ||
          rawEndX == null ||
          rawEndY == null ||
          gestureRawEvents.isEmpty) {
        return;
      }
      final startPoint = _mapPoint(
        rawX: rawStartX,
        rawY: rawStartY,
        bounds: bounds,
        screenSize: screenSize,
      );
      final endPoint = _mapPoint(
        rawX: rawEndX,
        rawY: rawEndY,
        bounds: bounds,
        screenSize: screenSize,
      );
      final localGestureStartTime = gestureStartTime;
      final localFirstMoveTime = firstMoveTime;
      final localPreviousGestureEndTime = previousGestureEndTime;
      final durationMs = gestureStartTime == null
          ? 0
          : max(((gestureEndTime - localGestureStartTime!) * 1000).round(), 0);
      final holdBeforeMoveMs =
          localFirstMoveTime == null || localGestureStartTime == null
          ? 0
          : max(
              ((localFirstMoveTime - localGestureStartTime) * 1000).round(),
              0,
            );
      final distance = sqrt(
        pow(endPoint.$1 - startPoint.$1, 2) +
            pow(endPoint.$2 - startPoint.$2, 2),
      );
      final actionType = _resolveGestureType(
        fallbackType: fallbackType,
        moved: moved,
        distance: distance,
        durationMs: durationMs,
        holdBeforeMoveMs: holdBeforeMoveMs,
      );
      final dragPath = _buildDragPath(
        actionType: actionType,
        samplePoints: gesturePathSamples,
        bounds: bounds,
        screenSize: screenSize,
      );
      final delayMs =
          localPreviousGestureEndTime == null || localGestureStartTime == null
          ? 0
          : max(
              ((localGestureStartTime - localPreviousGestureEndTime) * 1000)
                  .round(),
              0,
            );
      actions.add(
        RecordedAction(
          type: actionType,
          delayMs: delayMs,
          startX: startPoint.$1,
          startY: startPoint.$2,
          endX: endPoint.$1,
          endY: endPoint.$2,
          durationMs: durationMs,
          holdBeforeMoveMs: holdBeforeMoveMs,
          dragPath: dragPath,
          rawEvents: List<RawInputEvent>.from(gestureRawEvents),
        ),
      );
      previousGestureEndTime = gestureEndTime;
    }

    void appendPathSample({
      required int rawX,
      required int rawY,
      required double timestamp,
      bool force = false,
    }) {
      if (!force &&
          lastPathSampleTime != null &&
          ((timestamp - lastPathSampleTime!) * 1000).round() <
              _dragPathSampleIntervalMs) {
        return;
      }
      if (gesturePathSamples.isNotEmpty) {
        final lastSample = gesturePathSamples.last;
        if (lastSample.rawX == rawX && lastSample.rawY == rawY && !force) {
          return;
        }
      }
      gesturePathSamples.add(
        TimedRawPoint(timestamp: timestamp, rawX: rawX, rawY: rawY),
      );
      lastPathSampleTime = timestamp;
    }

    for (final line in lines) {
      totalLines += 1;
      final parsedEvent = _parseInputEventLine(line);
      if (parsedEvent == null || parsedEvent.devicePath != bounds.devicePath) {
        continue;
      }
      matchedDeviceLines += 1;

      if (_isTouchDown(line) && !isTouching) {
        isTouching = true;
        moved = false;
        touchDownCount += 1;
        gestureStartTime = parsedEvent.timestamp;
        previousRawEventTime = null;
        gestureRawEvents.clear();
        gestureStartRawX = null;
        gestureStartRawY = null;
        gestureLastRawX = null;
        gestureLastRawY = null;
        firstMoveTime = null;
        gesturePathSamples.clear();
        lastPathSampleTime = null;
      }

      if (isTouching) {
        appendGestureRawEvent(parsedEvent);
      }

      final maybeX = _extractAxisValue(line, isX: true);
      if (maybeX != null) {
        currentRawX = maybeX;
        xUpdateCount += 1;
        if (isTouching) {
          final previousGestureX = gestureLastRawX;
          gestureStartRawX ??= maybeX;
          if (previousGestureX != null && previousGestureX != maybeX) {
            moved = true;
            firstMoveTime ??= parsedEvent.timestamp;
          }
          gestureLastRawX = maybeX;
        }
      }

      final maybeY = _extractAxisValue(line, isX: false);
      if (maybeY != null) {
        currentRawY = maybeY;
        yUpdateCount += 1;
        if (isTouching) {
          final previousGestureY = gestureLastRawY;
          gestureStartRawY ??= maybeY;
          if (previousGestureY != null && previousGestureY != maybeY) {
            moved = true;
            firstMoveTime ??= parsedEvent.timestamp;
          }
          gestureLastRawY = maybeY;
        }
      }

      if (isTouching &&
          _isSyncReport(parsedEvent) &&
          gestureStartRawX != null &&
          gestureStartRawY != null &&
          currentRawX != null &&
          currentRawY != null &&
          (currentRawX != gestureStartRawX ||
              currentRawY != gestureStartRawY)) {
        appendPathSample(
          rawX: currentRawX,
          rawY: currentRawY,
          timestamp: parsedEvent.timestamp,
        );
      }

      if (_isTouchCancel(line) && isTouching) {
        touchCancelCount += 1;
        if (currentRawX != null && currentRawY != null) {
          appendPathSample(
            rawX: currentRawX,
            rawY: currentRawY,
            timestamp: parsedEvent.timestamp,
            force: true,
          );
        }
        finishGesture(
          gestureEndTime: parsedEvent.timestamp,
          fallbackType: RecordedActionType.cancel,
        );
        gestureRawEvents.clear();
        gesturePathSamples.clear();
        isTouching = false;
        gestureStartTime = null;
        gestureStartRawX = null;
        gestureStartRawY = null;
        gestureLastRawX = null;
        gestureLastRawY = null;
        firstMoveTime = null;
        previousRawEventTime = null;
        lastPathSampleTime = null;
        continue;
      }

      if (_isTouchUp(line) && isTouching) {
        touchUpCount += 1;
        if (currentRawX != null && currentRawY != null) {
          appendPathSample(
            rawX: currentRawX,
            rawY: currentRawY,
            timestamp: parsedEvent.timestamp,
            force: true,
          );
        }
        finishGesture(
          gestureEndTime: parsedEvent.timestamp,
          fallbackType: RecordedActionType.up,
        );
        gestureRawEvents.clear();
        gesturePathSamples.clear();
        isTouching = false;
        gestureStartTime = null;
        gestureStartRawX = null;
        gestureStartRawY = null;
        gestureLastRawX = null;
        gestureLastRawY = null;
        firstMoveTime = null;
        previousRawEventTime = null;
        lastPathSampleTime = null;
      }
    }

    final debugSummary = StringBuffer()
      ..writeln('totalLines=$totalLines')
      ..writeln('matchedDeviceLines=$matchedDeviceLines')
      ..writeln('touchDownCount=$touchDownCount')
      ..writeln('touchUpCount=$touchUpCount')
      ..writeln('touchCancelCount=$touchCancelCount')
      ..writeln('xUpdateCount=$xUpdateCount')
      ..writeln('yUpdateCount=$yUpdateCount')
      ..writeln('parsedActions=${actions.length}');
    for (int index = 0; index < actions.length; index++) {
      final action = actions[index];
      debugSummary.writeln(
        'action[$index]: type=${action.type.name} delay=${action.delayMs} start=(${action.startX},${action.startY}) end=(${action.endX},${action.endY}) duration=${action.durationMs} rawEvents=${action.rawEvents.length}',
      );
    }
    return ParseAttemptResult(
      devicePath: bounds.devicePath,
      actions: actions,
      debugSummary: debugSummary.toString(),
    );
  }

  List<RecordedPathPoint> _buildDragPath({
    required RecordedActionType actionType,
    required List<TimedRawPoint> samplePoints,
    required TouchBounds bounds,
    required ScreenSize screenSize,
  }) {
    if (actionType != RecordedActionType.swipe &&
        actionType != RecordedActionType.longPressSwipe) {
      return const [];
    }

    final path = <RecordedPathPoint>[];
    double? previousTimestamp;
    for (final sample in samplePoints) {
      final mappedPoint = _mapPoint(
        rawX: sample.rawX,
        rawY: sample.rawY,
        bounds: bounds,
        screenSize: screenSize,
      );
      final delayMs = previousTimestamp == null
          ? 0
          : max(((sample.timestamp - previousTimestamp) * 1000).round(), 0);
      if (path.isNotEmpty) {
        final lastPoint = path.last;
        if (lastPoint.x == mappedPoint.$1 && lastPoint.y == mappedPoint.$2) {
          previousTimestamp = sample.timestamp;
          continue;
        }
      }
      path.add(
        RecordedPathPoint(
          x: mappedPoint.$1,
          y: mappedPoint.$2,
          delayMs: delayMs,
        ),
      );
      previousTimestamp = sample.timestamp;
    }
    return path;
  }

  RecordedActionType _resolveGestureType({
    required RecordedActionType fallbackType,
    required bool moved,
    required double distance,
    required int durationMs,
    required int holdBeforeMoveMs,
  }) {
    if (fallbackType == RecordedActionType.cancel) {
      return RecordedActionType.cancel;
    }
    if (moved || distance > 24) {
      if (holdBeforeMoveMs >= 350) {
        return RecordedActionType.longPressSwipe;
      }
      return RecordedActionType.swipe;
    }
    if (durationMs >= 350) {
      return RecordedActionType.longPress;
    }
    return RecordedActionType.tap;
  }

  bool _isTouchDown(String line) {
    final parsedEvent = _parseInputEventLine(line);
    if (parsedEvent != null) {
      if (parsedEvent.type == 0x0003 && parsedEvent.code == 0x0039) {
        return parsedEvent.value >= 0;
      }
      return parsedEvent.type == 0x0001 &&
          parsedEvent.code == 0x014a &&
          parsedEvent.value == 1;
    }

    return line.contains('BTN_TOUCH') &&
        (line.contains('DOWN') || line.contains('00000001'));
  }

  bool _isTouchUp(String line) {
    final parsedEvent = _parseInputEventLine(line);
    if (parsedEvent != null) {
      if (parsedEvent.type == 0x0003 && parsedEvent.code == 0x0039) {
        return parsedEvent.value < 0;
      }
      return parsedEvent.type == 0x0001 &&
          parsedEvent.code == 0x014a &&
          parsedEvent.value == 0;
    }

    return line.contains('BTN_TOUCH') &&
        (line.contains('UP') || line.contains('00000000'));
  }

  bool _isTouchCancel(String line) {
    final parsedEvent = _parseInputEventLine(line);
    if (parsedEvent != null) {
      return parsedEvent.type == 0x0001 &&
          parsedEvent.code == 0x0145 &&
          parsedEvent.value == 1;
    }
    return line.contains('BTN_TOOL_DOUBLETAP') &&
        (line.contains('CANCEL') || line.contains('00000001'));
  }

  int? _extractAxisValue(String line, {required bool isX}) {
    final parsedEvent = _parseInputEventLine(line);
    if (parsedEvent != null && parsedEvent.type != 0x0003) {
      return null;
    }
    final axisNames = isX
        ? ['ABS_MT_POSITION_X', 'ABS_X']
        : ['ABS_MT_POSITION_Y', 'ABS_Y'];
    final axisCodes = isX ? ['0035', '0000'] : ['0036', '0001'];
    final matchesAxisName = axisNames.any(line.contains);
    final matchesAxisCode = axisCodes.any((code) => line.contains(' $code '));
    if (!matchesAxisName && !matchesAxisCode) {
      return null;
    }
    final match = RegExp(
      r'(?:0x)?([0-9a-fA-F]{1,8})\s*$',
    ).firstMatch(line.trim());
    if (match == null) {
      return null;
    }
    return int.parse(match.group(1)!, radix: 16);
  }

  bool _isSyncReport(ParsedInputEvent event) {
    return event.type == 0x0000 && event.code == 0x0000;
  }

  (int, int) _mapPoint({
    required int rawX,
    required int rawY,
    required TouchBounds bounds,
    required ScreenSize screenSize,
  }) {
    final x = (rawX / max(bounds.maxX, 1) * screenSize.width).round().clamp(
      0,
      screenSize.width,
    );
    final y = (rawY / max(bounds.maxY, 1) * screenSize.height).round().clamp(
      0,
      screenSize.height,
    );
    return (x, y);
  }

  Future<void> playFlow({
    required String deviceId,
    required RecordedFlow flow,
    required int loopCount,
    required bool Function() shouldStop,
    required void Function(String message) onLog,
  }) async {
    int currentLoop = 0;
    await _ensureSendeventReady(
      deviceId: deviceId,
      touchDevicePath: flow.touchDevicePath,
      onLog: onLog,
    );
    final sourceScreenSize = ScreenSize(
      width: flow.screenWidth,
      height: flow.screenHeight,
    );
    final targetScreenSize = await getScreenSize(deviceId);
    if (sourceScreenSize.isValid &&
        targetScreenSize.isValid &&
        (sourceScreenSize.width != targetScreenSize.width ||
            sourceScreenSize.height != targetScreenSize.height)) {
      onLog(
        '录制分辨率 ${sourceScreenSize.width}x${sourceScreenSize.height}，'
        '当前设备分辨率 ${targetScreenSize.width}x${targetScreenSize.height}，'
        '回放坐标将按比例映射',
      );
    }
    while (!shouldStop() && (loopCount <= 0 || currentLoop < loopCount)) {
      currentLoop += 1;
      onLog('开始回放第 $currentLoop 轮，共 ${flow.actions.length} 个动作');
      final shell = await Process.start('adb', ['-s', deviceId, 'shell']);
      await _sendPointerReset(
        shell: shell,
        touchDevicePath: flow.touchDevicePath,
      );
      for (final action in flow.actions) {
        if (shouldStop()) {
          await _sendPointerReset(
            shell: shell,
            touchDevicePath: flow.touchDevicePath,
          );
          shell.kill();
          onLog('已停止流程回放');
          return;
        }
        if (action.delayMs > 0) {
          await Future.delayed(Duration(milliseconds: action.delayMs));
        }
        await _playActionWithSendevent(
          shell: shell,
          touchDevicePath: flow.touchDevicePath,
          action: action,
          sourceScreenSize: sourceScreenSize,
          targetScreenSize: targetScreenSize,
        );
      }
      await _sendPointerReset(
        shell: shell,
        touchDevicePath: flow.touchDevicePath,
      );
      await shell.stdin.flush();
      await shell.stdin.close();
      await shell.exitCode.timeout(
        const Duration(seconds: 3),
        onTimeout: () => 0,
      );
      onLog('第 $currentLoop 轮流程回放完成');
    }
  }

  Future<void> _ensureSendeventReady({
    required String deviceId,
    required String touchDevicePath,
    required void Function(String message) onLog,
  }) async {
    if (touchDevicePath.isEmpty) {
      throw Exception('当前流程未保存触摸设备节点，无法使用 sendevent 回放');
    }
    final rootResult = await Process.run('adb', ['-s', deviceId, 'root']);
    final rootOutput = '${rootResult.stdout}${rootResult.stderr}'.trim();
    if (rootOutput.isNotEmpty) {
      onLog('adb root: $rootOutput');
    }
    final checkResult = await Process.run('adb', [
      '-s',
      deviceId,
      'shell',
      'ls',
      touchDevicePath,
    ]);
    if (checkResult.exitCode != 0) {
      throw Exception('无法访问触摸设备节点 $touchDevicePath: ${checkResult.stderr}');
    }
    onLog('当前版本使用 getevent 录制 + sendevent 回放，节点：$touchDevicePath');
  }

  Future<void> _playActionWithSendevent({
    required Process shell,
    required String touchDevicePath,
    required RecordedAction action,
    required ScreenSize sourceScreenSize,
    required ScreenSize targetScreenSize,
  }) async {
    final holdMs = switch (action.type) {
      RecordedActionType.longPress => max(action.durationMs, 350),
      RecordedActionType.longPressSwipe => max(action.holdBeforeMoveMs, 350),
      _ => 0,
    };
    final moveDurationMs = switch (action.type) {
      RecordedActionType.tap => 0,
      RecordedActionType.longPress => 0,
      RecordedActionType.swipe => max(action.durationMs, 60),
      RecordedActionType.longPressSwipe => max(
        action.durationMs - action.holdBeforeMoveMs,
        60,
      ),
      _ => max(action.durationMs, 60),
    };
    final (startX, startY) = sourceScreenSize.scalePointTo(
      x: action.startX,
      y: action.startY,
      target: targetScreenSize,
    );
    final (endX, endY) = sourceScreenSize.scalePointTo(
      x: action.endX,
      y: action.endY,
      target: targetScreenSize,
    );

    await _writeSendeventCommand(
      shell: shell,
      command: 'sendevent $touchDevicePath 3 47 $_defaultPointerSlot',
    );
    await _writeSendeventCommand(
      shell: shell,
      command: 'sendevent $touchDevicePath 3 57 $_defaultTrackingId',
    );
    await _writeSendeventCommand(
      shell: shell,
      command: 'sendevent $touchDevicePath 1 325 1',
    );
    await _writeSendeventCommand(
      shell: shell,
      command: 'sendevent $touchDevicePath 1 330 1',
    );
    await _writeSendeventCommand(
      shell: shell,
      command: 'sendevent $touchDevicePath 3 53 $startX',
    );
    await _writeSendeventCommand(
      shell: shell,
      command: 'sendevent $touchDevicePath 3 54 $startY',
    );
    await _writeSendeventCommand(
      shell: shell,
      command: 'sendevent $touchDevicePath 0 0 0',
    );

    if (holdMs > 0) {
      await Future.delayed(Duration(milliseconds: holdMs));
    }

    final needsMove = startX != endX || startY != endY;
    if (needsMove) {
      if (action.dragPath.isNotEmpty) {
        for (final point in action.dragPath) {
          if (point.delayMs > 0) {
            await Future.delayed(Duration(milliseconds: point.delayMs));
          }
          final (moveX, moveY) = sourceScreenSize.scalePointTo(
            x: point.x,
            y: point.y,
            target: targetScreenSize,
          );
          await _writeSendeventCommand(
            shell: shell,
            command: 'sendevent $touchDevicePath 3 53 $moveX',
          );
          await _writeSendeventCommand(
            shell: shell,
            command: 'sendevent $touchDevicePath 3 54 $moveY',
          );
          await _writeSendeventCommand(
            shell: shell,
            command: 'sendevent $touchDevicePath 0 0 0',
          );
        }
      } else {
        final steps = 12;
        final stepDelayMs = max((moveDurationMs / steps).round(), 8);
        for (int i = 1; i <= steps; i++) {
          final progress = i / steps;
          final moveX = startX + ((endX - startX) * progress).round();
          final moveY = startY + ((endY - startY) * progress).round();
          await _writeSendeventCommand(
            shell: shell,
            command: 'sendevent $touchDevicePath 3 53 $moveX',
          );
          await _writeSendeventCommand(
            shell: shell,
            command: 'sendevent $touchDevicePath 3 54 $moveY',
          );
          await _writeSendeventCommand(
            shell: shell,
            command: 'sendevent $touchDevicePath 0 0 0',
          );
          await Future.delayed(Duration(milliseconds: stepDelayMs));
        }
      }
    }

    await _sendPointerReset(shell: shell, touchDevicePath: touchDevicePath);
  }

  Future<void> _sendPointerReset({
    required Process shell,
    required String touchDevicePath,
  }) async {
    await _writeSendeventCommand(
      shell: shell,
      command: 'sendevent $touchDevicePath 1 330 0',
    );
    await _writeSendeventCommand(
      shell: shell,
      command: 'sendevent $touchDevicePath 1 325 0',
    );
    await _writeSendeventCommand(
      shell: shell,
      command: 'sendevent $touchDevicePath 3 57 4294967295',
    );
    await _writeSendeventCommand(
      shell: shell,
      command: 'sendevent $touchDevicePath 0 0 0',
    );
  }

  Future<void> _writeSendeventCommand({
    required Process shell,
    required String command,
  }) async {
    shell.stdin.writeln(command);
    await shell.stdin.flush();
  }

  Future<void> dispose() async {
    _activeWindowsRecorder = false;
    _recordingProcess?.kill();
    _recordingProcess = null;
    await _logController.close();
  }
}

class ParsedInputEvent {
  const ParsedInputEvent({
    required this.timestamp,
    required this.devicePath,
    required this.type,
    required this.code,
    required this.value,
  });

  final double timestamp;
  final String devicePath;
  final int type;
  final int code;
  final int value;
}

class TimedRawPoint {
  const TimedRawPoint({
    required this.timestamp,
    required this.rawX,
    required this.rawY,
  });

  final double timestamp;
  final int rawX;
  final int rawY;
}
